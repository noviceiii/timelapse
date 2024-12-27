#!/bin/bash

# Raspi Time Lapse from sunrise to sunset with text overlay,
# Backup on remote Linux server, upload to YouTube.
# @Version 4.0, 16.12.2024.
# - .1 - addes support for libcamera

# Configuration file path
CONFIG_FILE="config.cfg"                       # set path to config file

# Read security-relevant variables from config file
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Configuration file $CONFIG_FILE not found. Exiting."
    exit 1
fi

# ------------------------------------------------------------------------------------------------------------------------------------------- 

#### INIT ####
echo "** INIT"

i=1                                                 # Picture counter
fin=1                                               # Flag to continue loop

# Timestamp for filenames and directories
ts_path=$(date +%Y-%m-%d_%H%M%S)

# Working directory
wdir="$TDIR/$ts_path"
resxy="${RESW}x${RESH}"                             # Image/video size
fr=$(echo "scale=0; 1/$DT" | bc)                    # Calculate frame rate

# Current time
tnow1=$(date +%H:%M:%S)
snow1=$(date +%s -d "$tnow1")

# Get sunrise and sunset times
sunrisesunset=`hdate -q -s -S -l $LONG -L $LAT -z$TIZO`
tsunrise=`echo $sunrisesunset | awk '{ print $6}'`
tsunset=`echo $sunrisesunset | awk '{ print $8}'`

# Convert sunrise and sunset to seconds
ssunrise=$(date +%s -d "$tsunrise")
ssunset=$(date +%s -d "$tsunset")

# Calculate script start and end times
sstart=$((offSTART * 3600))
sstarttime=$((ssunrise - sstart))
send=$((offEND * 3600))
sendtime=$((ssunset + send))

# Wait until start time if not in debug mode
if [ $debug -eq 0 ]; then
    offwait=$((sstarttime - snow1))
    offwait=$((offwait < 0 ? 0 : offwait))
    echo "Sunrise at $ssunrise ($tsunrise). Sunset at $ssunset ($tsunset). Offset $offSTART hrs. It is $tnow1. Waiting $offwait second(s)..."
    sleep "$offwait"
else
    echo "Debugging mode is on. Starting immediately."
fi

### INIT END ###


#### INTRO ####
echo "** INTRO"

# Create working directory
if mkdir -p "$wdir"; then
    echo "Successfully created $wdir."
else
    echo "Unable to create $wdir."
    exit 1
fi

## INTRO END ##


#### LOOP ####
echo "** LOOP"

