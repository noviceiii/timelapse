#!/usr/bin/env python3
"""Count birds (or other objects) on a picture.

Used by pilapse.sh. Prints the number of detected objects to stdout and
optionally draws a frame around each of them.

The detection uses a YOLOX model in ONNX format (trained on the COCO data
set) through OpenCV, so only python3-opencv is required.

Birds are usually small on a wide angle picture. The picture is therefore
split into overlapping tiles and each tile is searched on its own, in
addition to the whole picture.

The YOLOX models start with a "Focus" layer that takes every second pixel
(slices with step 2). OpenCV before 4.5.2, e.g. 4.5.1 of Debian Bullseye,
cannot load such a slice. --convert therefore writes a copy of the model
without this layer, and the script does the same step on the picture itself
before it runs the model. get_model.sh does the conversion after the download.

@Version 5.4.0, 10.10.2026.   first version
@Version 5.4.2, 21.10.2026.   works with OpenCV 4.5.1: --convert removes the Focus layer from the model, done in numpy instead
"""

import argparse
import os
import sys

import cv2
import numpy as np

# Classes of the COCO data set, in the order the model reports them
COCO_CLASSES = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
    "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
    "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
    "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
    "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
    "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
    "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
    "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
    "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
    "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier",
    "toothbrush",
]

# Grey value YOLOX uses to fill the unused part of the model input
PAD_VALUE = 114


def parse_args():
    parser = argparse.ArgumentParser(description="Count birds or other objects on a picture.")
    parser.add_argument("image", nargs="?", help="picture to search")
    parser.add_argument("--model", required=True, help="YOLOX model file (.onnx)")
    parser.add_argument("--classes", default="bird",
                        help="comma separated class names to count (default: bird)")
    parser.add_argument("--confidence", type=float, default=0.3,
                        help="minimum confidence of a detection, 0..1 (default: 0.3)")
    parser.add_argument("--size", type=int, default=416,
                        help="input size of the model in pixels: 416 for yolox_tiny and "
                             "yolox_nano, 640 for yolox_s and larger (default: 416)")
    parser.add_argument("--tiles", default="3x2",
                        help="tiles as COLUMNSxROWS, 1x1 searches the whole picture only (default: 3x2)")
    parser.add_argument("--overlap", type=float, default=0.2,
                        help="overlap of neighbouring tiles, 0..0.5 (default: 0.2)")
    parser.add_argument("--annotate", metavar="FILE",
                        help="write the picture with a frame around each detection to FILE")
    parser.add_argument("--selftest", action="store_true",
                        help="only check that the model can be loaded and run, then exit")
    parser.add_argument("--convert", metavar="FILE",
                        help="write a copy of --model without the Focus layer to FILE, then exit; "
                             "needed for OpenCV before 4.5.2. FILE may be the --model file itself")
    return parser.parse_args()


def tile_regions(width, height, columns, rows, overlap):
    """Return the regions to search as (x, y, w, h): the whole picture plus the tiles."""
    regions = [(0, 0, width, height)]
    if columns == 1 and rows == 1:
        return regions

    tile_w = width / columns
    tile_h = height / rows
    pad_w = tile_w * overlap / 2
    pad_h = tile_h * overlap / 2

    for row in range(rows):
        for column in range(columns):
            x0 = max(0, int(column * tile_w - pad_w))
            y0 = max(0, int(row * tile_h - pad_h))
            x1 = min(width, int((column + 1) * tile_w + pad_w))
            y1 = min(height, int((row + 1) * tile_h + pad_h))
            regions.append((x0, y0, x1 - x0, y1 - y0))
    return regions


# ---------------------------------------------------------------------------
# Model file handling. An ONNX file is a protocol buffer message. Only the few
# fields needed to remove the Focus layer are read here, so no additional
# python package (onnx, protobuf) is required.
# ---------------------------------------------------------------------------

def read_varint(data, pos):
    """Read a protocol buffer varint at pos. Return the value and the position after it."""
    value = 0
    shift = 0
    while True:
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, pos
        shift += 7


