#!/bin/bash

# Raspi Time Lapse from sunrise to sunset with text overlay,
# Backup on remote Linux server, upload to YouTube.
# Requires rpicam-apps (formerly libcamera-apps), hdate, bc and ffmpeg.
# The text overlay works best with python3-pil (overlay.py); without it ffmpeg writes the text.
# The optional bird detection requires python3-opencv and a model file, see get_model.sh.

# @Version 5.2.0, 13.01.2025.   added functionality to replace placeholders for YouTube title and description
# @Version 5.2.1, 15.01.2025.   added functionality to replace placeholders in description
# @Version 5.2.2, 16.01.2025.   added more placeholders in description, added flag to enable/disable overlay text, added escape characters for special characters in overlay text
# @Version 5.2.3, 22.01.2025.   better handling of hdate; fixed and simplified longitude/latitude settings.
# ..                            fixed escaping of percentage sign in overlay text.
# ..                            fixed too early end of loop. Added more debug output.
# @Version 5.3.0, 10.02.2025.   added new config parameters to overwrite start and end time
# @Version 5.3.1, 10.10.2026.   fixed interval timing: pictures are now taken at a constant interval
# @Version 5.3.2, 10.10.2026.   video is now also created when the text overlay is disabled
# @Version 5.3.3, 10.10.2026.   upload results are checked; the video is kept if an upload fails or none was done
# @Version 5.3.4, 10.10.2026.   a failed picture is skipped instead of aborting the whole day; debug mode takes exactly z pictures
# @Version 5.3.5, 10.10.2026.   configuration, commands and hdate times are checked before waiting; camera command is detected (rpicam-jpeg or libcamera-jpeg)
# @Version 5.3.6, 10.10.2026.   placeholders: every occurrence is replaced, special characters in values are safe, spellings from the readme work
# @Version 5.3.7, 10.10.2026.   overlay text is passed to ffmpeg as a file, no escaping of special characters needed anymore
# @Version 5.3.8, 10.10.2026.   description of a start override is no longer lost when there is no end override
# @Version 5.4.0, 10.10.2026.   added optional bird detection: counts birds on each picture, shows the number in the overlay and frames them
# @Version 5.4.1, 10.10.2026.   duration of the bird detection is measured, logged and shown on the picture in debug mode; summary at the end of the capture
# @Version 5.4.2, 21.10.2026.   bird detection works with OpenCV 4.5.1 (Debian Bullseye): get_model.sh converts the model, detect_birds.py does the Focus layer
# @Version 5.4.3, 23.10.2026.   overlay text always fits into the picture (overlay.py), box, position, size, icons; font fallback; daily bird sum [BIRD-SUM]

# Configuration file path
script_dir=$(dirname "$(realpath "$0")")
CONFIG_FILE="$script_dir/config.cfg"         # set path to config file

# Read security-relevant variables from config file
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Configuration file $CONFIG_FILE not found. Exiting."
    exit 1
fi

# ------------------------------------------------------------------------------------------------------------------------------------------- 

#### INIT ####
echo "==========================================================================="
echo "Initialization"
echo "---------------------------------------------------------------------------"

i=1                                                 # Picture counter (number of the picture being taken)
ipics=0                                             # Number of successfully created pictures
fails=0                                             # Consecutive failed pictures
fin=1                                               # Flag to continue loop

# Give up after this many failed pictures in a row (optional in config file)
MAX_CAPTURE_FAILS="${MAX_CAPTURE_FAILS:-10}"

# Bird detection (optional in config file, off by default)
BIRD_DETECTION_ENABLED="${BIRD_DETECTION_ENABLED:-0}"
BIRD_SCRIPT="${BIRD_SCRIPT:-$script_dir/detect_birds.py}"
BIRD_MODEL="${BIRD_MODEL:-$script_dir/model/yolox_tiny.onnx}"
BIRD_MODEL_SIZE="${BIRD_MODEL_SIZE:-416}"
BIRD_CLASSES="${BIRD_CLASSES:-bird}"
BIRD_CONFIDENCE="${BIRD_CONFIDENCE:-0.3}"
BIRD_TILES="${BIRD_TILES:-3x2}"
BIRD_DRAW_BOXES="${BIRD_DRAW_BOXES:-1}"
BIRD_STATE_FILE="${BIRD_STATE_FILE:-$script_dir/bird_state.txt}"
birds=""                                            # Birds on the current picture
birdsum=0                                           # Birds on all pictures of today added up
birdmax=0                                           # Highest number of birds on a single picture today
birdimages=0                                        # Number of pictures with at least one bird today
birdday=""                                          # Day the numbers above belong to (YYYY-MM-DD)
birdtime=""                                         # Duration of the detection on the current picture in seconds
birdtimeavg=""                                      # Average duration of the detection in seconds
birdtimemax=""                                      # Longest duration of the detection in seconds
msbirdsum=0                                         # Sum of all detection durations in milliseconds
msbirdmax=0                                         # Longest detection duration in milliseconds
birdruns=0                                          # Number of detections done
slowpics=0                                          # Pictures that took longer than the interval