while [ $fin -eq 1 ]; do
    # Calculate sleep time based on last image capture
    tnow2=$(date +%H:%M:%S)
    snow2=$(date +%s -d "$tnow2")
    sdiff=$((snow2 - snow1))
    tsleep=$((INTERVAL - sdiff))
    tsleep=$((tsleep < 0 ? 0 : tsleep))

    echo "Interval is $INTERVAL, difference is $sdiff ($snow2 - $snow1). Sleeping for $tsleep second(s)..."
    sleep "$tsleep"

    tnow1=$(date +%H:%M:%S)
    snow1=$(date +%s -d "$tnow1")

    # Format picture number
    n=$(printf "%05d" $i)

    # Retrieve weather if enabled
    weather=""
    if [ $WEATHER_ENABLED -eq 1 ]; then
        if [ -f "$WFILE" ]; then
            weather=$(cat "$WFILE")
        else
            echo "Weather file $WFILE not found. Skipping weather information."
        fi
    fi

    # Get system temperature
    temp=$(cat /sys/class/thermal/thermal_zone0/temp)
    obrdtmp=$(echo "scale=2; $temp / 1000" | bc)

    # Prepare text overlay
    tsoverlay=$(date "+%d.%m.%Y %H:%M:%S")
    otext="$tsoverlay | Sunrise: $tsunrise | Sunset: $tsunset | $weather | Int. Tmp: $obrdtmp °C | $n"
    otext=${otext//:/\\:}  # Escape special characters for ffmpeg
    otext=${otext//|/\\|}
    otext=${otext//°/\\°}
    otext=${otext//%/\\%}

    echo "Overlay Text => $otext"

    # Capture image
    if rpicam-jpeg -n --width "$RESW" --height "$RESH" --output "$wdir/pic_$n.jpg"; then
        echo "Successfully created picture $i as $wdir/pic_$n.jpg."
    else
        echo "Unable to create picture $i as $wdir/pic_$n.jpg."
        exit 1
    fi

    # Add text overlay to image
    if ffmpeg -loglevel panic -i "$wdir/pic_$n.jpg" \
        -vf "drawtext=fontfile=$FPATH:text='$otext':fontcolor=white:fontsize=48:box=1:boxcolor=black@0.5:boxborderw=5:x=w-tw-10:y=h-th-10" \
        -y "$wdir/pic_txt_$n.jpg"; then
        echo "Successfully added text to picture $i as $wdir/pic_txt_$n.jpg."
    else
        echo "Unable to add text to picture $i as $wdir/pic_txt_$n.jpg."
        exit 1
    fi

    i=$((i + 1))

    # Check if it's time to end the loop
    if [ $debug -eq 1 ]; then
        echo "Debugging mode is on. Current iteration: $i."
        if [ $i -gt $z ]; then
            echo "Setting exit flag."
            fin=0
        fi
    elif [ $snow1 -gt $sendtime ]; then
        echo "$tnow1 is the time to exit the loop. Sunset at $tsunset. Offset $offEND hrs. Exit continuous image creation."
        fin=0
    fi
done

## LOOP END ##


### Video ###
echo "** Create Video of $i pictures."

tsfriendly=$(date +%d.%m.%Y)
finfile="${vidpref}_${tsfriendly}"

# Create video
if ffmpeg -r "$fr" -i "$wdir/pic_txt_%05d.jpg" "$wdir/$finfile.mp4"; then
    echo "Successfully created final video as $wdir/$finfile.mp4."
else
    echo "Unable to create final video as $wdir/$finfile.mp4."
    exit 1
fi

## Video END ##


#### OUTRO ####
echo "** OUTRO"

# Optional SCP upload
if [ $SCP_UPLOAD_ENABLED -eq 1 ] && [ $debug -eq 0 ]; then
    echo "Uploading video to remote server..."
    scp "$wdir/$finfile.mp4" "$SCP_SERVER_PATH"
else
    echo "No remote server upload since upload is disabled or debug mode is enabled."
fi

# Optional YouTube upload
if [ $YOUTUBE_UPLOAD_ENABLED -eq 1 ] && [ $debug -eq 0 ]; then
    echo "Preparing to upload to YouTube..."
    # Prepare YouTube metadata
    YDESC=$(printf "$YDESC" "$tsunrise" "$offSTART" "$tsunset" "$offEND" "$i" "$RESW" "$RESH" "$fr")

    # YouTube upload
    youtube-upload \
    --title="Solothurn Zeitraffer $tsfriendly" \
    --description="$YDESC" \
    --tags="Solothurn, Zeitraffer" \
    --default-language="de" \
    --default-audio-language="de" \
    --client-secrets="$CLIENT_SECRETS" \
    --credentials-file="$CREDENTIALS_FILE" \
    --playlist="$PLAYLIST" \
    --privacy public \
    --location latitude=$LATITUDE,longitude=$LONGITUDE \
    --embeddable=True \
    "$wdir/$finfile.mp4"
else
    echo "No youtube upload since upload is disabled or debug mode is enabled."
fi

# Cleanup
if [ $debug -eq 0 ]; then
    echo "Deleting temp directory $wdir."
    rm -r "$wdir"
else
    echo "Won't delete directory $wdir as debugging is enabled."
fi

echo "** All done. **"