def encode_varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def read_fields(data):
    """Split a protocol buffer message into (field number, value, raw bytes of the field).

    The value is the number for varints and the content for length delimited fields.
    """
    fields = []
    pos = 0
    while pos < len(data):
        start = pos
        key, pos = read_varint(data, pos)
        number, wire_type = key >> 3, key & 7
        if wire_type == 0:
            value, pos = read_varint(data, pos)
        elif wire_type == 1:
            value, pos = data[pos:pos + 8], pos + 8
        elif wire_type == 2:
            length, pos = read_varint(data, pos)
            value, pos = data[pos:pos + length], pos + length
        elif wire_type == 5:
            value, pos = data[pos:pos + 4], pos + 4
        else:
            raise ValueError("not an ONNX model file")
        if pos > len(data):
            raise ValueError("not an ONNX model file")
        fields.append((number, value, data[start:pos]))
    return fields


def encode_field(number, content):
    """Encode a length delimited field (bytes, string or message)."""
    return encode_varint(number << 3 | 2) + encode_varint(len(content)) + bytes(content)


def strings(fields, number):
    return [bytes(value).decode() for field, value, _ in fields if field == number]


# Field numbers of the ONNX messages used here (see onnx.proto)
MODEL_GRAPH = 7
GRAPH_NODE, GRAPH_INITIALIZER, GRAPH_INPUT, GRAPH_VALUE_INFO = 1, 5, 11, 13
NODE_INPUT, NODE_OUTPUT, NODE_OP_TYPE = 1, 2, 4
TENSOR_NAME = 8
VALUE_INFO_NAME, VALUE_INFO_TYPE = 1, 2
TYPE_TENSOR, TENSOR_TYPE_ELEM_TYPE, TENSOR_TYPE_SHAPE = 1, 1, 2
SHAPE_DIM, DIM_VALUE = 1, 1
FLOAT = 1


def load_graph(path):
    """Read a model file. Return the fields of the model and of its graph."""
    with open(path, "rb") as model_file:
        model = read_fields(memoryview(model_file.read()))
    graphs = [value for field, value, _ in model if field == MODEL_GRAPH]
    if len(graphs) != 1:
        raise ValueError("not an ONNX model file")
    return model, read_fields(graphs[0])


def graph_input(graph):
    """Return name and dimensions of the picture input of a graph."""
    initializers = set()
    for field, value, _ in graph:
        if field == GRAPH_INITIALIZER:
            initializers.update(strings(read_fields(value), TENSOR_NAME))
    inputs = [read_fields(value) for field, value, _ in graph if field == GRAPH_INPUT]
    inputs = [info for info in inputs if strings(info, VALUE_INFO_NAME)[0] not in initializers]
    if len(inputs) != 1:
        raise ValueError("the model must have exactly one input")
    dims = []
    for field, value, _ in inputs[0]:
        if field == VALUE_INFO_TYPE:
            for tensor in (v for f, v, _ in read_fields(value) if f == TYPE_TENSOR):
                for shape in (v for f, v, _ in read_fields(tensor) if f == TENSOR_TYPE_SHAPE):
                    for dim in (v for f, v, _ in read_fields(shape) if f == SHAPE_DIM):
                        dims.append(next((v for f, v, _ in read_fields(dim) if f == DIM_VALUE), 0))
    return strings(inputs[0], VALUE_INFO_NAME)[0], dims


def model_channels(path):
    """Return the number of channels the model input has: 3 for the original
    YOLOX models, 12 for a model converted with --convert."""
    _, graph = load_graph(path)
    dims = graph_input(graph)[1]
    if len(dims) != 4 or dims[1] not in (3, 12):
        raise ValueError("the model input must be a picture with 3 or 12 channels, is %s" % dims)
    return dims[1]


