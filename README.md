# Raspi Time Lapse Script

A Bash script for Raspberry Pi that creates time-lapse videos from sunrise to sunset, with text overlays, backup, and YouTube upload.
See it in action here: https://www.youtube.com/watch?v=RmAjS0czRXU&list=PLcnGcU-Z-RJ1uRxLbBiHb2feVr6tQzJVj .

## Overview

This script:

- Generates time-lapse images from sunrise to sunset for a given location.
- Adds a text overlay to each image, displaying date, time, weather, and temperature.
- Combines images into a video.
- (Optionally) backs up the video to a remote Linux server.
- Uploads the video to YouTube.

## Prerequisites

- **Raspberry Pi** with camera module
- **Bash** (pre-installed on most Linux systems)
- **ffmpeg** for video and image processing
- **raspistill** for capturing images
- **hdate** for calculating sun times
- **youtube-upload** for YouTube uploads 
- **scp** for remote backup

## Installation
Reneame and adjust config.example.cfg

1. **Install required software:**
   ```bash
   sudo apt-get update
   sudo apt-get install -y ffmpeg hdate scp
   pip install youtube-upload