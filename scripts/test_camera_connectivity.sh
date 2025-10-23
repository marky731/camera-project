#!/bin/bash

# Test connectivity of all 25 cameras from cameras_test.txt
# This helps identify which cameras are reachable vs. problematic

CAMERA_FILE="/home/nbadmin/camera-new/cameras_test.txt"
RESULTS_DIR="/home/nbadmin/camera-new/test_results"
RESULTS_FILE="${RESULTS_DIR}/camera_connectivity_results.csv"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Camera Connectivity Test${NC}"
echo "========================"

# Create results directory
mkdir -p "$RESULTS_DIR"

# Create CSV header
echo "camera_id,camera_url,ping_status,rtsp_connect,rtsp_auth,stream_info,overall_status,notes" > "$RESULTS_FILE"

echo ""
echo "Testing all cameras from: $CAMERA_FILE"
echo "Results will be saved to: $RESULTS_FILE"
echo ""

# Read camera URLs and test each one
camera_id=1
while IFS= read -r camera_url || [[ -n "$camera_url" ]]; do
    # Skip empty lines
    [[ -z "$camera_url" ]] && continue
    
    echo -e "${BLUE}Camera $camera_id:${NC} ${camera_url:0:60}..."
    
    # Extract host from RTSP URL
    host=$(echo "$camera_url" | sed -n 's|rtsp://[^@]*@\([^/]*\).*|\1|p')
    if [[ -z "$host" ]]; then
        host=$(echo "$camera_url" | sed -n 's|rtsp://\([^/]*\).*|\1|p')
    fi
    
    # Remove port if present  
    host_ip=$(echo "$host" | cut -d: -f1)
    
    # Test 1: Ping connectivity
    echo -n "  Ping test: "
    if timeout 3 ping -c 1 "$host_ip" >/dev/null 2>&1; then
        ping_status="OK"
        echo -e "${GREEN}✓${NC}"
    else
        ping_status="FAIL"
        echo -e "${RED}✗${NC}"
    fi
    
    # Test 2: RTSP connection (basic handshake)
    echo -n "  RTSP connect: "
    rtsp_connect_output=$(timeout 10 ffprobe -hide_banner -loglevel info -rtsp_transport tcp "$camera_url" 2>&1 | head -20)
    if echo "$rtsp_connect_output" | grep -q "401 Unauthorized"; then
        rtsp_connect="AUTH_FAIL"
        rtsp_auth="401"
        echo -e "${YELLOW}Auth${NC}"
    elif echo "$rtsp_connect_output" | grep -q "404 Not Found\|method.*failed"; then
        rtsp_connect="NOT_FOUND" 
        rtsp_auth="404"
        echo -e "${RED}404${NC}"
    elif echo "$rtsp_connect_output" | grep -q "Connection refused\|Connection timed out\|No route to host"; then
        rtsp_connect="NO_CONNECT"
        rtsp_auth="TIMEOUT"
        echo -e "${RED}Timeout${NC}"
    elif echo "$rtsp_connect_output" | grep -q "Stream #0"; then
        rtsp_connect="OK"
        rtsp_auth="OK"
        echo -e "${GREEN}✓${NC}"
    else
        rtsp_connect="UNKNOWN"
        rtsp_auth="UNKNOWN"
        echo -e "${YELLOW}?${NC}"
    fi
    
    # Test 3: Stream information (if connection works)
    stream_info=""
    if [[ "$rtsp_connect" == "OK" ]]; then
        echo -n "  Stream info: "
        stream_details=$(timeout 15 ffprobe -hide_banner -loglevel error -show_streams -select_streams v:0 "$camera_url" 2>/dev/null | head -20)
        if [[ -n "$stream_details" ]]; then
            # Extract codec and resolution
            codec=$(echo "$stream_details" | grep "codec_name=" | cut -d= -f2)
            width=$(echo "$stream_details" | grep "width=" | cut -d= -f2) 
            height=$(echo "$stream_details" | grep "height=" | cut -d= -f2)
            if [[ -n "$codec" && -n "$width" && -n "$height" ]]; then
                stream_info="${codec}_${width}x${height}"
                echo -e "${GREEN}${codec} ${width}x${height}${NC}"
            else
                stream_info="PARTIAL"
                echo -e "${YELLOW}Partial${NC}"
            fi
        else
            stream_info="NO_STREAM"
            echo -e "${RED}No stream${NC}"
        fi
    else
        stream_info="N/A"
        echo "  Stream info: N/A"
    fi
    
    # Overall status
    if [[ "$ping_status" == "OK" && "$rtsp_connect" == "OK" && "$stream_info" != "NO_STREAM" ]]; then
        overall_status="WORKING"
        status_color="${GREEN}"
        status_symbol="✓"
    elif [[ "$rtsp_connect" == "AUTH_FAIL" ]]; then
        overall_status="AUTH_ISSUE" 
        status_color="${YELLOW}"
        status_symbol="!"
    elif [[ "$ping_status" == "FAIL" ]]; then
        overall_status="NETWORK_DOWN"
        status_color="${RED}"
        status_symbol="✗"
    else
        overall_status="CAMERA_ISSUE"
        status_color="${RED}"
        status_symbol="✗"
    fi
    
    # Notes
    notes=""
    if [[ "$rtsp_connect_output" == *"error while decoding"* ]]; then
        notes="decoding_errors"
    elif [[ "$rtsp_connect_output" == *"RTP: missed"* ]]; then
        notes="packet_loss"
    fi
    
    echo -e "  Result: ${status_color}${status_symbol} ${overall_status}${NC}"
    
    # Save to CSV  
    echo "$camera_id,$(echo "$camera_url" | tr ',' ';'),$ping_status,$rtsp_connect,$rtsp_auth,$stream_info,$overall_status,$notes" >> "$RESULTS_FILE"
    
    echo ""
    ((camera_id++))
    
done < "$CAMERA_FILE"

echo "=== SUMMARY ==="
echo ""

# Generate summary from CSV
working_count=$(grep ",WORKING," "$RESULTS_FILE" | wc -l)
auth_issues=$(grep ",AUTH_ISSUE," "$RESULTS_FILE" | wc -l) 
network_down=$(grep ",NETWORK_DOWN," "$RESULTS_FILE" | wc -l)
camera_issues=$(grep ",CAMERA_ISSUE," "$RESULTS_FILE" | wc -l)
total_cameras=$((camera_id - 1))

echo -e "${GREEN}✓ Working cameras: $working_count/$total_cameras${NC}"
echo -e "${YELLOW}! Auth issues: $auth_issues/$total_cameras${NC}"
echo -e "${RED}✗ Network down: $network_down/$total_cameras${NC}"
echo -e "${RED}✗ Camera issues: $camera_issues/$total_cameras${NC}"

echo ""
echo "Detailed results saved to: $RESULTS_FILE"
echo ""
echo "To view results in a table format:"
echo "  column -t -s, $RESULTS_FILE | less -S"
echo ""

# Show problematic cameras
echo "=== PROBLEMATIC CAMERAS ==="
grep -v "WORKING" "$RESULTS_FILE" | grep -v "camera_id" | while IFS=, read -r id url ping rtsp auth stream status notes; do
    echo -e "${RED}Camera $id${NC}: $status - $(echo "$url" | cut -c1-50)..."
done