#!/bin/bash

# Raspi Time Lapse from sunrise to sunset with text overlay, 
# Backup on remote Linux server, upload to YouTube.
# Version 3.3, updated by Oliver.

# Please see credits, sources, and help on GitHub.
# Note: For 1K (HD) resolution at 1-second intervals and 25 fps, 
# about 25GB of processing space is required.

# CLEANED BY GROK

# Configuration Variables
INTERVAL=15                                         # Interval for taking pictures (seconds)
offSTART=1                                          # Offset hours before sunrise to start
offEND=2                                            # Offset hours after sunset to end
RESW="3280"                                         # Image width resolution
RESH="2464"                                         # Image height resolution
DT=0.020                                            # Display time for each picture (in seconds)
vidpref="Solothurn_Timelapse"                       # Prefix for final video name
LONG="47.2333"                                      # Longitude for location
LAT="7.5167"                                        # Latitude for location
TIZO="2"                                            # Timezone offset
TDIR="/tmp"                                         # Temporary directory
FPATH="/opt/timelapse/Roboto-Regular.ttf"           # Path to font file
WFILE="/opt/timelapse/weather.txt"                  # Path to weather information file

debug=0                                             # Enable debug mode
z=2                                                 # Number of pictures for debug mode
fupload=0                                           # Force upload in debug mode

# Script Initialization
echo "** INIT"
ts_path=$(date +%Y-%m-%d_%H%M%S)                # Timestamp for directories and files
wdir="$TDIR/$ts_path"                           # Working directory
resxy="${RESW}x${RESH}"                         # Resolution string
fr=$(echo "scale=0; 1/$DT" | bc)                # Calculate frame rate

fin=1                                           # Flag to continue loop
i=1                                             # Picture counter
j=1                                             # Unused counter, consider removing if not needed

# Current time in seconds
tnow1=$(date +%H:%M:%S)
snow1=$(date +%s -d "$tnow1")
tnow2=$(date +%H:%M:%S)
snow2=$(date +%s -d "$tnow2")

# Get sunrise and sunset times
sunrisesunset=$(hdate -q -s -S -l $LONG -L $LAT -z$TIZO)
tsunrise=$(echo "$sunrisesunset" | awk '{print $6}')
tsunset=$(echo "$sunrisesunset" | awk '{print $8}')

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
    offwait=$((offwait < 0 ? 0 : offwait)) # Ensure positive wait time
    echo "Sunrise at $ssunrise ($tsunrise). Sunset at $ssunset ($tsunset). Offset $offSTART hrs. It is $tnow1. Waiting $offwait second(s)..."
    sleep "$offwait"
else
    echo "Debugging mode is on. Starting immediately."
fi

# Create working directory
echo "** INTRO"
if mkdir -p "$wdir"; then
    echo "Successfully created $wdir."
else
    echo "Unable to create $wdir."
    exit 1
fi

# Main Loop for capturing images
echo "** LOOP"
while [ $fin -eq 1 ]; do
    # Calculate sleep time based on last image capture
    sdiff=$((snow2 - snow1))
    tsleep=$((INTERVAL - sdiff))
    tsleep=$((tsleep < 0 ? 0 : tsleep)) # Ensure non-negative sleep time

    echo "Interval is $INTERVAL, difference is $sdiff ($snow2 - $snow1). Sleeping for $tsleep second(s)..."
    sleep "$tsleep"

    tnow1=$(date +%H:%M:%S)
    snow1=$(date +%s -d "$tnow1")

    # Format picture number
    n=$(printf "%05d" $i)

    # Retrieve weather and system temperature
    weather=$(cat "$WFILE")
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
    if raspistill -w "$RESW" -h "$RESH" -q 100 -ex auto -awb auto -mm average -drc low -o "$wdir/pic_$n.jpg"; then
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

    tnow2=$(date +%H:%M:%S)
    snow2=$(date +%s -d "$tnow2")

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

# Video Creation
echo "** Create Video of $i pictures."
tsfriendly=$(date +%d.%m.%Y)
finfile="${vidpref}_${tsfriendly}"

if ffmpeg -r $fr -i "$wdir/pic_txt_%05d.jpg" "$wdir/$finfile.mp4"; then
    echo "Successfully created final video as $wdir/$finfile.mp4."
else
    echo "Unable to create final video as $wdir/$finfile.mp4."
    exit 1
fi

# Outro - Upload and Cleanup
echo "** OUTRO"
if [ $debug -eq 0 ] || [ $fupload -eq 1 ]; then
    # Upload video to server
    scp "$wdir/$finfile.mp4" picam@plexxor.dmz.t9t.ch:/multimedia/timelapse/

    # Prepare YouTube metadata
    YDESC="Zeitraffer von Solothurn, Schweiz. Von Sonnenaufgang ${tsunrise} (-${offSTART}h) bis Sonnenuntergang ${tsunset} (+${offEND}h) sind \
    $i Bilder alle $INTERVAL Sekunde(n) in $resxy auf dem Raspberry Pi 3 erstellt worden. Framerate ist ${fr}. \
    Das Video wird automatisch generiert und auf Youtube geladen. \
    Details auf Github: https://github.com/noviceiii/RaspiTimeLaps."

    # YouTube upload
    /usr/local/bin/youtube-upload \
    --title="Solothurn Zeitraffer $tsfriendly" \
    --description="$YDESC" \
    --tags="Solothurn, Zeitraffer" \
    --default-language="de" \
    --default-audio-language="de" \
    --client-secrets="/home/pi/client_secrets.json" \
    --credentials-file="/home/pi/my_credentials.json" \
    --playlist="Solothurn Zeitraffer" \
    --privacy public \
    --location latitude=47.2066136,longitude=7.5353353 \
    --embeddable=True \
    "$wdir/$finfile.mp4"

    # Cleanup
    if [ $debug -eq 0 ]; then
        echo "Deleting temp directory $wdir."
        rm -r "$wdir"
    fi
else
    echo "Won't upload video as debugging is enabled and upload not forced."
    echo "Won't delete directory $wdir as debugging is enabled."
fi

echo "** All done. Like tears in the rain. **"