# Raspi Time Lapse Script

`pilapse.sh` takes pictures on a Raspberry Pi from sunrise to sunset, writes a text onto each picture, builds a time-lapse video from them, saves the video on a remote server and uploads it to YouTube. It can count the birds on each picture.

Absolutely no warranty for anything given.

## Contents

- [Features](#features)
- [Files](#files)
- [Requirements](#requirements)
- [Setup](#setup)
- [Run](#run)
- [Configuration](#configuration)
- [Placeholders](#placeholders)
- [Bird detection](#bird-detection)
- [What happens when something fails](#what-happens-when-something-fails)
- [Version history](#version-history)

## Features

- **Time-lapse capture**: Takes a picture every few seconds with the Raspberry Pi camera.
- **Sun times**: Starts before sunrise or first light and ends after sunset, each with an offset.
- **Time override**: Sets a fixed start or end time on certain days, e.g. to record until midnight on New Year's Eve.
- **Text overlay**: Writes date, time, sun times, weather, system temperature and more onto each picture.
- **Weather**: Reads the weather from a text file, e.g. written by [Netatmo Weather](https://github.com/noviceiii/netatmoweather).
- **Bird detection**: Counts the birds on each picture, shows the number in the text overlay and frames each bird.
- **Remote backup**: Copies the video to a Linux server with SCP.
- **YouTube upload**: Uploads the video with [YouTube Upload](https://github.com/noviceiii/youtube-upload). Title and description can contain placeholders.

Everything except the capture and the video is optional and switched on in the config file.

## Files

| File | Purpose |
|---|---|
| `pilapse.sh` | The script. |
| `config.example.cfg` | Example configuration. Copy it to `config.cfg`. |
| `detect_birds.py` | Counts the birds on a picture. Called by `pilapse.sh` if the bird detection is enabled. |
| `get_model.sh` | Downloads the model for the bird detection. |

## Requirements

| Needed for | Software | Install on Raspberry Pi OS |
|---|---|---|
| Capture | `rpicam-jpeg` or `libcamera-jpeg` | preinstalled (`rpicam-apps`) |
| Sun times | `hdate` | `sudo apt install hdate` |
| Calculations | `bc` | `sudo apt install bc` |
| Overlay and video | `ffmpeg` | `sudo apt install ffmpeg` |
| Text overlay | a font file (`.ttf`) | e.g. from Google Fonts |
| Weather | a text file with the weather | e.g. [Netatmo Weather](https://github.com/noviceiii/netatmoweather) |
| Remote backup | `scp` with key login to the server | preinstalled |
| YouTube upload | `python3` and [YouTube Upload](https://github.com/noviceiii/youtube-upload) | see that repository |
| Bird detection | `python3` with OpenCV, a model file | `sudo apt install python3-opencv`, then `./get_model.sh` |

The script checks at start that everything needed for the enabled features is there, and stops with a message if not.

## Setup

1. Copy `config.example.cfg` to `config.cfg` in the same directory as `pilapse.sh`.
2. Adjust `config.cfg`, at least the location (`LAT`, `LONG`, `TIZO`) and the features you want.
3. Try it with `debug=1`: the script then starts immediately, takes `z` pictures and keeps all files.
4. Set `debug=0` and start the script before sunrise, e.g. with cron:

```
0 3 * * * /path/to/timelapse/pilapse.sh >> /path/to/timelapse/pilapse.log 2>&1
```

The script waits by itself until the start time. Start it only once per day; a second start while the first one is running fails because the camera is in use.

## Run

```bash
./pilapse.sh
```

What the script does:

1. Reads `config.cfg` and checks the setup.
2. Gets the sun times from `hdate` and calculates start and end time.
3. Waits until the start time (not in debug mode).
4. Takes a picture every `INTERVAL` seconds, counts the birds and writes the text onto the picture, until the end time is reached.
5. Builds the video from the pictures.
6. Uploads the video to the remote server and to YouTube.
7. Deletes the pictures and the video, if the video was uploaded.

All messages go to the standard output. Redirect it to a file to keep a log, as in the cron example above. At the end of the capture a summary is written: number of pictures, bird detection results and times, and a warning if pictures took longer than the interval.

Pictures and video are stored in a subdirectory of `TDIR` named after date and time of the start, e.g. `/tmp/2026-10-10_030000`.

## Configuration

All settings are in `config.cfg`. Each one is explained there; this is the overview.

### Debug

| Setting | Meaning |
|---|---|
| `debug` | `1`: start immediately, take `z` pictures, keep all files, no uploads. `0`: normal run. |
| `z` | Number of pictures in debug mode. |
| `FORCE_SCP_UPLOAD`, `FORCE_YT_UPLOAD` | `1`: upload also in debug mode. |

### Time and location

| Setting | Meaning |
|---|---|
| `LAT`, `LONG` | Location in decimal format, e.g. from [latitudelongitude.org](https://latitudelongitude.org/map-address-latlong). Also used as location of the YouTube video. |
| `TIZO` | Offset to UTC in hours, e.g. `1` for UTC+1. Change it by hand for daylight saving time. |
| `startevent` | `sunrise` or `firstlight`: the event the capture starts at. |
| `offSTART` | Whole hours to start before the start event. |
| `offEND` | Whole hours to continue after sunset. |
| `override_times` | List of fixed start or end times for certain days, see below. |

An entry of `override_times` consists of parts separated by `|`:

| Part | Meaning |
|---|---|
| `y:2025` | Year. Optional; without it the entry applies every year. |
| `m:02` | Month with two digits. Optional; without it the entry applies every month. |
| `d:10` | Day with two digits. Optional; without it the entry applies every day. |
| `e:Start` or `e:End` | Whether the start or the end time is set. |
| `08:15` | The time. |
| `t:Some text` | Description, available as placeholder `[EVENT-DESCRIPTION]`. Must not contain `|`. |

Example: `"m:12|d:31|e:End|23:59|t:New Year's Eve"` ends the capture at 23:59 on every 31 December. The first matching entry is used. Offsets and `startevent` are ignored for an overridden time.

### Capture and video

| Setting | Meaning |
|---|---|
| `INTERVAL` | Whole seconds between two pictures. |
| `RESW`, `RESH` | Width and height of the pictures in pixels. |
| `DT` | Display time of each picture in the video in seconds, between 0 and 1. `0.020` results in 50 pictures per second. |
| `vidpref` | Prefix of the video file name. The date is appended. |
| `TDIR` | Directory for pictures and video. Needs enough space: both the original pictures and the ones with text are stored until the end. |
| `CAMERA_CMD` | Optional. Camera command. If empty, `rpicam-jpeg` is used if available, otherwise `libcamera-jpeg`. |
| `MAX_CAPTURE_FAILS` | Optional. The capture ends after this many failed pictures in a row. Default 10. |

### Text overlay and weather

| Setting | Meaning |
|---|---|
| `OVERLAY_ENABLED` | `1`: write `OVERLAY_TEXT` onto each picture. |
| `FPATH` | Path to the font file. |
| `OVERLAY_TEXT` | The text. Can contain [placeholders](#placeholders). |
| `WEATHER_ENABLED` | `1`: read the weather for the placeholder `[WEATHER]`. |
| `WFILE` | Text file with the weather. Its content is shown as it is. |

### Bird detection

See [Bird detection](#bird-detection).

### Remote server upload

| Setting | Meaning |
|---|---|
| `SCP_UPLOAD_ENABLED` | `1`: copy the video to the server. |
| `SCP_SERVER_PATH` | Target as `user@server:/path/`. The login must work without a password. |

### YouTube upload

| Setting | Meaning |
|---|---|
| `YOUTUBE_UPLOAD_ENABLED` | `1`: upload the video to YouTube. |
| `YOUTUBE_SCRIPT_PATH` | Path to `youtube-upload.py`. |
| `YOUTUBE_TITLE`, `YOUTUBE_DESC` | Title and description. Can contain [placeholders](#placeholders). |
| `PLAYLIST` | ID of the playlist. |
| `YOUTUBE_TAGS` | Tags, comma-separated. |
| `YOUTUBE_CATEGORY` | Category ID. |
| `YOUTUBE_LANGUAGE` | Language of the video. |
| `YOUTUBE_PRIVACY` | `public`, `private` or `unlisted`. |

## Placeholders

Placeholders can be used in `OVERLAY_TEXT`, `YOUTUBE_TITLE` and `YOUTUBE_DESC`. Every occurrence is replaced.

| Placeholder | Replaced with |
|---|---|
| `[SUNRISE]` | Time of sunrise. |
| `[FIRSTLIGHT]` | Time of first light. |
| `[SUNSET]` | Time of sunset. |
| `[START-OFFSET]` | `offSTART`. |
| `[SUNSET-OFFSET]` | `offEND`. |
| `[EVENT-DESCRIPTION]` | Description of the time override of today. With a start and an end override both are shown, separated by a slash. |
| `[FORMATTED_DATE]` | Date of the start as dd.mm.yyyy. |
| `[FORMATTED_DATETIME]` | Date and time of the picture as dd.mm.yyyy hh:mm:ss. |
| `[IMAGE-COUNT]` | In the overlay the number of the picture, afterwards the number of pictures taken. |
| `[IMAGE-COUNT-FORMATED]` | The same with leading zeros, e.g. 00042. |
| `[INTERVAL]` | `INTERVAL`. |
| `[WIDTH]`, `[HEIGHT]` | `RESW`, `RESH`. |
| `[FRAMERATE]` | Pictures per second of the video. |
| `[INT-TEMP]` | Temperature of the Raspberry Pi in °C. |
| `[WEATHER]` | Content of the weather file. |
| `[LATITUDE]`, `[LONGITUDE]` | `LAT`, `LONG`. |
| `[BIRD-COUNT]` | Number of birds on the picture. `?` if the detection failed, empty if it is disabled. |
| `[BIRD-MAX]` | Highest number of birds on a single picture so far. |
| `[BIRD-IMAGES]` | Number of pictures with at least one bird so far. |
| `[BIRD-TIME]` | Duration of the bird detection on the picture in seconds, e.g. 1.2. |
| `[BIRD-TIME-AVG]` | Average duration of the bird detection so far in seconds. |
| `[BIRD-TIME-MAX]` | Longest duration of the bird detection so far in seconds. |
| `[PLAYLIST]`, `[YOUTUBE-CATEGORY]`, `[YOUTUBE-LANGUAGE]`, `[YOUTUBE-PRIVACY]`, `[YOUTUBE-TAGS]` | The setting of the same name. |

`[INT-TEMP]`, `[WEATHER]`, `[FORMATTED_DATETIME]`, `[BIRD-COUNT]` and `[BIRD-TIME]` belong to a single picture. In the YouTube title and description they hold the values of the last picture.

The older spellings `[FORMATED_DATE]`, `[FORMATED_DATETIME]`, `[LENGTH]` (for the width), `[LAT]` and `[LONG]` still work.

## Bird detection

The bird detection is disabled by default. It runs a YOLOX object detection model with OpenCV on each picture.

### Setup

```bash
sudo apt install python3-opencv
./get_model.sh
```

Then set in `config.cfg`:

```
BIRD_DETECTION_ENABLED=1
OVERLAY_ENABLED=1
OVERLAY_TEXT="[FORMATTED_DATETIME] | Birds: [BIRD-COUNT]"
```

Try it with `debug=1` first. At start the script loads the model once and runs it; if OpenCV cannot use the model, it stops with a message.

### Settings

| Setting | Meaning |
|---|---|
| `BIRD_DETECTION_ENABLED` | `1`: count the birds on each picture. |
| `BIRD_DRAW_BOXES` | `1`: draw a frame around each detected bird. |
| `BIRD_CLASSES` | What to count, comma-separated. Default `bird`. |
| `BIRD_CONFIDENCE` | Minimum confidence of a detection, 0 to 1. Lower finds more birds but also more false ones. |
| `BIRD_TILES` | Number of tiles the picture is split into for the search, as `COLUMNSxROWS`. |
| `BIRD_MODEL` | Model file. If empty, `model/yolox_tiny.onnx` next to the script. |
| `BIRD_MODEL_SIZE` | Input size of the model: `416` for `yolox_tiny` and `yolox_nano`, `640` for `yolox_s`. |

### What it does and what it does not

- The model knows `bird` as a single class. Gulls, ducks, pigeons and other birds are all counted as bird; the species is not distinguished.
- The number is a count per picture. The same bird is counted again on the next picture, so there is no total number of birds per day. Use `[BIRD-MAX]` or `[BIRD-IMAGES]` for the video description.
- Small or far away birds, birds in a dense flock and birds in front of a busy background are missed easily. Expect the number to be a lower estimate.
- Other classes of the model can be counted too, e.g. `BIRD_CLASSES="bird,boat"`. Run `python3 detect_birds.py --model model/yolox_tiny.onnx --classes x` to list them.

### Duration of the detection

The detection is done for each picture before the next one is taken, so its duration must stay below `INTERVAL`. Otherwise the pictures are taken less often than configured. The duration includes the start of Python and the loading of the model.

Where the duration is shown:

| Where | What |
|---|---|
| Log, for each picture | `* bird detection: 3 on picture 12, took 1.2 s (average 1.1 s, longest 1.4 s).` |
| Log, at the end of the capture | Average and longest duration, and a warning with the number of pictures that took longer than `INTERVAL`. |
| On the picture, in debug mode | ` | Detection: 1.2 s` is appended to the overlay text. |
| On the picture, always | Add `[BIRD-TIME]` to `OVERLAY_TEXT`. |

### Accuracy and speed

The picture is searched as a whole and additionally in tiles, because birds are small on a wide angle picture. More tiles and a larger model find more and smaller birds but take longer. Check the duration in debug mode after each change.

| Setting | Finds | Duration |
|---|---|---|
| `./get_model.sh yolox_nano`, `BIRD_MODEL_SIZE=416` | least | shortest |
| `./get_model.sh yolox_tiny`, `BIRD_MODEL_SIZE=416` (default) | medium | medium |
| `./get_model.sh yolox_s`, `BIRD_MODEL_SIZE=640` | most | several times longer |
| `BIRD_TILES="1x1"` | large birds only | 1 search |
| `BIRD_TILES="3x2"` (default) | smaller birds | 7 searches |
| `BIRD_TILES="4x3"` | even smaller birds | 13 searches |

Set `BIRD_MODEL` to the downloaded file if it is not `model/yolox_tiny.onnx`.

The models are the YOLOX models published by [Megvii](https://github.com/Megvii-BaseDetection/YOLOX) under the Apache License 2.0, trained on the COCO data set.

## What happens when something fails

| Situation | Behaviour |
|---|---|
| A setting, command or file is missing | The script stops at start with a list of the problems. |
| `hdate` delivers no sun times | The script stops at start. |
| A picture cannot be taken or the text cannot be written | The picture is skipped. After `MAX_CAPTURE_FAILS` failures in a row the capture ends and the video is built from the pictures taken so far. |
| The bird detection fails on a picture | The picture is kept, `[BIRD-COUNT]` shows `?`. |
| The video cannot be built | The script stops. The pictures are kept. |
| An upload fails | The video and the pictures are kept for a manual upload. The script ends with exit code 1. |
| No upload is enabled | The video and the pictures are kept. |

## Version history

| Version | Changes |
|---|---|
| 5.4.1 | Duration of the bird detection is measured, logged and shown on the picture in debug mode. Summary at the end of the capture. Readme and example configuration revised. |
| 5.4.0 | Optional bird detection. |
| 5.3.8 | Description of a start override is no longer lost. |
| 5.3.7 | Overlay text is passed to ffmpeg as a file; special characters need no escaping. |
| 5.3.6 | Placeholders: every occurrence is replaced, special characters in values are safe. |
| 5.3.5 | Setup and sun times are checked at start. Camera command is detected. |
| 5.3.4 | A failed picture is skipped instead of ending the script. |
| 5.3.3 | The video is kept if an upload fails. |
| 5.3.2 | The video is also built when the text overlay is disabled. |
| 5.3.1 | Pictures are taken at a constant interval. |
| 5.3.0 | Start and end time can be overridden for certain days. |

## Acknowledgments

Thanks to the authors of libcamera, ffmpeg, hdate, OpenCV, YOLOX and the youtube-upload script for their contributions to open-source software.
