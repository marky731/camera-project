#!/bin/bash

# Phase 2: Concurrent Testing Script  
# Tests concurrent camera streams starting with 2 cameras using thread 1, preset fast

# Configuration
CAMERA_FILE="/home/nbadmin/camera-new/cameras_test_small.txt"
RESULTS_DIR="/home/nbadmin/camera-new/test_results"
TEST_DURATION=60  # 1 minute
SAMPLE_INTERVAL=10 # Sample every 10 seconds
LOG_FILE="${RESULTS_DIR}/phase2_concurrent.log"
CSV_FILE="${RESULTS_DIR}/phase2_concurrent_results.csv"
TEMP_DIR="${RESULTS_DIR}/temp_tests_phase2"
DEBUG_MODE=${DEBUG:-0}  # Set DEBUG=1 to enable debug logging

# Phase 2 configuration: Start with 2 cameras, using production parameters
CONCURRENT_TESTS=(2)
DEFAULT_THREADS=1 # Production uses threads=2
DEFAULT_PRESET="ultrafast"  # Production uses preset=ultrafast

# Global variables
TEST_COUNTER=1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local message="$1"
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $message"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
}

# Debug logging function
debug_log() {
    local message="$1"
    if [[ $DEBUG_MODE -eq 1 ]]; then
        echo -e "${YELLOW}[DEBUG]${NC} $message"
        echo "[DEBUG] $message" >> "$LOG_FILE"
    fi
}

# Error function
error() {
    local message="$1"
    echo -e "${RED}[ERROR]${NC} $message" >&2
    echo "[ERROR] $message" >> "$LOG_FILE"
}

# Setup function
setup() {
    log "Setting up Phase 2 concurrent test environment..."
    
    # Create directories
    mkdir -p "$RESULTS_DIR"
    mkdir -p "$TEMP_DIR"
    
    # Check if camera file exists
    if [[ ! -f "$CAMERA_FILE" ]]; then
        error "Camera file not found: $CAMERA_FILE"
        exit 1
    fi
    
    # Check if we have enough cameras
    local camera_count=$(wc -l < "$CAMERA_FILE")
    log "Found $camera_count cameras in test file"
    
    if [[ $camera_count -lt 25 ]]; then
        error "Not enough cameras for concurrent tests (need 25, have $camera_count)"
        exit 1
    fi
    
    # Load optimal config from Phase 1 if available, otherwise use defaults
    local optimal_threads=$DEFAULT_THREADS
    local optimal_preset=$DEFAULT_PRESET
    
    if [[ -f "${RESULTS_DIR}/optimal_config.env" ]]; then
        source "${RESULTS_DIR}/optimal_config.env"
        optimal_threads=${OPTIMAL_THREADS:-$DEFAULT_THREADS}
        optimal_preset=${OPTIMAL_PRESET:-$DEFAULT_PRESET}
        log "Loaded optimal config from Phase 1: threads=$optimal_threads, preset=$optimal_preset"
    else
        log "No Phase 1 results found, using defaults: threads=$optimal_threads, preset=$optimal_preset"
    fi
    
    # Override with Phase 2 requirements: Use production parameters
    optimal_threads=$DEFAULT_THREADS
    optimal_preset=$DEFAULT_PRESET
    log "Phase 2 configuration: Using production parameters - threads=$optimal_threads, preset=$optimal_preset for all concurrent tests"
    
    # Save config for this phase
    echo "CONCURRENT_THREADS=$optimal_threads" > "${RESULTS_DIR}/phase2_config.env"
    echo "CONCURRENT_PRESET=$optimal_preset" >> "${RESULTS_DIR}/phase2_config.env"
    
    # Create CSV header
    echo "test_id,test_type,threads,preset,concurrent_streams,camera_url,avg_cpu_percent,avg_memory_mb,total_system_cpu,network_rx_mb,network_tx_mb,speed_ratio,duration_seconds,success,error_message" > "$CSV_FILE"
    
    # Check system resources
    local total_mem=$(free -m | awk 'NR==2{printf "%.0f", $2}')
    local cpu_cores=$(nproc)
    log "System: $cpu_cores CPU cores, ${total_mem}MB RAM"
    
    log "Setup complete. Starting Phase 2 concurrent tests..."
}

# Get camera URL by index
get_camera_url() {
    local index=$1
    sed -n "${index}p" "$CAMERA_FILE"
}

