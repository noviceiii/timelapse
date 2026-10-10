#!/usr/bin/env python3
"""Count birds (or other objects) on a picture.

Used by pilapse.sh. Prints the number of detected objects to stdout and
optionally draws a frame around each of them.

The detection uses a YOLOX model in ONNX format (trained on the COCO data
set) through OpenCV, so only python3-opencv is required.

Birds are usually small on a wide angle picture. The picture is therefore
split into overlapping tiles and each tile is searched on its own, in
addition to the whole picture.

@Version 5.4.0, 10.10.2026.   first version
"""

import argparse
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


def run_model(net, picture, size):
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
    net.setInput(blob)
    output = np.asarray(net.forward())
    return output.reshape(-1, output.shape[-1]), scale


def detect_region(net, grid, strides, image, region, size, confidence, wanted_ids):
    """Search one region. Return boxes as [x0, y0, x1, y1] in picture coordinates and their scores.

    A detection touching a border of the region that lies inside the picture
    is dropped: the object is cut there and would be counted once per part.
    It is found as a whole in the neighbouring tile (small objects, thanks to
    the overlap) or in the search of the whole picture (large objects).
    """
    x, y, w, h = region
    image_h, image_w = image.shape[:2]
    margin = max(2.0, 0.01 * min(w, h))
    rows, scale = run_model(net, image[y:y + h, x:x + w], size)
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

    try:
        net = cv2.dnn.readNet(args.model)
    except cv2.error as error:
        sys.exit("Unable to load model %s with OpenCV %s: %s" % (args.model, cv2.__version__, error))
    grid, strides = make_grid(args.size)

    if args.selftest:
        try:
            test_rows, _ = run_model(net, np.full((args.size, args.size, 3), PAD_VALUE, dtype=np.uint8), args.size)
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
            net, grid, strides, image, region, args.size, args.confidence, wanted_ids)
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
