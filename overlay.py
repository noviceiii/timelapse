#!/usr/bin/env python3
"""Write a text onto a picture.

Used by pilapse.sh if python3-pil is installed. The text always fits into
the picture: it is wrapped at " | " onto up to --max-lines lines and made
smaller if needed. A semi-transparent box behind the text keeps it readable
on bright and dark backgrounds; without the box the text gets a dark outline.

[ICON-NAME] in the text is replaced with the picture icons/name.png, e.g.
[ICON-BIRD] with icons/bird.png. The icons are single-coloured: only their
transparency is used, they are drawn in the colour of the text.

@Version 5.4.3, 23.10.2026.   first version: text fits into the picture, box behind the text, icons
"""

import argparse
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ICON_PATTERN = re.compile(r"\[ICON-([A-Za-z0-9_-]+)\]")
SEPARATOR = " | "
SEPARATOR_PATTERN = re.compile(r"(?:^|\s)\|(?=\s|$)")
POSITIONS = ("bottom-right", "bottom-center", "bottom-left", "top-right", "top-center", "top-left")


def parse_args():
    parser = argparse.ArgumentParser(description="Write a text onto a picture.")
    parser.add_argument("input", help="picture to write on")
    parser.add_argument("output", help="file to save the result to (JPEG)")
    text = parser.add_mutually_exclusive_group(required=True)
    text.add_argument("--text", help="the text")
    text.add_argument("--text-file", help="file with the text (UTF-8)")
    parser.add_argument("--font", required=True, help="font file (.ttf or .otf)")
    parser.add_argument("--size", type=float, default=3.5,
                        help="height of the text in percent of the picture height (default: 3.5)")
    parser.add_argument("--max-lines", type=int, default=2,
                        help="wrap the text at ' | ' onto at most this many lines (default: 2)")
    parser.add_argument("--position", default="bottom-right", choices=POSITIONS,
                        help="where the text is placed (default: bottom-right)")
    parser.add_argument("--margin", type=float, default=2.0,
                        help="distance to the border in percent of the picture height (default: 2)")
    parser.add_argument("--box", type=float, default=50,
                        help="opacity of the box behind the text in percent, 0 for no box (default: 50)")
    parser.add_argument("--color", default="white", help="text colour, a name or #RRGGBB (default: white)")
    parser.add_argument("--icons", default=os.path.join(os.path.dirname(os.path.realpath(__file__)), "icons"),
                        help="directory of the icons (default: icons next to the script)")
    parser.add_argument("--quality", type=int, default=92, help="JPEG quality (default: 92)")
    parser.add_argument("--verbose", action="store_true", help="print font size, lines and area of the text")
    return parser.parse_args()


def split_parts(line, icons_dir, warnings):
    """Split a line into text and icon parts: ("text", "abc") or ("icon", Image)."""
    parts = []
    position = 0
    for match in ICON_PATTERN.finditer(line):
        if match.start() > position:
            parts.append(("text", line[position:match.start()]))
        path = os.path.join(icons_dir, match.group(1).lower() + ".png")
        try:
            parts.append(("icon", Image.open(path).convert("RGBA").getchannel("A")))
        except OSError:
            warnings.add("icon %s not found, left out" % path)
        position = match.end()
    if position < len(line):
        parts.append(("text", line[position:]))
    return parts


class Layout:
    """Measures and draws text with icons at one font size."""

    def __init__(self, font_file, size):
        self.font = ImageFont.truetype(font_file, size)
        self.size = size
        self.ascent, self.descent = self.font.getmetrics()
        cap_top, cap_bottom = self.font.getbbox("H")[1], self.font.getbbox("H")[3]
        # Icons are as high as the capital letters plus a little, centred on them
        self.icon_size = max(1, int(round((cap_bottom - cap_top) * 1.3)))
        self.icon_centre = (cap_top + cap_bottom) / 2
        self.icon_gap = max(1, int(round(size * 0.25)))

    def width(self, parts):
        total = 0
        for index, (kind, value) in enumerate(parts):
            if kind == "text":
                total += self.font.getlength(value)
            else:
                total += self.icon_size
                # Space after an icon unless the text after it starts with one anyway
                following = parts[index + 1] if index + 1 < len(parts) else None
                if following and not (following[0] == "text" and following[1].startswith(" ")):
                    total += self.icon_gap
        return int(round(total))

    def line_height(self):
        return self.ascent + self.descent


