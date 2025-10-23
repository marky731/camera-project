#!/bin/bash

# Test a single camera manually to debug the connection
camera_url="rtsp://admin:9LPY%23qPyD@78.188.37.56/cam/realmonitor?channel=3&subtype=0"

echo "Testing camera: $camera_url"
echo ""

echo "=== Test 1: Basic ffprobe ==="
timeout 15 ffprobe -hide_banner -loglevel info -rtsp_transport tcp "$camera_url" 2>&1

echo ""
echo "=== Test 2: Stream details ==="  
timeout 15 ffprobe -hide_banner -loglevel error -show_streams -select_streams v:0 "$camera_url" 2>/dev/null

echo ""
echo "=== Test 3: Quick FFmpeg test ==="
timeout 10 ffmpeg -hide_banner -loglevel info \
    -rtsp_transport tcp \
    -i "$camera_url" \
    -t 5 \
    -vf scale=640:480 \
    -c:v libx264 -preset superfast \
    -f hls \
    -hls_time 2 \
    -hls_list_size 3 \
    /tmp/test_single.m3u8 2>&1 | head -20

if ls /tmp/test_single*.ts 2>/dev/null; then
    echo "SUCCESS: Segments created!"
    ls -la /tmp/test_single*
    rm -f /tmp/test_single*
else
    echo "FAILED: No segments created"
fi