# FIXED Monitor process resources - SIMPLIFIED VERSION
monitor_process() {
    local pid=$1
    local output_file=$2
    local duration=$3
    
    # Header for monitoring file
    echo "timestamp,cpu_percent,memory_mb,network_rx_bytes,network_tx_bytes" > "$output_file"
    
    local end_time=$(($(date +%s) + duration))
    local initial_net_stats=$(cat /proc/net/dev | grep -E "eth0|ens|wlan" | head -1 | awk '{print $2,$10}')
    local initial_rx=$(echo "$initial_net_stats" | awk '{print $1}' || echo "0")
    local initial_tx=$(echo "$initial_net_stats" | awk '{print $2}' || echo "0")
    
    local first_measurement=1
    
    # Wait for process to initialize 
    sleep 3
    
    # Check if we've already exceeded duration
    if [[ $(date +%s) -ge $end_time ]]; then
        echo "Process initialization took too long" >> "$output_file"
        return
    fi
    
    while [[ $(date +%s) -lt $end_time ]] && kill -0 "$pid" 2>/dev/null; do
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        
        # SIMPLE CPU measurement using ps
        local cpu_percent="0.00"
        if [[ $first_measurement -eq 0 ]]; then
            # Skip first measurement to let process initialize
            first_measurement=1
        else
            local ps_output=$(ps -p "$pid" -o pcpu --no-headers 2>/dev/null)
            if [[ -n "$ps_output" ]]; then
                local raw_cpu=$(echo "$ps_output" | tr -d ' ')
                if [[ "$raw_cpu" =~ ^[0-9]*\.?[0-9]*$ ]] && [[ -n "$raw_cpu" ]]; then
                    cpu_percent=$(printf "%.2f" "$raw_cpu" 2>/dev/null || echo "0.00")
                fi
            fi
        fi
        
        # SIMPLE Memory measurement 
        local memory_mb="0.00"
        if [[ -f "/proc/$pid/status" ]]; then
            local rss_line=$(grep "^VmRSS:" "/proc/$pid/status" 2>/dev/null)
            if [[ -n "$rss_line" ]]; then
                local memory_kb=$(echo "$rss_line" | awk '{print $2}')
                if [[ "$memory_kb" =~ ^[0-9]+$ ]]; then
                    memory_mb=$(printf "%.2f" "$(echo "$memory_kb / 1024" | bc -l)" 2>/dev/null || echo "0.00")
                fi
            fi
        fi
        
        # Get current network stats
        local current_net_stats=$(cat /proc/net/dev | grep -E "eth0|ens|wlan" | head -1 | awk '{print $2,$10}')
        local current_rx=$(echo "$current_net_stats" | awk '{print $1}' || echo "0")
        local current_tx=$(echo "$current_net_stats" | awk '{print $2}' || echo "0")
        
        # Calculate delta (bytes since start of monitoring)
        local rx_delta=$((current_rx - initial_rx))
        local tx_delta=$((current_tx - initial_tx))
        
        # Write to file
        echo "$timestamp,$cpu_percent,$memory_mb,$rx_delta,$tx_delta" >> "$output_file"
        
        # Debug logging
        if [[ $DEBUG_MODE -eq 1 ]]; then
            echo "[DEBUG] PID=$pid, CPU=$cpu_percent%, Memory=$memory_mb MB" >> "${output_file}.debug"
        fi
        
        sleep "$SAMPLE_INTERVAL"
    done
}

# Parse FFmpeg output for performance metrics
parse_ffmpeg_output() {
    local log_file=$1
    
    # Extract speed ratio (last occurrence)
    local speed_ratio=$(grep -o "speed=[0-9.]*x" "$log_file" | tail -1 | grep -o "[0-9.]*" || echo "0")
    
    # Check for errors (including decoding failures and timeouts)
    local has_error=0
    local error_msg=""
    if grep -q -i "error\|failed\|connection refused\|timeout\|decoding.*failed\|could not find codec\|no frames processed" "$log_file"; then
        has_error=1
        error_msg=$(grep -i "error\|failed\|connection refused\|timeout\|decoding.*failed\|could not find codec\|no frames processed" "$log_file" | head -1 | tr '"' "'" | tr ',' ';')
    fi
    
    # Special check for zero frames processed (common with problematic streams)
    if grep -q "frame=\s*0\s*fps=" "$log_file"; then
        has_error=1
        if [[ -z "$error_msg" ]]; then
            error_msg="No frames processed - stream may be incompatible or corrupted"
        fi
    fi
    
    echo "$speed_ratio,$has_error,$error_msg"
}