def wrap(chunks, widths, limit, separator_width, max_lines):
    """Pack chunks greedily onto lines not wider than limit. Return the lines as lists of chunk
    indexes, or None if more than max_lines lines would be needed."""
    lines = [[]]
    line_width = 0
    for index, width in enumerate(widths):
        if lines[-1] and line_width + separator_width + width > limit:
            lines.append([])
            line_width = 0
        line_width += (separator_width if lines[-1] else 0) + width
        lines[-1].append(index)
        if len(lines) > max_lines:
            return None
    return lines


def balance(lines, widths, sep_width, limit):
    """Move chunks between two lines so that they get about equally long: looks calmer."""
    if len(lines) != 2:
        return lines
    chunks = lines[0] + lines[1]

    def width(line):
        return sum(widths[i] for i in line) + sep_width * (len(line) - 1)

    best = lines
    for cut in range(1, len(chunks)):
        first, second = chunks[:cut], chunks[cut:]
        if max(width(first), width(second)) <= limit and \
                max(width(first), width(second)) < max(width(best[0]), width(best[1])):
            best = [first, second]
    return best


def layout_text(text, font_file, base_size, limit, max_lines, icons_dir, warnings):
    """Choose font size and line breaks. Return the layout and the lines as lists of parts."""
    # Split at " | "; empty parts (e.g. an empty placeholder) are left out
    chunks = [chunk.strip() for chunk in SEPARATOR_PATTERN.split(text)]
    chunks = [chunk for chunk in chunks if chunk] or [""]
    chunk_parts = [split_parts(chunk, icons_dir, warnings) for chunk in chunks]
    sep_parts = [("text", SEPARATOR)]

    def measure(size):
        layout = Layout(font_file, size)
        widths = [layout.width(parts) for parts in chunk_parts]
        return layout, widths, layout.width(sep_parts)

    def line_width(line, widths, sep_width):
        return sum(widths[i] for i in line) + sep_width * (len(line) - 1)

    layout, widths, sep_width = measure(base_size)
    everything = [list(range(len(chunks)))]
    single = line_width(everything[0], widths, sep_width)
    if single <= limit:
        lines = everything
    elif single * 0.85 <= limit or max_lines <= 1 or len(chunks) == 1:
        # One line at a slightly smaller size covers less of the picture than two lines
        lines = everything
        size = max(6, int(base_size * limit / single))
        layout, widths, sep_width = measure(size)
        while size > 6 and line_width(lines[0], widths, sep_width) > limit:
            size -= 1
            layout, widths, sep_width = measure(size)
        if line_width(lines[0], widths, sep_width) > limit and len(chunks) > 1:
            # Even the smallest size is too wide: more lines rather than a cut text
            lines = wrap(chunks, widths, limit, sep_width, len(chunks))
    else:
        size = base_size
        while True:
            lines = wrap(chunks, widths, limit, sep_width, max_lines)
            if lines is not None and all(line_width(line, widths, sep_width) <= limit for line in lines):
                break
            if size <= 6:
                # Even the smallest size is too wide: more lines rather than a cut text
                lines = wrap(chunks, widths, limit, sep_width, len(chunks))
                break
            size -= max(1, size // 25)
            layout, widths, sep_width = measure(size)
        lines = balance(lines, widths, sep_width, limit)

    result = []
    for line in lines:
        parts = []
        for position, index in enumerate(line):
            if position:
                parts.extend(sep_parts)
            parts.extend(chunk_parts[index])
        result.append(parts)
    return layout, result


def rounded_box(draw, box, radius, fill):
    """Rectangle with rounded corners (ImageDraw.rounded_rectangle needs Pillow 8.2)."""
    x0, y0, x1, y1 = box
    radius = min(radius, (x1 - x0) // 2, (y1 - y0) // 2)
    draw.rectangle((x0 + radius, y0, x1 - radius, y1), fill=fill)
    draw.rectangle((x0, y0 + radius, x1, y1 - radius), fill=fill)
    for cx, cy in ((x0, y0), (x1 - 2 * radius, y0), (x0, y1 - 2 * radius), (x1 - 2 * radius, y1 - 2 * radius)):
        draw.pieslice((cx, cy, cx + 2 * radius, cy + 2 * radius), 0, 360, fill=fill)


def main():
    args = parse_args()
    warnings = set()

    if args.text_file:
        try:
            with open(args.text_file, encoding="utf-8", errors="replace") as text_file:
                text = text_file.read()
        except OSError as error:
            sys.exit("Unable to read text file: %s" % error)
    else:
        text = args.text
    text = " ".join(text.split())

    try:
        picture = Image.open(args.input)
        picture.load()
    except OSError as error:
        sys.exit("Unable to read picture %s: %s" % (args.input, error))
    exif = picture.info.get("exif")
    picture = picture.convert("RGB")
    width, height = picture.size

    try:
        ImageFont.truetype(args.font, 10)
    except OSError as error:
        sys.exit("Unable to load font %s: %s" % (args.font, error))
    try:
        color = Image.new("RGB", (1, 1), args.color).getpixel((0, 0))
    except ValueError:
        sys.exit("Unknown colour '%s'" % args.color)

    margin = max(4, int(round(height * args.margin / 100)))
    base_size = max(8, int(round(height * args.size / 100)))
    padding = max(2, int(round(base_size * 0.35)))
    limit = width - 2 * margin - 2 * padding

    if text:
        layout, lines = layout_text(text, args.font, base_size, limit, max(1, args.max_lines),
                                    args.icons, warnings)
        area_box = draw_text(picture, layout, lines, args, color, margin, padding)
        if args.verbose:
            print("overlay: font size %d, %d line(s), area %d,%d-%d,%d of %dx%d"
                  % ((layout.size, len(lines)) + area_box + (width, height)))

    for warning in sorted(warnings):
        print("overlay: " + warning, file=sys.stderr)

    options = {"quality": args.quality}
    if exif:
        options["exif"] = exif
    try:
        picture.save(args.output, "JPEG", **options)
    except OSError as error:
        sys.exit("Unable to write picture %s: %s" % (args.output, error))


def draw_text(picture, layout, lines, args, color, margin, padding):
    width, height = picture.size
    line_height = layout.line_height()
    spacing = int(round(layout.size * 0.2))
    line_widths = [layout.width(parts) for parts in lines]
    block_w = max(line_widths) + 2 * padding
    block_h = len(lines) * line_height + (len(lines) - 1) * spacing + 2 * padding

    vertical, horizontal = args.position.split("-")
    if horizontal == "left":
        x0 = margin
    elif horizontal == "right":
        x0 = width - margin - block_w
    else:
        x0 = (width - block_w) // 2
    y0 = margin if vertical == "top" else height - margin - block_h
    # Never outside of the picture, even if the text could not be made small enough
    x0 = max(0, min(x0, width - block_w))
    y0 = max(0, min(y0, height - block_h))

    # Draw on a copy of the area only: faster than a layer of the whole picture
    area_box = (x0, y0, min(width, x0 + block_w), min(height, y0 + block_h))
    area = picture.crop(area_box).convert("RGBA")
    layer = Image.new("RGBA", area.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    box_alpha = int(round(255 * min(max(args.box, 0), 100) / 100))
    if box_alpha:
        rounded_box(draw, (0, 0, area.size[0] - 1, area.size[1] - 1), padding, (0, 0, 0, box_alpha))
    area = Image.alpha_composite(area, layer)

    # Without a box the text gets a dark outline to stay readable
    stroke = 0 if box_alpha >= 64 else max(1, layout.size // 16)
    draw = ImageDraw.Draw(area)
    for number, parts in enumerate(lines):
        if horizontal == "left":
            x = padding
        elif horizontal == "right":
            x = block_w - padding - line_widths[number]
        else:
            x = (block_w - line_widths[number]) // 2
        y = padding + number * (line_height + spacing)
        for index, (kind, value) in enumerate(parts):
            if kind == "text":
                draw.text((x, y), value, font=layout.font, fill=color + (255,),
                          stroke_width=stroke, stroke_fill=(0, 0, 0, 255))
                x += layout.font.getlength(value)
            else:
                icon = value.resize((layout.icon_size, layout.icon_size), Image.LANCZOS)
                top = int(round(y + layout.icon_centre - layout.icon_size / 2))
                left = int(round(x))
                if stroke:
                    outline = icon.filter(ImageFilter.MaxFilter(2 * (stroke // 2) + 3))
                    area.paste((0, 0, 0, 255), (left, top), outline)
                area.paste(color + (255,), (left, top), icon)
                x += layout.icon_size
                following = parts[index + 1] if index + 1 < len(parts) else None
                if following and not (following[0] == "text" and following[1].startswith(" ")):
                    x += layout.icon_gap
    picture.paste(area.convert("RGB"), area_box[:2])
    return area_box


if __name__ == "__main__":
    main()