def convert_model(source, target):
    """Write a copy of the model without the Focus layer.

    The Focus layer consists of 8 Slice nodes (step 2) on the input and a
    Concat node joining their results to 12 channels of half size. These
    nodes are removed and the output of the Concat becomes the model input.
    focus() does the same on the picture.
    """
    model, graph = load_graph(source)
    input_name, dims = graph_input(graph)
    if len(dims) == 4 and dims[1] == 12:
        return False
    if len(dims) != 4 or dims[1] != 3 or dims[2] % 2 or dims[3] % 2:
        raise ValueError("unexpected model input %s" % dims)

    nodes = []
    for field, value, raw in graph:
        if field == GRAPH_NODE:
            node = read_fields(value)
            nodes.append((node, strings(node, NODE_OP_TYPE)[0],
                          strings(node, NODE_INPUT), strings(node, NODE_OUTPUT)))

    # Slices on the input or on another such slice, then the Concat of them
    sliced = {input_name}
    removed = []
    focus_output = None
    for index, (_, op_type, inputs, outputs) in enumerate(nodes):
        if op_type == "Slice" and inputs[0] in sliced:
            sliced.update(outputs)
            removed.append(index)
        elif op_type == "Concat" and len(removed) == 8 and all(name in sliced for name in inputs) \
                and len(inputs) == 4:
            removed.append(index)
            focus_output = outputs[0]
            break
    if focus_output is None:
        raise ValueError("no Focus layer found, the model is not a YOLOX model")

    removed_tensors = sliced | {focus_output}
    used = set()
    for index, (_, _, inputs, _) in enumerate(nodes):
        if index not in removed:
            used.update(inputs)
    if input_name in used:
        raise ValueError("the model input is used outside of the Focus layer")
    # Parameters of the slices (start, end, axis, step) that nothing else uses
    unused = set()
    for index in removed:
        unused.update(name for name in nodes[index][2] if name not in used and name not in removed_tensors)

    new_dims = [dims[0], 12, dims[2] // 2, dims[3] // 2]
    shape = b"".join(encode_field(SHAPE_DIM, encode_varint(DIM_VALUE << 3) + encode_varint(dim))
                     for dim in new_dims)
    tensor_type = encode_varint(TENSOR_TYPE_ELEM_TYPE << 3) + encode_varint(FLOAT) \
        + encode_field(TENSOR_TYPE_SHAPE, shape)
    new_input = encode_field(VALUE_INFO_NAME, input_name.encode()) \
        + encode_field(VALUE_INFO_TYPE, encode_field(TYPE_TENSOR, tensor_type))

    new_graph = []
    node_index = 0
    for field, value, raw in graph:
        if field == GRAPH_NODE:
            index = node_index
            node_index += 1
            if index in removed:
                continue
            node = nodes[index][0]
            if focus_output in nodes[index][2]:
                # Feed the model input where the output of the Focus layer was used
                content = b"".join(encode_field(NODE_INPUT, input_name.encode())
                                   if f == NODE_INPUT and bytes(v).decode() == focus_output else bytes(r)
                                   for f, v, r in node)
                raw = encode_field(GRAPH_NODE, content)
        elif field == GRAPH_INITIALIZER:
            if strings(read_fields(value), TENSOR_NAME)[0] in unused:
                continue
        elif field == GRAPH_INPUT:
            name = strings(read_fields(value), VALUE_INFO_NAME)[0]
            if name in unused:
                continue
            if name == input_name:
                raw = encode_field(GRAPH_INPUT, new_input)
        elif field == GRAPH_VALUE_INFO:
            if strings(read_fields(value), VALUE_INFO_NAME)[0] in removed_tensors:
                continue
        new_graph.append(bytes(raw))

    content = b"".join(encode_field(MODEL_GRAPH, b"".join(new_graph)) if field == MODEL_GRAPH else bytes(raw)
                       for field, value, raw in model)
    # Write to a temporary file first, so the model can be converted in place
    with open(target + ".tmp", "wb") as model_file:
        model_file.write(content)
    os.replace(target + ".tmp", target)
    return True


def focus(blob):
    """Do the Focus layer of YOLOX on a blob (1, 3, size, size): every second
    pixel, starting at (0, 0), (1, 0), (0, 1) and (1, 1) as row and column,
    gives 12 channels of half the size."""
    return np.ascontiguousarray(np.concatenate(
        (blob[:, :, 0::2, 0::2], blob[:, :, 1::2, 0::2], blob[:, :, 0::2, 1::2], blob[:, :, 1::2, 1::2]),
        axis=1))


def make_grid(size):
    """Return the cell positions and cell sizes YOLOX output rows refer to."""
    grids = []
    strides = []
    for stride in (8, 16, 32):
        cells = size // stride
        xs, ys = np.meshgrid(np.arange(cells), np.arange(cells))
        grids.append(np.stack((xs, ys), axis=2).reshape(-1, 2))
        strides.append(np.full((cells * cells, 1), stride))
    return np.concatenate(grids).astype(np.float32), np.concatenate(strides).astype(np.float32)


def run_model(net, picture, size, channels=3):
    """Run the model on a picture. Return the raw output rows and the scale used."""
    height, width = picture.shape[:2]
    scale = min(size / height, size / width)
    new_w = max(1, int(round(width * scale)))
    new_h = max(1, int(round(height * scale)))

    # Keep the aspect ratio: scale the picture into the top left corner, fill the rest
    model_input = np.full((size, size, 3), PAD_VALUE, dtype=np.uint8)
    model_input[:new_h, :new_w] = cv2.resize(picture, (new_w, new_h), interpolation=cv2.INTER_LINEAR)

    # This YOLOX export expects BGR pixel values 0..255 without normalisation
    blob = cv2.dnn.blobFromImage(model_input, 1.0, (size, size), swapRB=False, crop=False)
    if channels == 12:
        # Converted model: the Focus layer is done here instead of in the model
        blob = focus(blob)
    net.setInput(blob)
    output = np.asarray(net.forward())
    return output.reshape(-1, output.shape[-1]), scale


def detect_region(net, channels, grid, strides, image, region, size, confidence, wanted_ids):
    """Search one region. Return boxes as [x0, y0, x1, y1] in picture coordinates and their scores.

    A detection touching a border of the region that lies inside the picture
    is dropped: the object is cut there and would be counted once per part.
    It is found as a whole in the neighbouring tile (small objects, thanks to
    the overlap) or in the search of the whole picture (large objects).
    """
    x, y, w, h = region
    image_h, image_w = image.shape[:2]
    margin = max(2.0, 0.01 * min(w, h))
    rows, scale = run_model(net, image[y:y + h, x:x + w], size, channels)
    if rows.shape[0] != grid.shape[0]:
        sys.exit("The model does not fit --size %d. Use 416 for yolox_tiny and yolox_nano, "
                 "640 for yolox_s and larger." % size)

    # Each row: centre x, centre y, width, height, objectness, one score per class
    centres = (rows[:, 0:2] + grid) * strides / scale
    sizes = np.exp(rows[:, 2:4]) * strides / scale

    boxes = []
    scores = []
    for class_id in wanted_ids:
        class_scores = rows[:, 4] * rows[:, 5 + class_id]
        for index in np.nonzero(class_scores >= confidence)[0]:
            centre_x, centre_y = centres[index]
            box_w, box_h = sizes[index]
            x0, y0 = x + centre_x - box_w / 2, y + centre_y - box_h / 2
            x1, y1 = x + centre_x + box_w / 2, y + centre_y + box_h / 2
            cut = ((x > 0 and x0 <= x + margin) or (y > 0 and y0 <= y + margin)
                   or (x + w < image_w and x1 >= x + w - margin)
                   or (y + h < image_h and y1 >= y + h - margin))
            if cut:
                continue
            boxes.append([x0, y0, x1, y1])
            scores.append(float(class_scores[index]))
    return boxes, scores


def merge_detections(boxes, scores, threshold=0.5):
    """Remove duplicates of the same object.

    Two boxes are the same object if their intersection covers more than
    `threshold` of the smaller box. This also joins a box that shows only a
    part of an object (cut by a tile border) with the box of the whole object.
    """
    if not boxes:
        return []

    boxes = np.array(boxes, dtype=np.float32)
    areas = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    order = np.argsort(scores)[::-1]
    keep = []

    while order.size > 0:
        best = order[0]
        keep.append(best)
        rest = order[1:]
        if rest.size == 0:
            break

        inter_w = np.minimum(boxes[best, 2], boxes[rest, 2]) - np.maximum(boxes[best, 0], boxes[rest, 0])
        inter_h = np.minimum(boxes[best, 3], boxes[rest, 3]) - np.maximum(boxes[best, 1], boxes[rest, 1])
        intersection = np.clip(inter_w, 0, None) * np.clip(inter_h, 0, None)
        smaller = np.minimum(areas[best], areas[rest])
        covered = intersection / np.maximum(smaller, 1e-6)

        order = rest[covered <= threshold]

    return [boxes[index] for index in keep]


def main():
    args = parse_args()

    try:
        columns, rows = (int(value) for value in args.tiles.lower().split("x"))
        if columns < 1 or rows < 1:
            raise ValueError
    except ValueError:
        sys.exit("--tiles must look like 3x2, is '%s'" % args.tiles)

    if args.size < 32 or args.size % 32 != 0:
        sys.exit("--size must be a multiple of 32, is %d" % args.size)

    wanted = [name.strip() for name in args.classes.split(",") if name.strip()]
    unknown = [name for name in wanted if name not in COCO_CLASSES]
    if unknown or not wanted:
        sys.exit("Unknown class name(s): %s. Available: %s"
                 % (", ".join(unknown) or "(none given)", ", ".join(COCO_CLASSES)))
    wanted_ids = [COCO_CLASSES.index(name) for name in wanted]

    if args.convert:
        try:
            converted = convert_model(args.model, args.convert)
        except (OSError, ValueError, IndexError, UnicodeDecodeError) as error:
            sys.exit("Unable to convert model %s: %s" % (args.model, error))
        print("Model %s %s." % (args.model, ("converted, saved as " + args.convert) if converted
                                else "is already converted, nothing written"))
        return

    try:
        channels = model_channels(args.model)
    except (OSError, ValueError, IndexError, UnicodeDecodeError) as error:
        sys.exit("Unable to read model %s: %s" % (args.model, error))
    try:
        net = cv2.dnn.readNet(args.model)
    except cv2.error as error:
        hint = ""
        if channels == 3:
            hint = (" OpenCV before 4.5.2 cannot load the Focus layer of the original model. Convert it with: "
                    "python3 %s --model %s --convert %s" % (sys.argv[0], args.model, args.model))
        sys.exit("Unable to load model %s with OpenCV %s: %s%s" % (args.model, cv2.__version__, error, hint))
    grid, strides = make_grid(args.size)

    if args.selftest:
        try:
            test_rows, _ = run_model(net, np.full((args.size, args.size, 3), PAD_VALUE, dtype=np.uint8),
                                     args.size, channels)
        except cv2.error as error:
            sys.exit("Unable to run model %s with OpenCV %s: %s" % (args.model, cv2.__version__, error))
        if test_rows.shape[0] != grid.shape[0] or test_rows.shape[1] != 5 + len(COCO_CLASSES):
            sys.exit("Model %s does not fit: check --size (416 for yolox_tiny and yolox_nano, "
                     "640 for yolox_s and larger)." % args.model)
        print("ok")
        return

    if not args.image:
        sys.exit("No picture given.")
    image = cv2.imread(args.image)
    if image is None:
        sys.exit("Unable to read picture %s" % args.image)
    height, width = image.shape[:2]

    boxes = []
    scores = []
    for region in tile_regions(width, height, columns, rows, min(max(args.overlap, 0.0), 0.5)):
        region_boxes, region_scores = detect_region(
            net, channels, grid, strides, image, region, args.size, args.confidence, wanted_ids)
        boxes.extend(region_boxes)
        scores.extend(region_scores)

    found = merge_detections(boxes, scores)

    if args.annotate:
        thickness = max(2, width // 640)
        for box in found:
            x0, y0, x1, y1 = (int(round(value)) for value in box)
            cv2.rectangle(image, (x0, y0), (x1, y1), (0, 255, 255), thickness)
        if not cv2.imwrite(args.annotate, image, [cv2.IMWRITE_JPEG_QUALITY, 95]):
            sys.exit("Unable to write picture %s" % args.annotate)

    print(len(found))


if __name__ == "__main__":
    main()
