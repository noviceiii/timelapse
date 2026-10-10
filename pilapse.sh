#!/bin/bash

# Raspi Time Lapse from sunrise to sunset with text overlay,
# Backup on remote Linux server, upload to YouTube.
# Requires libcamera and hdate.

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

# Timestamp for filenames and directories
ts_path=$(date +%Y-%m-%d_%H%M%S)
tsfriendly=$(date +%d.%m.%Y)

# Working directory
wdir="$TDIR/$ts_path"
resxy="${RESW}x${RESH}"                             # Image/video size
fr=$(echo "scale=0; 1/$DT" | bc)                    # Calculate frame rate

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
IFS='|' read -r time description <<< "$overridden_start"
if [ -n "$time" ]; then
    echo "Overriding start time with $time. Description: $description"
    sstarttime=$(date +%s -d "$time")
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
IFS='|' read -r time description <<< "$overridden_end"
if [ -n "$time" ]; then
    echo "Overriding end time with $time. Description: $description"
    sendtime=$(date +%s -d "$time")
else
    sendtime=$((ssunset + send))
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
    local input_string="$1"
    local output_string="$input_string"

    # leading zero for image count
    local formatted_i=$(printf "%05d" "$i")

    output_string=$(echo "$output_string" | sed "s|\[SUNRISE\]|$sunrise|")
    output_string=$(echo "$output_string" | sed "s|\[FIRSTLIGHT\]|$first_light|")
    output_string=$(echo "$output_string" | sed "s|\[START-OFFSET\]|$offSTART|")
    output_string=$(echo "$output_string" | sed "s|\[SUNSET\]|$sunset|")
    output_string=$(echo "$output_string" | sed "s|\[SUNSET-OFFSET\]|$offEND|")
    output_string=$(echo "$output_string" | sed "s|\[EVENT-DESCRIPTION\]|$description|")
    output_string=$(echo "$output_string" | sed "s|\[IMAGE-COUNT\]|$i|")
    output_string=$(echo "$output_string" | sed "s|\[IMAGE-COUNT-FORMATED\]|$formatted_i|")
    output_string=$(echo "$output_string" | sed "s|\[INTERVAL\]|$INTERVAL|")
    output_string=$(echo "$output_string" | sed "s|\[HEIGHT\]|$RESH|")
    output_string=$(echo "$output_string" | sed "s|\[LENGTH\]|$RESW|")
    output_string=$(echo "$output_string" | sed "s|\[FRAMERATE\]|$fr|")
    output_string=$(echo "$output_string" | sed "s|\[FORMATED_DATE\]|$tsfriendly|")
    output_string=$(echo "$output_string" | sed "s|\[FORMATED_DATETIME\]|$tsoverlay|")
    output_string=$(echo "$output_string" | sed "s|\[INT-TEMP\]|$obrdtmp|")
    output_string=$(echo "$output_string" | sed "s|\[WEATHER\]|$weather|")
    output_string=$(echo "$output_string" | sed "s|\[LAT\]|$LAT|")
    output_string=$(echo "$output_string" | sed "s|\[LONG\]|$LONG|")
    output_string=$(echo "$output_string" | sed "s|\[PLAYLIST\]|$PLAYLIST|")
    output_string=$(echo "$output_string" | sed "s|\[YOUTUBE-CATEGORY\]|$YOUTUBE_CATEGORY|")
    output_string=$(echo "$output_string" | sed "s|\[YOUTUBE-LANGUAGE\]|$YOUTUBE_LANGUAGE|")
    output_string=$(echo "$output_string" | sed "s|\[YOUTUBE-PRIVACY\]|$YOUTUBE_PRIVACY|")
    output_string=$(echo "$output_string" | sed "s|\[YOUTUBE-TAGS\]|$YOUTUBE_TAGS|")

    echo "$output_string"
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
    if libcamera-jpeg -n --width "$RESW" --height "$RESH" --output "$wdir/pic_$n.jpg"; then
        echo "Successfully created picture $i as $wdir/pic_$n.jpg."
    else
        echo "Unable to create picture $i as $wdir/pic_$n.jpg. Skipping this picture."
        rm -f "$wdir/pic_$n.jpg"
        picok=0
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
        # Prepare text overlay; escape special characters
        otext=${otext//:/\\:}
        otext=${otext//,/\\,}
        otext=${otext//|/\\|}
        otext=${otext//°/\\°}
        otext=${otext//(/\\(}
        otext=${otext//)/\\)}
        otext=${otext//#/\\#}
        otext=${otext//\!/\\!}
        otext=${otext//\?/\\?}
        otext=${otext//%/\\\\%}

        echo "Overlay text parsed:"
        echo "$otext"

        # Test if font file exists
        if [ -f "$FPATH" ]; then
            echo "Font file $FPATH found. Prooceed."
        else
            echo "Font file $FPATH not found. Exiting."
            exit 1
        fi

        # Add text overlay to image
        if ffmpeg -hide_banner -loglevel panic -i "$wdir/pic_$n.jpg" \
            -vf "drawtext=fontfile='$FPATH':text='$otext':fontcolor=white:fontsize=48:box=1:boxcolor=black@0.5:boxborderw=5:x=w-tw-10:y=h-th-50" "$wdir/pic_txt_$n.jpg"; then
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
        tsleep=$((INTERVAL - selapsed))
        tsleep=$((tsleep < 0 ? 0 : tsleep))
        echo "Interval is $INTERVAL s, this iteration took $selapsed s. Sleeping for $tsleep second(s)..."
        sleep "$tsleep"
    fi

done

## LOOP END ##

# From here on the counter holds the number of pictures created
i=$ipics

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