# Calculate averages from monitoring file
calculate_averages() {
    local monitor_file=$1
    
    if [[ ! -f "$monitor_file" ]] || [[ $(wc -l < "$monitor_file") -le 1 ]]; then
        echo "0,0,0,0"
        return
    fi
    
    # Skip header and calculate averages
    local avg_cpu=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$2; count++} END {if(count>0) print sum/count; else print 0}')
    local avg_memory=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$3; count++} END {if(count>0) print sum/count; else print 0}')
    
    # Calculate total bandwidth used
    local rx_start=$(tail -n +2 "$monitor_file" | head -1 | awk -F, '{print $4}')
    local rx_end=$(tail -n +2 "$monitor_file" | tail -1 | awk -F, '{print $4}')
    local tx_start=$(tail -n +2 "$monitor_file" | head -1 | awk -F, '{print $5}')
    local tx_end=$(tail -n +2 "$monitor_file" | tail -1 | awk -F, '{print $5}')
    
    local rx_mb=$(echo "scale=2; ($rx_end - $rx_start) / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
    local tx_mb=$(echo "scale=2; ($tx_end - $tx_start) / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
    
    echo "$avg_cpu,$avg_memory,$rx_mb,$tx_mb"
}

# Run single FFmpeg test for concurrent testing
run_single_test() {
    local camera_url=$1
    local test_id=$2
    local concurrent_id=$3
    
    # Create test-specific temp directory
    local test_temp_dir="${TEMP_DIR}/test_${test_id}_${concurrent_id}"
    mkdir -p "$test_temp_dir"
    
    # Files for this test
    local ffmpeg_log="${test_temp_dir}/ffmpeg.log"
    local monitor_file="${test_temp_dir}/monitor.csv"
    local playlist_file="${test_temp_dir}/playlist.m3u8"
    
    # Build FFmpeg command - EXACT match to production FFmpegManager.cs
    local ffmpeg_cmd="ffmpeg -hide_banner -loglevel info \
        -analyzeduration 3000000 \
        -probesize 5000000 \
        -i \"$camera_url\" \
        -t $TEST_DURATION \
        -vf scale=1280:720 \
        -c:v libx264 -threads 1 -crf 35 -preset ultrafast \
        -x264-params threads=2:lookahead-threads=1:sliced-threads=0 \
        -g 60 \
        -an \
        -f hls \
        -hls_time 30 \
        -hls_flags append_list \
        -hls_list_size 0 \
        -hls_segment_filename \"${test_temp_dir}/segment_%d.ts\" \
        \"$playlist_file\""
    
    # Start system monitoring
    local cpu_stat_before=$(grep '^cpu ' /proc/stat)
    local user_before=$(echo "$cpu_stat_before" | awk '{print $2}')
    local system_before=$(echo "$cpu_stat_before" | awk '{print $4}')
    local idle_before=$(echo "$cpu_stat_before" | awk '{print $5}')
    
    # Start FFmpeg in background
    eval "$ffmpeg_cmd" > "$ffmpeg_log" 2>&1 &
    local ffmpeg_pid=$!
    
    # Monitor the process
    monitor_process "$ffmpeg_pid" "$monitor_file" "$TEST_DURATION" &
    local monitor_pid=$!
    
    # Wait for FFmpeg to complete with timeout
    local start_time=$(date +%s)
    local timeout_time=$((start_time + TEST_DURATION + 10))  # 10 second grace period
    local ffmpeg_exit_code=0
    
    # Wait with timeout
    while kill -0 "$ffmpeg_pid" 2>/dev/null; do
        local current_time=$(date +%s)
        if [[ $current_time -ge $timeout_time ]]; then
            echo "[WARNING] FFmpeg process exceeded timeout, killing..." >> "$ffmpeg_log"
            kill -TERM "$ffmpeg_pid" 2>/dev/null || true
            sleep 2
            if kill -0 "$ffmpeg_pid" 2>/dev/null; then
                kill -KILL "$ffmpeg_pid" 2>/dev/null || true
            fi
            ffmpeg_exit_code=124  # timeout exit code
            break
        fi
        sleep 1
    done
    
    # Get actual exit code if process finished normally
    if [[ $ffmpeg_exit_code -eq 0 ]]; then
        wait "$ffmpeg_pid" 2>/dev/null
        ffmpeg_exit_code=$?
    fi
    
    local end_time=$(date +%s)
    local actual_duration=$((end_time - start_time))
    
    # Stop monitoring
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    
    # Calculate system CPU usage
    local cpu_stat_after=$(grep '^cpu ' /proc/stat)
    local user_after=$(echo "$cpu_stat_after" | awk '{print $2}')
    local system_after=$(echo "$cpu_stat_after" | awk '{print $4}')
    local idle_after=$(echo "$cpu_stat_after" | awk '{print $5}')
    
    local total_before=$((user_before + system_before + idle_before))
    local total_after=$((user_after + system_after + idle_after))
    local active_before=$((user_before + system_before))
    local active_after=$((user_after + system_after))
    
    local system_cpu_usage="0"
    if [[ $((total_after - total_before)) -gt 0 ]]; then
        system_cpu_usage=$(echo "scale=2; ((${active_after} - ${active_before}) * 100) / (${total_after} - ${total_before})" | bc -l 2>/dev/null || echo "0")
    fi
    
    # Parse results
    local ffmpeg_results=$(parse_ffmpeg_output "$ffmpeg_log")
    local speed_ratio=$(echo "$ffmpeg_results" | cut -d, -f1)
    local has_error=$(echo "$ffmpeg_results" | cut -d, -f2)
    local error_msg=$(echo "$ffmpeg_results" | cut -d, -f3)
    
    # Calculate resource averages
    local averages=$(calculate_averages "$monitor_file")
    local avg_cpu=$(echo "$averages" | cut -d, -f1)
    local avg_memory=$(echo "$averages" | cut -d, -f2)
    local rx_mb=$(echo "$averages" | cut -d, -f3)
    local tx_mb=$(echo "$averages" | cut -d, -f4)
    
    # Determine success
    local success=1
    if [[ $ffmpeg_exit_code -ne 0 ]] || [[ $has_error -eq 1 ]] || [[ $(echo "$speed_ratio < 0.5" | bc -l 2>/dev/null) -eq 1 ]]; then
        success=0
    fi
    
    # Write results to CSV
    local csv_line="${test_id}_${concurrent_id},concurrent,2,ultrafast,${concurrent_id},$(echo "$camera_url" | tr ',' ';'),${avg_cpu},${avg_memory},${system_cpu_usage},${rx_mb},${tx_mb},${speed_ratio},${actual_duration},${success},${error_msg}"
    echo "$csv_line" >> "$CSV_FILE"
    
    # Return success status
    return $success
}

# Run concurrent test
run_concurrent_test() {
    local concurrent_count=$1
    
    log "Running concurrent test: $concurrent_count streams (using production config: threads=1, preset=ultrafast)"
    
    local pids=()
    local test_ids=()
    local success_count=0
    
    # Start concurrent processes
    for ((i=1; i<=concurrent_count; i++)); do
        local camera_url=$(get_camera_url "$i")
        local test_id="${TEST_COUNTER}"
        
        # Run test in background
        (
            if run_single_test "$camera_url" "$test_id" "$i"; then
                exit 0
            else
                exit 1
            fi
        ) &
        
        pids+=($!)
        test_ids+=("${test_id}_${i}")
    done
    
    ((TEST_COUNTER++))
    
    # Wait for all processes and count successes
    for i in "${!pids[@]}"; do
        local pid=${pids[$i]}
        local test_id=${test_ids[$i]}
        
        if wait "$pid"; then
            ((success_count++))
            log "${GREEN}✓${NC} Concurrent test $test_id completed successfully"
        else
            log "${RED}✗${NC} Concurrent test $test_id failed"
        fi
    done
    
    local success_rate=$(echo "scale=2; $success_count * 100 / $concurrent_count" | bc -l)
    log "Concurrent test completed: $success_count/$concurrent_count successful (${success_rate}%)"
    
    return $(echo "$success_count >= $(echo "$concurrent_count * 0.8" | bc)" | bc)
}

# Main execution for Phase 2
main() {
    echo -e "${BLUE}Phase 2: Concurrent Testing${NC}"
    echo "==========================="
    
    setup
    
    # Load configuration
    source "${RESULTS_DIR}/phase2_config.env" 2>/dev/null || {
        CONCURRENT_THREADS=$DEFAULT_THREADS
        CONCURRENT_PRESET=$DEFAULT_PRESET
    }
    
    log "${YELLOW}Running concurrent scaling tests with production parameters (threads=${CONCURRENT_THREADS}, preset=${CONCURRENT_PRESET})${NC}"
    
    # Run concurrent scaling tests starting with 2 cameras
    for concurrent in "${CONCURRENT_TESTS[@]}"; do
        run_concurrent_test "$concurrent"
        
        # Brief pause between concurrent tests
        sleep 10
    done
    
    log "${GREEN}Phase 2 completed!${NC}"
    log "Results saved to: $CSV_FILE"
    log "Logs saved to: $LOG_FILE"
    
    echo ""
    echo -e "${BLUE}Phase 2 Summary:${NC}"
    echo "================="
    echo "Production configuration used: threads=$CONCURRENT_THREADS, preset=$CONCURRENT_PRESET"
    echo "Concurrent tests: ${CONCURRENT_TESTS[*]}"
    echo "Results file: $CSV_FILE"
    echo ""
    echo "Use the following command to analyze results:"
    echo "  column -t -s, $CSV_FILE | less -S"
}

# Handle interruption
cleanup() {
    log "Phase 2 script interrupted. Cleaning up..."
    # Kill any remaining FFmpeg processes
    pkill -f "ffmpeg.*scale=1280:720" 2>/dev/null || true
    log "Temp files preserved in: $TEMP_DIR"
    exit 1
}

# Set trap for cleanup
trap cleanup INT TERM

# Check dependencies
command -v ffmpeg >/dev/null 2>&1 || { error "ffmpeg is required but not installed"; exit 1; }
command -v bc >/dev/null 2>&1 || { error "bc is required but not installed"; exit 1; }

# Run main function if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi