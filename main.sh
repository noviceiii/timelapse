#!/bin/bash

#   Raspii Time Lapse from sunrise to sunset with text overlay,
#   Backup on remote linux server, upload to youtube.
#   Version 3.3, December 27th 2023 by Oliver.

#   Please see credits, sources and help on github.
#
#   Mind, for a 1k (HD) resolution, 1 second interval and 25 frames
#   it requires around 25GB of processing space.
#
#   Change below values accorings your needs.

#   CODE BEFORE OPTIMISATION


INTERVAL=15                                         # INT. take picture in that interval in seconds
offSTART=1                                          # INT. Offset Hour to start before sunrise
offEND=2                                            # INT. Offset Hour to quit after sunset
RESW="3280"                                         # STRING. resolution width. 1920 should work.
RESH="2464"                                         # STRING. resolution height. 1080 should work.
DT=0.020                                            # FLOAT. Time to display one picture in seconds (0.040 equals to 25 frames per second)
vidpref="Solothurn_Timelapse"                       # STRING. Prefix for final video name.
LONG="47.2333"					    # String. Longitude
LAT="7.5167"					    # STRING. Lattitude
TIZO="2"					    # STRING. Timezone 
TDIR="/tmp"                                         # STRING. temporary directory
FPATH="/opt/timelapse/Roboto-Regular.ttf"           # STRING. full path to font file. Optain from google fonts
WFILE="/opt/timelapse/weather.txt"                  # STRING. full path to file with weather information

debug=0                                             # BOOLEAN. 1 to enable. Ignores time dependend start and stop.
z=2                                                 # INT. Number of pictures to create in debug mode. 
fupload=0					    # BOOLEAN. 1 to enable. Force video upload despite debug mode.

# ------------------------------------------------------------------------------------------------------------------------------------------- 

#### INIT ####
echo "** INIT"
#    set parameters and init program

ts_path=`date +%Y-%m-%d_%H%M%S`             # time stamp for filenames and directories

wdir="$TDIR/$ts_path"                       # full path to temporary work directory
resxy="${RESW}x${RESH}"                     # image/video size in HEIGHTxWIDTH
fr=`echo 1/${DT} | bc`                      # calculate frame rate by the picture display time

fin=1                                       # exit parameter in loop
i=1                                         # counter for current iteration
j=1                                         # counter for current iteration

tnow1=$(date +%H:%M:%S)                     # current time in HH:MM
snow1=$(date +%s -d "${tnow1}")             # current time in seconds
tnow2=$(date +%H:%M:%S) 
snow2=$(date +%s -d "${tnow2}")

# Get sunrise and sunset raw data from weather.com
# sun_times=$( curl -s  https://weather.com/weather/today/l/$LOCATION sed 's/<span/\n/g' | sed 's/<\/span>/\n/g'  |\
# grep -E "dp0-details-sunrise|dp0-details-sunset" | tr -d '\n' | sed 's/>/ /g' | cut -d " " -f 4,8 )

# Extract sunrise and sunset times and convert to 24 hour format
# tsunrise=$(date --date="`echo $sun_times | awk '{ print $1}'` AM" +%R)
# tsunset=$(date --date="`echo $sun_times | awk '{ print $2}'` PM" +%R)
sunrisesunset=`hdate -q -s -S -l $LONG -L $LAT -z$TIZO`
tsunrise=`echo $sunrisesunset | awk '{ print $6}'`
tsunset=`echo $sunrisesunset | awk '{ print $8}'`

# to seconds
ssunrise=`date +%s -d ${tsunrise}`
ssunset=`date +%s -d ${tsunset}`

# calculate when to start and end the script
# it is from sunrise to sunset plus/minus the offsets
sstart=$((offSTART*3600))
sstarttime=$(( ssunrise - sstart ))         # when to start the script in seconds
send=$((offEND*3600))
sendtime=$(( ssunset + send ))              # when to end the script in seconds

# wait until sunset minus offset to start, if needed
if [ $debug -gt 0 ]; then
    echo "Debugging mode is on. Starting imedately."
else
    offwait=$(( sstarttime - snow1 )) 
    if [ $offwait -lt 0 ]; then
        offwait=0
    fi
    echo "Sunrise at $ssunrise ($tsunrise). Sunset at $ssunset ($tsunset). Offset $offSTART hrs. It is $tnow1. Waiting $offwait second(s)..."
    sleep $offwait
fi

### INIT END ##


#### INTRO ####
echo "** INTRO"
#    It requires an initial picture and video to begin with.

# create working directory
if mkdir -p "$wdir" ; then
    echo "Successfully created $wdir."
else
    echo "Unable to create $wdir."
    exit
fi

## INTRO END #


#### LOOP ####
echo "** LOOP"
#    ongoing picture and video creation.
#    Exits when sunset (plus offset time) is reached.

while [ $fin -eq 1 ]
do
    # calculate running time
    sdiff=$(( snow2 - snow1 ))
    tsleep=$(( INTERVAL - sdiff ))
    
    # wait for the interval time
    # minus the past processing time
    if [ $tsleep -lt 0 ]; then
        tsleep=0
    fi

    echo "Interval is $INTERVAL, difference is $sdiff ($snow2 - $snow1). Sleeping for $tsleep second(s)..."
    sleep $tsleep

    tnow1=$(date +%H:%M:%S) 
    snow1=$(date +%s -d "${tnow1}")

    # format counters with leading zeros
    n=`printf "%05d" $i`

    # read weather file
    weather=`cat ${WFILE}`

    # time
    tsoverlay=`date "+%d.%m.%Y %H:%M:%S"`

    # get raspii onboard temp
    # obrdtmp=`/opt/vc/bin/vcgencmd measure_temp | cut -d "=" -f2`
    temp=`cat /sys/class/thermal/thermal_zone0/temp`
    obrdtmp=`echo "scale=2; $temp / 1000" | bc -l`
    
    # create overlay text and escape special chars 
    otext="$tsoverlay | Sunrise: $tsunrise | Sunset: $tsunset | $weather | Int. Tmp: $obrdtmp °C | $n"
    otext="${otext//:/\\:}"
    otext="${otext//|/\\|}"
    otext="${otext//°/\\°}"
    otext="${otext//\'/\\°}"
    otext="${otext//%/\\\\%}"
    otext="${otext////\\/}"

    echo "Overlay Text => $otext"

    # create a picture
    raspistill -w $RESW -h $RESH -q 100 -ex auto -awb auto -mm average -drc low -o "$wdir/pic_$n.jpg"
    if [ $? -eq 0 ]; then
        echo "Successfully created picture $i as $wdir/pic_$n.jpg."
    else
        echo "Unable to create pciture $i as $wdir/pic_$n.jpg."
        exit
    fi

    # add text to picture
    ffmpeg -loglevel panic -i "$wdir/pic_$n.jpg" \
    -vf drawtext="fontfile=$FPATH: \
    text='$otext': fontcolor=white: fontsize=48: box=1: boxcolor=black@0.5: \
    boxborderw=5: x=w-tw-10: y=h-th-10" \
    -y "$wdir/pic_txt_$n.jpg"

    if [ $? -eq 0 ]; then
        echo "Successfully added text to picture $i as $wdir/pic_txt_$n.jpg."
    else
        echo "Unable to add text to picture $i as $wdir/pic_txt_$n.jpg."
        exit
    fi

    # just one more
    i=`expr 1 + ${i}`

    # set time 
    tnow2=$(date +%H:%M:%S)
    snow2=$(date +%s -d "${tnow2}")

    # set fin to 0 if end of day is reached. This will exit the loop.
    if [ $debug -gt 0 ]; then
        echo "Debugging mode is on. Current iteration: $i."
        if [ $i -eq $z ]; then
            echo "Setting exit flag."
            fin=0
        fi
    elif [ $snow1 -gt $sendtime ]; then
        echo "$tnow1 is the time to exit the loop. Sunset at $tsunset. Offset $offEND hrs. Exit continious image creation."
        fin=0
    fi

done

## LOOP END #


### Video ###
#    Create video picture by picture to save memory
echo "** Create Video of $n pictures."

tsfriendly=`date +%d.%m.%Y`
finfile=${vidpref}_${tsfriendly}

# create video
ffmpeg -r ${fr} -i "$wdir/pic_txt_%05d.jpg" "$wdir/$finfile.mp4"

if [ $? -eq 0 ]; then
    echo "Successfully created final video as $wdir/$finfile.mp4."
else
    echo "Unable to create final video from as $wdir/$finfile.mp4."
    exit
fi

## Video END #


#### OUTRO ####
echo "** OUTRO"

# upload final video
if [ $debug -eq 1 -a $fupload -eq 0 ]; then
    echo "Won't upload video as debugging is enabled and upload not forced."
else
    # copy video file to backup
    scp "$wdir/$finfile.mp4" picam@plexxor.dmz.t9t.ch:/multimedia/timelapse/

    # youtube meta data
    YDESC="Zeitraffer von Solothurn, Schweiz. Von Sonnenaufgang ${tsunrise} (-${offSTART}h) bis Sonnenuntergang ${tsunset} (+${offEND}h) sind \
    $i Bilder alle $INTERVAL Sekunde(n) in $resxy auf dem Raspberry Pi 3 erstellt worden. Framerate ist ${fr}. \
    Das Video wird automatisch generiert und auf Youtube geladen. \
    Details auf Github: https://github.com/noviceiii/RaspiTimeLaps."

    # TODO CUSTOM STRINGS. For now, change below
    # upload to youtube
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
fi

if [ $debug -eq 1 ]; then
    echo "Won't delete directory $wdir as debugging is enabled."
else
    echo "Deleting temp directory $wdir."
    rm -r "$wdir"
fi

echo "** All done. Like tears in the rain. **"