# Text overlay (optional in config file)
OVERLAY_SIZE="${OVERLAY_SIZE:-3.5}"                 # Height of the text in percent of the picture height
OVERLAY_MAX_LINES="${OVERLAY_MAX_LINES:-2}"         # Wrap a long text at " | " onto up to this many lines
OVERLAY_POSITION="${OVERLAY_POSITION:-bottom-right}"
OVERLAY_MARGIN="${OVERLAY_MARGIN:-2}"               # Distance to the border in percent of the picture height
OVERLAY_BOX="${OVERLAY_BOX:-50}"                    # Opacity of the box behind the text in percent, 0 = outline instead
OVERLAY_COLOR="${OVERLAY_COLOR:-white}"
OVERLAY_ICONS="${OVERLAY_ICONS:-$script_dir/icons}"
OVERLAY_SCRIPT="$script_dir/overlay.py"
overlaypil=0                                        # 1 if overlay.py (Pillow) writes the text, 0 for ffmpeg
ofont=""                                            # Font file used for the overlay

# Daily bird numbers: kept in a small file, so a restart on the same day
# continues to count and a new day starts at 0. Format: "YYYY-MM-DD sum max images"
bird_state_load() {
    local day sum max images
    birdday=$(date +%F)
    birdsum=0; birdmax=0; birdimages=0
    if [ -r "$BIRD_STATE_FILE" ] && read -r day sum max images < "$BIRD_STATE_FILE" \
        && [ "$day" = "$birdday" ] && [[ "$sum" =~ ^[0-9]+$ ]] && [[ "$max" =~ ^[0-9]+$ ]] && [[ "$images" =~ ^[0-9]+$ ]]; then
        birdsum=$sum; birdmax=$max; birdimages=$images
    fi
}

# Add the birds of one picture to today's numbers and save them
bird_state_add() {
    local today
    today=$(date +%F)
    # New day while running: start again at 0
    if [ "$today" != "$birdday" ]; then
        birdday=$today; birdsum=0; birdmax=0; birdimages=0
    fi
    birdsum=$((birdsum + $1))
    [ "$1" -gt "$birdmax" ] && birdmax=$1
    [ "$1" -gt 0 ] && birdimages=$((birdimages + 1))
    if ! { printf '%s %s %s %s\n' "$birdday" "$birdsum" "$birdmax" "$birdimages" > "$BIRD_STATE_FILE.tmp" \
            && mv -f "$BIRD_STATE_FILE.tmp" "$BIRD_STATE_FILE"; } 2>/dev/null; then
        echo "* unable to save the bird numbers to $BIRD_STATE_FILE."
    fi
}

# Format milliseconds as seconds with one decimal, e.g. 1234 -> 1.2
ms_to_s() {
    printf "%d.%d" $(($1 / 1000)) $((($1 % 1000) / 100))
}

# Camera command: taken from the config file if set, otherwise detected.
# Newer Raspberry Pi OS releases name it rpicam-jpeg, older ones libcamera-jpeg.
if [ -z "$CAMERA_CMD" ]; then
    if command -v rpicam-jpeg >/dev/null 2>&1; then
        CAMERA_CMD="rpicam-jpeg"
    else
        CAMERA_CMD="libcamera-jpeg"
    fi
fi
echo "Camera command: $CAMERA_CMD"

# Collect all configuration problems before the script starts to wait
errors=0
fail() {
    echo "ERROR: $1"
    errors=$((errors + 1))
}

# Required commands
reqcmds="$CAMERA_CMD hdate bc ffmpeg"
[ "$SCP_UPLOAD_ENABLED" = "1" ] && reqcmds="$reqcmds scp"
[ "$YOUTUBE_UPLOAD_ENABLED" = "1" ] && reqcmds="$reqcmds python3"
[ "$BIRD_DETECTION_ENABLED" = "1" ] && reqcmds="$reqcmds python3"
for reqcmd in $reqcmds; do
    command -v "$reqcmd" >/dev/null 2>&1 || fail "Command $reqcmd not found."
done

# Numeric settings
is_uint='^[0-9]+$'
[[ "$INTERVAL" =~ $is_uint ]] && [ "$INTERVAL" -ge 1 ] || fail "INTERVAL must be a whole number of seconds >= 1, is '$INTERVAL'."
[[ "$RESW" =~ $is_uint ]] || fail "RESW must be a whole number, is '$RESW'."
[[ "$RESH" =~ $is_uint ]] || fail "RESH must be a whole number, is '$RESH'."
[[ "$offSTART" =~ $is_uint ]] || fail "offSTART must be a whole number of hours, is '$offSTART'."
[[ "$offEND" =~ $is_uint ]] || fail "offEND must be a whole number of hours, is '$offEND'."
[[ "$MAX_CAPTURE_FAILS" =~ $is_uint ]] && [ "$MAX_CAPTURE_FAILS" -ge 1 ] || fail "MAX_CAPTURE_FAILS must be a whole number >= 1, is '$MAX_CAPTURE_FAILS'."
[[ "$debug" =~ ^[01]$ ]] || fail "debug must be 0 or 1, is '$debug'."
if [ "$debug" = "1" ]; then
    [[ "$z" =~ $is_uint ]] && [ "$z" -ge 1 ] || fail "z must be a whole number >= 1 in debug mode, is '$z'."
