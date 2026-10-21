#!/bin/bash

# Downloads the model for the optional bird detection of pilapse.sh.
# The models are the YOLOX models published by Megvii (Apache License 2.0),
# trained on the COCO data set.
#
# Usage: ./get_model.sh [yolox_nano|yolox_tiny|yolox_s]
#
#   yolox_nano   smallest and fastest, finds the fewest birds   (BIRD_MODEL_SIZE=416)
#   yolox_tiny   default                                        (BIRD_MODEL_SIZE=416)
#   yolox_s      finds the most birds, several times slower     (BIRD_MODEL_SIZE=640)
#
# After the download the model is converted with detect_birds.py --convert:
# its first layer ("Focus") is removed and done by detect_birds.py instead.
# OpenCV before 4.5.2 (e.g. python3-opencv 4.5.1 of Debian Bullseye) cannot
# load this layer. The converted model works with every OpenCV version.
#
# @Version 5.4.0, 10.10.2026.   first version
# @Version 5.4.2, 21.10.2026.   model is converted after the download (Focus layer removed) for OpenCV 4.5.1

model="${1:-yolox_tiny}"

case "$model" in
    yolox_nano ) checksum="c789161ed43c8269fcd4e67c67eeeb4e80c622da2eb296a20bc6007bd18a0b7d";;
    yolox_tiny ) checksum="427cc366d34e27ff7a03e2899b5e3671425c262ea2291f88bb942bc1cc70b0f7";;
    yolox_s    ) checksum="c5c2d13e59ae883e6af3b45daea64af4833a4951c92d116ec270d9ddbe998063";;
    *          ) echo "Unknown model $model. Use yolox_nano, yolox_tiny or yolox_s."; exit 1;;
esac

script_dir=$(dirname "$(realpath "$0")")
target="$script_dir/model/$model.onnx"
url="https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/$model.onnx"

mkdir -p "$script_dir/model" || exit 1

echo "Downloading $url ..."
if ! curl -fL --retry 3 -o "$target.part" "$url"; then
    echo "Download failed."
    rm -f "$target.part"
    exit 1
fi

# Only keep the file if it is exactly the expected one
if ! echo "$checksum  $target.part" | sha256sum -c --quiet -; then
    echo "The downloaded file does not match the expected checksum. Removing it."
    rm -f "$target.part"
    exit 1
fi

# Remove the Focus layer, so OpenCV 4.5.1 can load the model
if ! python3 "$script_dir/detect_birds.py" --model "$target.part" --convert "$target"; then
    mv "$target.part" "$target"
    echo "The model could not be converted, the original is saved as $target."
    echo "It only works with OpenCV 4.5.2 or newer. Install python3-opencv and convert it with:"
    echo "python3 $script_dir/detect_birds.py --model $target --convert $target"
    exit 1
fi
rm -f "$target.part"
echo "Model saved as $target."