fi
[[ "$DT" =~ ^[0-9]*\.?[0-9]+$ ]] || fail "DT must be a positive number, is '$DT'."

# Files and directories
[ -d "$TDIR" ] && [ -w "$TDIR" ] || fail "Temporary directory '$TDIR' does not exist or is not writable."
if [ "$OVERLAY_ENABLED" = "1" ]; then
    # Font: the one from the config file, otherwise a common font of Raspberry Pi OS
    for ofont in "$FPATH" /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
        /usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf \
        /usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf \
        /usr/share/fonts/truetype/freefont/FreeSans.ttf ""; do
        [ -n "$ofont" ] && [ -f "$ofont" ] && break
    done
    if [ -z "$ofont" ]; then
        fail "Font file '$FPATH' not found and no other font found. Set FPATH or install fonts-dejavu-core."
    elif [ "$ofont" != "$FPATH" ]; then
        echo "Note: font file '$FPATH' not found, using $ofont instead."
    fi
    [[ "$OVERLAY_SIZE" =~ ^[0-9]*\.?[0-9]+$ ]] || fail "OVERLAY_SIZE must be a number (percent of the picture height), is '$OVERLAY_SIZE'."
    [[ "$OVERLAY_MARGIN" =~ ^[0-9]*\.?[0-9]+$ ]] || fail "OVERLAY_MARGIN must be a number (percent of the picture height), is '$OVERLAY_MARGIN'."
    [[ "$OVERLAY_MAX_LINES" =~ ^[1-9]$ ]] || fail "OVERLAY_MAX_LINES must be a number from 1 to 9, is '$OVERLAY_MAX_LINES'."
    [[ "$OVERLAY_BOX" =~ ^([0-9]|[1-9][0-9]|100)$ ]] || fail "OVERLAY_BOX must be a number from 0 to 100 (percent), is '$OVERLAY_BOX'."
    [[ "$OVERLAY_POSITION" =~ ^(top|bottom)-(left|center|right)$ ]] || fail "OVERLAY_POSITION must be top-left, top-center, top-right, bottom-left, bottom-center or bottom-right, is '$OVERLAY_POSITION'."
    [[ "$OVERLAY_COLOR" =~ ^([a-zA-Z]+|#[0-9a-fA-F]{6})$ ]] || fail "OVERLAY_COLOR must be a colour name like white or #RRGGBB, is '$OVERLAY_COLOR'."
    # overlay.py makes the text fit into the picture and can show icons. Without
    # Pillow ffmpeg writes the text: the size is estimated and icons are left out.
    if [ -f "$OVERLAY_SCRIPT" ] && command -v python3 >/dev/null 2>&1 && python3 -c "import PIL" 2>/dev/null; then
        overlaypil=1
        echo "Text overlay is written by overlay.py. Font: $ofont."
    else
        echo "Note: text overlay is written by ffmpeg. Install python3-pil for a text that always fits and for icons: sudo apt install python3-pil"
    fi
fi
if [ "$YOUTUBE_UPLOAD_ENABLED" = "1" ] && [ ! -f "$YOUTUBE_SCRIPT_PATH" ]; then
    fail "YouTube upload script '$YOUTUBE_SCRIPT_PATH' not found."
fi


# Bird detection: check the files and run the model once, so a missing
# package or an unsuitable model shows up now and not on the first picture
if [ "$BIRD_DETECTION_ENABLED" = "1" ]; then
    echo "Bird detection is enabled. Classes: $BIRD_CLASSES. Model: $BIRD_MODEL. Tiles: $BIRD_TILES."
    [[ "$BIRD_DRAW_BOXES" =~ ^[01]$ ]] || fail "BIRD_DRAW_BOXES must be 0 or 1, is '$BIRD_DRAW_BOXES'."
    if [ ! -f "$BIRD_SCRIPT" ]; then
        fail "Bird detection script '$BIRD_SCRIPT' not found."
    elif [ ! -f "$BIRD_MODEL" ]; then
        fail "Bird detection model '$BIRD_MODEL' not found. Run get_model.sh to download it."
    elif ! python3 -c "import cv2" 2>/dev/null; then
        fail "Bird detection needs OpenCV for Python. Install it with: sudo apt install python3-opencv"
    elif ! birdtest=$(python3 "$BIRD_SCRIPT" --selftest --model "$BIRD_MODEL" --size "$BIRD_MODEL_SIZE" \
            --classes "$BIRD_CLASSES" --confidence "$BIRD_CONFIDENCE" --tiles "$BIRD_TILES" 2>&1); then
        fail "Bird detection self test failed: $birdtest"
    fi
    if [ "$OVERLAY_ENABLED" != "1" ] || [[ "$OVERLAY_TEXT" != *"[BIRD-"* ]]; then
        echo "Note: the number of birds is only shown on the pictures if OVERLAY_ENABLED=1 and OVERLAY_TEXT contains [BIRD-SUM] or [BIRD-COUNT]."
    fi
    # Debug runs count separately, so testing does not change the numbers of the day
    [ "$debug" = "1" ] && BIRD_STATE_FILE="$BIRD_STATE_FILE.debug"
    bird_state_load
    echo "Birds today so far: $birdsum (most on one picture: $birdmax, pictures with birds: $birdimages). Saved in $BIRD_STATE_FILE."
fi

if [ "$errors" -gt 0 ]; then
    echo "$errors configuration problem(s) found. Exiting."
    exit 1
fi

# Timestamp for filenames and directories
ts_path=$(date +%Y-%m-%d_%H%M%S)
tsfriendly=$(date +%d.%m.%Y)

# Working directory
wdir="$TDIR/$ts_path"
resxy="${RESW}x${RESH}"                             # Image/video size
fr=$(echo "scale=0; 1/$DT" | bc)                    # Calculate frame rate
if ! [[ "$fr" =~ $is_uint ]] || [ "$fr" -lt 1 ]; then
    echo "ERROR: DT=$DT results in an invalid frame rate '$fr'. DT must be between 0 and 1. Exiting."
    exit 1
fi

# Current time
tnow1=$(date +%H:%M:%S)
snow1=$(date +%s -d "$tnow1")

# Execute hdate to get sunrise and sunset times
output=$(hdate --timezone $TIZO --latitude $LAT --longitude $LONG -t --not-sunset-aware)

# Extract date and time values
date=$(echo "$output" | grep -oP '(?<=, ).*(?=, \d{4})')
year=$(echo "$output" | grep -oP '\d{4}')
first_light=$(echo "$output" | grep -oP '(?<=first_light: )\d{2}:\d{2}')
talit=$(echo "$output" | grep -oP '(?<=talit: )\d{2}:\d{2}')
sunrise=$(echo "$output" | grep -oP '(?<=sunrise: )\d{2}:\d{2}')
midday=$(echo "$output" | grep -oP '(?<=midday: )\d{2}:\d{2}')
sunset=$(echo "$output" | grep -oP '(?<=sunset: )\d{2}:\d{2}')
first_stars=$(echo "$output" | grep -oP '(?<=first_stars: )\d{2}:\d{2}')
three_stars=$(echo "$output" | grep -oP '(?<=three_stars: )\d{2}:\d{2}')
sun_hour=$(echo "$output" | grep -oP '(?<=sun_hour: )\d{2}:\d{2}')

# Sheow values of time variables
echo "First Light: $first_light"
echo "Sunrise: $sunrise"
echo "Sunset : $sunset"
echo "First Stars: $first_stars"
echo "Three Stars: $three_stars"
echo "Sun Hour: $sun_hour"

# Stop here if hdate did not deliver usable times. An empty value would
# silently be read as midnight and the script would end after one picture.
is_hhmm='^[0-9]{2}:[0-9]{2}$'
[[ "$sunrise" =~ $is_hhmm ]] || fail "No sunrise time from hdate."
[[ "$sunset" =~ $is_hhmm ]] || fail "No sunset time from hdate."
if [ "$startevent" = "firstlight" ]; then
    [[ "$first_light" =~ $is_hhmm ]] || fail "No first light time from hdate. Set startevent to \"sunrise\" if there is none at your location."
fi
if [ "$errors" -gt 0 ]; then
    echo "hdate output was:"
    echo "$output"
    echo "Exiting."
    exit 1
fi

# Convert time to seconds
ssunrise=$(date +%s -d "$sunrise")
ssunset=$(date +%s -d "$sunset")
sfirstlight=$(date +%s -d "$first_light")

# Function to get overridden start or end time
get_overridden_time() {
    local event=$1
    local now=$(date +"%Y-%m-%d %H:%M:%S")
    local year=$(date +"%Y")
    local month=$(date +"%m")
    local day=$(date +"%d")

    for override in "${override_times[@]}"; do
        # Split the override string into its parts
        IFS='|' read -ra PARTS <<< "$override"
        local y=""
        local m=""
        local d=""
        local e=""
        local t=""
        local time=""

        for part in "${PARTS[@]}"; do
            case $part in
                y:* ) y=${part#y:};;
                m:* ) m=${part#m:};;
                d:* ) d=${part#d:};;
                e:* ) e=${part#e:};;
                t:* ) t=${part#t:};;
                *   ) time=$part;;  # This should be the time part
            esac
        done

        if [ "$e" != "$event" ]; then
            continue  # Skip if the event does not match
        fi

        # Check year, month, and day
        if [ -n "$y" ] && [ "$y" != "$year" ]; then
            continue
        fi
        if [ -n "$m" ] && [ "$m" != "$month" ]; then
            continue
        fi
        if [ -n "$d" ] && [ "$d" != "$day" ]; then
            continue
        fi

        echo "$time|$t"
        return
    done
    echo ""
}

# Calculate script start and end times, including offset
sstart=$((offSTART * 3600))
send=$((offEND * 3600))

# Check for overridden start time
overridden_start=$(get_overridden_time "Start")
IFS='|' read -r start_override start_desc <<< "$overridden_start"
if [ -n "$start_override" ]; then
    echo "Overriding start time with $start_override. Description: $start_desc"
    sstarttime=$(date +%s -d "$start_override")
else
    if [ "$startevent" = "firstlight" ]; then
        echo "The script shall start at first light: $first_light with an offset of -$offSTART."
        sstarttime=$((sfirstlight - sstart))
    else
        echo "The script shall start at sunrise: $sunrise with an offset of -$offSTART."
        sstarttime=$((ssunrise - sstart))
    fi
fi

# Check for overridden end time
overridden_end=$(get_overridden_time "End")
IFS='|' read -r end_override end_desc <<< "$overridden_end"
if [ -n "$end_override" ]; then
    echo "Overriding end time with $end_override. Description: $end_desc"
    sendtime=$(date +%s -d "$end_override")
else
    sendtime=$((ssunset + send))
fi

# Description for the placeholder [EVENT-DESCRIPTION]: start and end text, whichever is set
description="$start_desc"
if [ -n "$end_desc" ]; then
    description="${description:+$description / }$end_desc"
fi

# Wait until start time if not in debug mode
if [ "$debug" -eq 0 ]; then
    offwait=$((sstarttime - snow1))
    offwait=$((offwait < 0 ? 0 : offwait))

    echo "Sunrise at $sunrise. Sunset at $sunset. Offset $offSTART hrs. It is $tnow1. Waiting $offwait second(s)..."
    
    sleep "$offwait"
else
    echo "Debugging mode is on. Starting immediately."
fi

# Function to replace placeholders in a given string with actual values
replace_placeholders() {
    local out="$1"

    # leading zero for image count
    local formatted_i
    formatted_i=$(printf "%05d" "$i")

    # Replace every occurrence. The quotes around the values keep special
    # characters in them (like & | or \) literal.
    out=${out//\[SUNRISE\]/"$sunrise"}
    out=${out//\[FIRSTLIGHT\]/"$first_light"}
    out=${out//\[START-OFFSET\]/"$offSTART"}
    out=${out//\[SUNSET\]/"$sunset"}
    out=${out//\[SUNSET-OFFSET\]/"$offEND"}
    out=${out//\[EVENT-DESCRIPTION\]/"$description"}
    out=${out//\[IMAGE-COUNT\]/"$i"}
    out=${out//\[IMAGE-COUNT-FORMATED\]/"$formatted_i"}
    out=${out//\[INTERVAL\]/"$INTERVAL"}
    out=${out//\[HEIGHT\]/"$RESH"}
    out=${out//\[LENGTH\]/"$RESW"}
    out=${out//\[WIDTH\]/"$RESW"}
    out=${out//\[FRAMERATE\]/"$fr"}
    out=${out//\[FORMATED_DATE\]/"$tsfriendly"}
    out=${out//\[FORMATTED_DATE\]/"$tsfriendly"}
    out=${out//\[FORMATED_DATETIME\]/"$tsoverlay"}
    out=${out//\[FORMATTED_DATETIME\]/"$tsoverlay"}
    out=${out//\[INT-TEMP\]/"$obrdtmp"}
    out=${out//\[WEATHER\]/"$weather"}
    out=${out//\[LAT\]/"$LAT"}
    out=${out//\[LATITUDE\]/"$LAT"}
    out=${out//\[LONG\]/"$LONG"}
    out=${out//\[LONGITUDE\]/"$LONG"}
    out=${out//\[PLAYLIST\]/"$PLAYLIST"}
    out=${out//\[YOUTUBE-CATEGORY\]/"$YOUTUBE_CATEGORY"}
    out=${out//\[YOUTUBE-LANGUAGE\]/"$YOUTUBE_LANGUAGE"}
    out=${out//\[YOUTUBE-PRIVACY\]/"$YOUTUBE_PRIVACY"}
    out=${out//\[YOUTUBE-TAGS\]/"$YOUTUBE_TAGS"}
    out=${out//\[BIRD-COUNT\]/"$birds"}
    out=${out//\[BIRD-SUM\]/"$birdsum"}
    out=${out//\[BIRD-MAX\]/"$birdmax"}
    out=${out//\[BIRD-IMAGES\]/"$birdimages"}
    out=${out//\[BIRD-TIME\]/"$birdtime"}
    out=${out//\[BIRD-TIME-AVG\]/"$birdtimeavg"}
    out=${out//\[BIRD-TIME-MAX\]/"$birdtimemax"}

    printf '%s\n' "$out"
}

### INIT END ###


#### INTRO ####
echo "---------------------------------------------------------------------------"
echo "INTRO"
echo "---------------------------------------------------------------------------"

# Create working directory
if mkdir -p "$wdir"; then
    echo "Successfully created $wdir."
else
    echo "Unable to create $wdir."
    exit 1
fi

## INTRO END ##

#### LOOP ####
echo "---------------------------------------------------------------------------"
echo "Loop through capturing images until sunset every $INTERVAL seconds"
echo "or for $z pictures if debug ($debug) is on." 
echo "---------------------------------------------------------------------------"

while [ "$fin" -eq 1 ]; do
    # Remember when this iteration started; the sleep time is derived from it below
    tnow1=$(date +%H:%M:%S)
    snow1=$(date +%s)

    # Format picture number
    n=$(printf "%05d" $i)

    # Capture image. A failed picture is skipped and its number is used again,
    # so the numbering stays without gaps for the video creation.
    picok=1
    if "$CAMERA_CMD" -n --width "$RESW" --height "$RESH" --output "$wdir/pic_$n.jpg"; then
        echo "Successfully created picture $i as $wdir/pic_$n.jpg."
    else
        echo "Unable to create picture $i as $wdir/pic_$n.jpg. Skipping this picture."
        rm -f "$wdir/pic_$n.jpg"
        picok=0
    fi

    # Count the birds on the picture if enabled in config. A failed detection
    # does not discard the picture; the count is shown as "?" in that case.
    if [ "$picok" -eq 1 ] && [ "$BIRD_DETECTION_ENABLED" -eq 1 ]; then
        birdargs=(--model "$BIRD_MODEL" --size "$BIRD_MODEL_SIZE" --classes "$BIRD_CLASSES"
                  --confidence "$BIRD_CONFIDENCE" --tiles "$BIRD_TILES")
        # Draw a frame around each bird directly into the picture
        [ "$BIRD_DRAW_BOXES" -eq 1 ] && birdargs+=(--annotate "$wdir/pic_$n.jpg")

        # Measure how long the detection takes, including the start of Python
        # and the loading of the model: this is the time added to each picture
        msbird=$(date +%s%3N)
        if birds=$(python3 "$BIRD_SCRIPT" "$wdir/pic_$n.jpg" "${birdargs[@]}") && [[ "$birds" =~ ^[0-9]+$ ]]; then
            bird_state_add "$birds"
        else
            echo "* bird detection failed on picture $i."
            birds="?"
        fi
        msbird=$(( $(date +%s%3N) - msbird ))

        birdruns=$((birdruns + 1))
        msbirdsum=$((msbirdsum + msbird))
        [ "$msbird" -gt "$msbirdmax" ] && msbirdmax=$msbird
        birdtime=$(ms_to_s "$msbird")
        birdtimeavg=$(ms_to_s $((msbirdsum / birdruns)))
        birdtimemax=$(ms_to_s "$msbirdmax")
        echo "* bird detection: $birds on picture $i, took $birdtime s (average $birdtimeavg s, longest $birdtimemax s). Today: $birdsum in total, most on one picture $birdmax."
    fi

    # Add text overlay text to image if enabled in config
    if [ "$picok" -eq 1 ] && [ "$OVERLAY_ENABLED" -eq 1 ]; then

        echo "* overlay is enabled."
        
        # Time Date Stamp for overlay
        tsoverlay=$(date "+%d.%m.%Y %H:%M:%S")

        # Get system temperature
        temp=$(cat /sys/class/thermal/thermal_zone0/temp)
        obrdtmp=$(echo "scale=2; $temp / 1000" | bc)

        # Retrieve weather if enabled
        weather=""
        if [ "$WEATHER_ENABLED" -eq 1 ]; then
            echo "* weather is enabled."
            if [ -f "$WFILE" ]; then
                weather=$(cat "$WFILE")
            else
                echo "Weather file $WFILE not found. Skipping weather information."
            fi
        fi

        # Prepare text overlay; replace placeholders
        otext=$(replace_placeholders "$OVERLAY_TEXT")
        # In debug mode the duration of the bird detection is shown on the picture,
        # unless the overlay text already contains it
        if [ "$debug" -eq 1 ] && [ "$BIRD_DETECTION_ENABLED" -eq 1 ] && [[ "$OVERLAY_TEXT" != *"[BIRD-TIME]"* ]]; then
            otext="$otext | Detection: $birdtime s"
        fi

        echo "Overlay text parsed:"
        echo "$otext"

        # Write the text to a file. overlay.py and ffmpeg read it as it is,
        # so special characters in the text do not need to be escaped.
        if [ "$overlaypil" -eq 1 ]; then
            printf '%s' "$otext" > "$wdir/overlay.txt"
            overlaycmd=(python3 "$OVERLAY_SCRIPT" "$wdir/pic_$n.jpg" "$wdir/pic_txt_$n.jpg" --text-file "$wdir/overlay.txt"
                        --font "$ofont" --size "$OVERLAY_SIZE" --max-lines "$OVERLAY_MAX_LINES" --position "$OVERLAY_POSITION"
                        --margin "$OVERLAY_MARGIN" --box "$OVERLAY_BOX" --color "$OVERLAY_COLOR" --icons "$OVERLAY_ICONS")
            [ "$debug" -eq 1 ] && overlaycmd+=(--verbose)
        else
            # ffmpeg cannot measure the text beforehand: the size is estimated from
            # the number of characters, and the text is never moved past the left border
            otext=$(printf '%s' "$otext" | sed -E 's/\[ICON-[A-Za-z0-9_-]+\] ?//g')
            printf '%s' "$otext" > "$wdir/overlay.txt"
            omargin=$(echo "$RESH * $OVERLAY_MARGIN / 100" | bc)
            ofsize=$(echo "s = $RESH * $OVERLAY_SIZE / 100; f = ($RESW - 2 * $omargin) / (${#otext} * 0.6); if (f < s) s = f; if (s < 8) s = 8; scale=0; s / 1" | bc -l)
            opad=$((ofsize / 3))
            omargin=$((omargin + opad))
            case "$OVERLAY_POSITION" in
                *-left)   ox="$omargin" ;;
                *-center) ox="max($omargin\,(w-tw)/2)" ;;
                *)        ox="max($omargin\,w-tw-$omargin)" ;;
            esac
            case "$OVERLAY_POSITION" in
                top-*) oy="$omargin" ;;
                *)     oy="h-th-$omargin" ;;
            esac
            obox="box=1:boxcolor=black@$(echo "scale=2; $OVERLAY_BOX / 100" | bc):boxborderw=$opad"
            [ "$OVERLAY_BOX" -lt 25 ] && obox="borderw=$((ofsize / 16 + 1)):bordercolor=black"
            overlaycmd=(ffmpeg -hide_banner -loglevel panic -y -i "$wdir/pic_$n.jpg" -q:v 2
                        -vf "drawtext=fontfile='$ofont':textfile='$wdir/overlay.txt':expansion=none:fontcolor=$OVERLAY_COLOR:fontsize=$ofsize:$obox:x=$ox:y=$oy"
                        "$wdir/pic_txt_$n.jpg")
        fi

        # Add text overlay to image
        if "${overlaycmd[@]}"; then
            echo "Successfully added text to picture $i as $wdir/pic_txt_$n.jpg."
        else
            echo "Unable to add text to picture $i as $wdir/pic_txt_$n.jpg. Skipping this picture."
            rm -f "$wdir/pic_$n.jpg" "$wdir/pic_txt_$n.jpg"
            picok=0
        fi
    fi

    # Count the picture, or give up after too many failures in a row
    if [ "$picok" -eq 1 ]; then
        ipics=$((ipics + 1))
        fails=0
        i=$((i + 1))
    else
        fails=$((fails + 1))
        echo "Failed pictures in a row: $fails of $MAX_CAPTURE_FAILS allowed."
        if [ "$fails" -ge "$MAX_CAPTURE_FAILS" ]; then
            echo "Too many failed pictures in a row. EXIT continuous image creation."
            break
        fi
    fi

    # Check if it's time to end the loop or to wait for the next interval
    if [ "$debug" -eq 1 ]; then
        echo "Debugging mode is on. Pictures created: $ipics. Maximum pictures: $z."
        if [ "$ipics" -ge "$z" ]; then
            echo "Setting exit flag."
            fin=0
        fi

    elif [ "$snow1" -gt "$sendtime" ]; then
        echo "It is $tnow1 ($snow1). $sendtime is the time to exit the loop. EXIT continuous image creation."
        fin=0
    else
        fin=1

        # Sleep for the rest of the interval: interval minus the time this iteration took
        selapsed=$(( $(date +%s) - snow1 ))
        [ "$selapsed" -gt "$INTERVAL" ] && slowpics=$((slowpics + 1))
        tsleep=$((INTERVAL - selapsed))
        tsleep=$((tsleep < 0 ? 0 : tsleep))
        echo "Interval is $INTERVAL s, this iteration took $selapsed s. Sleeping for $tsleep second(s)..."
        sleep "$tsleep"
    fi

done

## LOOP END ##

rm -f "$wdir/overlay.txt"

# From here on the counter holds the number of pictures created
i=$ipics

# Summary of the capture
echo "---------------------------------------------------------------------------"
echo "Pictures created: $ipics."
if [ "$birdruns" -gt 0 ]; then
    echo "Bird detection today: $birdsum birds on all pictures added up, most birds on one picture $birdmax, pictures with birds $birdimages."
    echo "Bird detection time per picture: average $birdtimeavg s, longest $birdtimemax s."
fi
if [ "$slowpics" -gt 0 ]; then
    echo "WARNING: $slowpics picture(s) took longer than the interval of $INTERVAL s, so they were taken late."
    echo "Increase INTERVAL, or reduce BIRD_TILES or use a smaller model if the bird detection is enabled."
fi

if [ "$ipics" -eq 0 ]; then
    echo "No picture was created. Exiting."
    rmdir "$wdir" 2>/dev/null
    exit 1
fi


### Video ###
echo "---------------------------------------------------------------------------"
echo "Create Video from $i pictures. Please wait a while..."
echo "---------------------------------------------------------------------------"

finfile="${vidpref}_${tsfriendly}"

# Use the pictures with text overlay if enabled, the plain pictures otherwise
if [ "$OVERLAY_ENABLED" -eq 1 ]; then
    vidinput="$wdir/pic_txt_%05d.jpg"
else
    vidinput="$wdir/pic_%05d.jpg"
fi

# Create video
if ffmpeg -hide_banner -loglevel panic -r "$fr" -i "$vidinput" "$wdir/$finfile.mp4"; then
    echo "Successfully created final video as $wdir/$finfile.mp4."
else
    echo "Unable to create final video as $wdir/$finfile.mp4."
    exit 1
fi

## Video END ##


#### OUTRO ####
echo "---------------------------------------------------------------------------"
echo "OUTRO"
echo "---------------------------------------------------------------------------"

# Track upload results: the working directory is only deleted after a successful upload
uploads_ok=0
uploads_failed=0

# Optional SCP upload
if [ "$SCP_UPLOAD_ENABLED" -eq 1 ] && ([ "$debug" -eq 0 ] || [ "$FORCE_SCP_UPLOAD" -eq 1 ]); then
    echo "Uploading video to remote server..."
    if scp "$wdir/$finfile.mp4" "$SCP_SERVER_PATH"; then
        echo "Successfully uploaded video to remote server."
        uploads_ok=$((uploads_ok + 1))
    else
        echo "Unable to upload video to remote server."
        uploads_failed=$((uploads_failed + 1))
    fi
else
    echo "No remote server upload since upload is disabled or debug mode is enabled."
fi

# Optional YouTube upload
if [ "$YOUTUBE_UPLOAD_ENABLED" -eq 1 ] && ([ "$debug" -eq 0 ] || [ "$FORCE_YT_UPLOAD" -eq 1 ]); then
    echo "Preparing to upload to YouTube..."

    # Replace placeholders in title
    YOUTUBE_TITLE=$(replace_placeholders "$YOUTUBE_TITLE")
    echo "YouTube title: $YOUTUBE_TITLE"

    # Replace placeholders in description
    YOUTUBE_DESC=$(replace_placeholders "$YOUTUBE_DESC")
    echo "YouTube description: $YOUTUBE_DESC"

    # Call youtube-upload script
    if python3 "$YOUTUBE_SCRIPT_PATH" \
        --videofile="$wdir/$finfile.mp4" \
        --title="$YOUTUBE_TITLE" \
        --description="$YOUTUBE_DESC" \
        --category="$YOUTUBE_CATEGORY" \
        --keywords="$YOUTUBE_TAGS" \
        --privacyStatus="$YOUTUBE_PRIVACY" \
        --latitude="$LAT" \
        --longitude="$LONG" \
        --playlistId="$PLAYLIST" \
        --language="$YOUTUBE_LANGUAGE"; then
        echo "Successfully uploaded video to YouTube."
        uploads_ok=$((uploads_ok + 1))
    else
        echo "Unable to upload video to YouTube."
        uploads_failed=$((uploads_failed + 1))
    fi
else
    echo "No youtube upload since upload is disabled or debug mode is enabled and upload not forced."
fi

# Cleanup: keep the video unless it is safely stored somewhere else
exitcode=0
if [ "$debug" -ne 0 ]; then
    echo "Won't delete directory $wdir as debugging is enabled."
elif [ "$uploads_failed" -gt 0 ]; then
    echo "$uploads_failed upload(s) failed. Keeping $wdir/$finfile.mp4 for a manual upload."
    exitcode=1
elif [ "$uploads_ok" -eq 0 ]; then
    echo "No upload was done. Keeping $wdir/$finfile.mp4."
else
    echo "Deleting temp directory $wdir."
    rm -r "$wdir"
fi

echo "---------------------------------------------------------------------------"
echo "** All done. **"
echo "==========================================================================="

exit "$exitcode"