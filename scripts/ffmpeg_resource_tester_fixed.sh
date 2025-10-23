#!/bin/bash

# FFmpeg Resource Testing Script - FIXED VERSION
# Tests different configurations to measure resource usage per camera stream

# Configuration
CAMERA_FILE="/home/nbadmin/camera-project/scripts/camera-list.txt"
RESULTS_DIR="/home/nbadmin/camera-project/test_results"
TEST_DURATION=30  # 30 seconds for faster testing
SAMPLE_INTERVAL=5 # Sample every 5 seconds
LOG_FILE="${RESULTS_DIR}/test.log"
CSV_FILE="${RESULTS_DIR}/ffmpeg_test_results.csv"
TEMP_DIR="${RESULTS_DIR}/temp_tests"
DEBUG_MODE=${DEBUG:-0}  # Set DEBUG=1 to enable debug logging

# Test matrices
THREAD_COUNTS=(1 2 4)
PRESETS=(ultrafast fast)
CONCURRENT_TESTS=(1 2 4 8)

# Global variables
BEST_THREADS=2
BEST_PRESET="ultrafast"
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
    log "Setting up test environment..."
    
    # Create directories
    mkdir -p "$RESULTS_DIR"
    mkdir -p "$TEMP_DIR"
    
    # Check if camera file exists
    if [[ ! -f "$CAMERA_FILE" ]]; then
        error "Camera file not found: $CAMERA_FILE"
        exit 1
    fi
    
    # Check if we have cameras
    local camera_count=$(wc -l < "$CAMERA_FILE")
    log "Found $camera_count cameras in test file"
    
    if [[ $camera_count -lt 25 ]]; then
        error "Not enough cameras for concurrent tests (need 25, have $camera_count)"
        exit 1
    fi
    
    # Create CSV header
    echo "test_id,test_type,threads,preset,concurrent_streams,camera_url,avg_cpu_percent,avg_memory_mb,total_system_cpu,network_rx_mb,network_tx_mb,speed_ratio,duration_seconds,success,error_message" > "$CSV_FILE"
    
    # Check system resources
    local total_mem=$(free -m | awk 'NR==2{printf "%.0f", $2}')
    local cpu_cores=$(nproc)
    log "System: $cpu_cores CPU cores, ${total_mem}MB RAM"
    
    log "Setup complete. Starting tests..."
}

# Get camera URL by index
get_camera_url() {
    local index=$1
    sed -n "${index}p" "$CAMERA_FILE"
}

# FIXED Monitor process resources - MUCH SIMPLER VERSION
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
        
        # SIMPLE CPU measurement using ps (we know this works!)
        local cpu_percent="0.00"
        if [[ $first_measurement -eq 0 ]]; then
            # ps gives cumulative CPU usage - this works reliably
            local ps_output=$(ps -p "$pid" -o pcpu --no-headers 2>/dev/null)
            if [[ -n "$ps_output" ]]; then
                local raw_cpu=$(echo "$ps_output" | tr -d ' ')
                if [[ "$raw_cpu" =~ ^[0-9]*\.?[0-9]*$ ]] && [[ -n "$raw_cpu" ]]; then
                    cpu_percent=$(printf "%.2f" "$raw_cpu" 2>/dev/null || echo "0.00")
                fi
            fi
        else
            first_measurement=0
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
    
    # Check for errors
    local has_error=0
    local error_msg=""
    if grep -q -i "error\|failed\|connection refused\|timeout" "$log_file"; then
        has_error=1
        error_msg=$(grep -i "error\|failed\|connection refused\|timeout" "$log_file" | head -1 | tr '"' "'" | tr ',' ';')
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
    
    # Calculate total bandwidth used (max - min values converted to MB)
    local rx_start=$(tail -n +2 "$monitor_file" | head -1 | awk -F, '{print $4}')
    local rx_end=$(tail -n +2 "$monitor_file" | tail -1 | awk -F, '{print $4}')
    local tx_start=$(tail -n +2 "$monitor_file" | head -1 | awk -F, '{print $5}')
    local tx_end=$(tail -n +2 "$monitor_file" | tail -1 | awk -F, '{print $5}')
    
    local rx_mb=$(echo "scale=2; ($rx_end - $rx_start) / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
    local tx_mb=$(echo "scale=2; ($tx_end - $tx_start) / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
    
    echo "$avg_cpu,$avg_memory,$rx_mb,$tx_mb"
}

# Run single FFmpeg test
run_single_test() {
    local threads=$1
    local preset=$2
    local camera_url=$3
    local test_id=$4
    local test_type=$5
    
    log "Running test $test_id: threads=$threads, preset=$preset, camera=${camera_url:0:50}..."
    
    # Create test-specific temp directory
    local test_temp_dir="${TEMP_DIR}/test_${test_id}"
    mkdir -p "$test_temp_dir"
    
    # Files for this test
    local ffmpeg_log="${test_temp_dir}/ffmpeg.log"
    local monitor_file="${test_temp_dir}/monitor.csv"
    local output_file="${test_temp_dir}/output.mp4"
    
    # Build FFmpeg command
    local ffmpeg_cmd="ffmpeg -hide_banner -loglevel info \
        -y \
        -analyzeduration 3000000 \
        -probesize 5000000 \
        -i \"$camera_url\" \
        -t $TEST_DURATION \
        -vf scale=1280:720 \
        -r 30 \
        -c:v libx264 -threads $threads -preset $preset -crf 35 \
        -g 60 \
        -an \
        -f mp4 \
        \"$output_file\""
    
    # Start system monitoring - get initial CPU stats
    local cpu_stat_before=$(grep '^cpu ' /proc/stat)
    local user_before=$(echo "$cpu_stat_before" | awk '{print $2}')
    local nice_before=$(echo "$cpu_stat_before" | awk '{print $3}')
    local system_before=$(echo "$cpu_stat_before" | awk '{print $4}')
    local idle_before=$(echo "$cpu_stat_before" | awk '{print $5}')
    local iowait_before=$(echo "$cpu_stat_before" | awk '{print $6}')
    local irq_before=$(echo "$cpu_stat_before" | awk '{print $7}')
    local softirq_before=$(echo "$cpu_stat_before" | awk '{print $8}')
    
    # Start FFmpeg in background
    eval "$ffmpeg_cmd" > "$ffmpeg_log" 2>&1 &
    local ffmpeg_pid=$!
    
    # Monitor the process
    monitor_process "$ffmpeg_pid" "$monitor_file" "$TEST_DURATION" &
    local monitor_pid=$!
    
    # Wait for FFmpeg to complete
    local start_time=$(date +%s)
    wait "$ffmpeg_pid"
    local ffmpeg_exit_code=$?
    local end_time=$(date +%s)
    local actual_duration=$((end_time - start_time))
    
    # Stop monitoring
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    
    # Get system CPU after - calculate proper delta
    local cpu_stat_after=$(grep '^cpu ' /proc/stat)
    local user_after=$(echo "$cpu_stat_after" | awk '{print $2}')
    local nice_after=$(echo "$cpu_stat_after" | awk '{print $3}')
    local system_after=$(echo "$cpu_stat_after" | awk '{print $4}')
    local idle_after=$(echo "$cpu_stat_after" | awk '{print $5}')
    local iowait_after=$(echo "$cpu_stat_after" | awk '{print $6}')
    local irq_after=$(echo "$cpu_stat_after" | awk '{print $7}')
    local softirq_after=$(echo "$cpu_stat_after" | awk '{print $8}')
    
    # Calculate deltas
    local user_delta=$((user_after - user_before))
    local nice_delta=$((nice_after - nice_before))
    local system_delta=$((system_after - system_before))
    local idle_delta=$((idle_after - idle_before))
    local iowait_delta=$((iowait_after - iowait_before))
    local irq_delta=$((irq_after - irq_before))
    local softirq_delta=$((softirq_after - softirq_before))
    
    # Calculate total and active time
    local total_delta=$((user_delta + nice_delta + system_delta + idle_delta + iowait_delta + irq_delta + softirq_delta))
    local active_delta=$((user_delta + nice_delta + system_delta + irq_delta + softirq_delta))
    
    # Calculate system CPU usage percentage
    local system_cpu_usage="0"
    if [[ $total_delta -gt 0 ]]; then
        system_cpu_usage=$(echo "scale=2; ($active_delta * 100) / $total_delta" | bc -l 2>/dev/null || echo "0")
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
    
    # Validate measurements
    if [[ $(echo "$avg_cpu < 1.0" | bc -l 2>/dev/null) -eq 1 ]] && [[ $success -eq 1 ]]; then
        log "${YELLOW}[WARNING]${NC} Test $test_id: Suspiciously low CPU usage (${avg_cpu}%)"
        debug_log "Check monitor file: $monitor_file"
    fi
    
    if [[ $(echo "$avg_memory < 10" | bc -l 2>/dev/null) -eq 1 ]] && [[ $success -eq 1 ]]; then
        log "${YELLOW}[WARNING]${NC} Test $test_id: Suspiciously low memory usage (${avg_memory}MB)"
        debug_log "Check monitor file: $monitor_file"
    fi
    
    # Write results to CSV
    local csv_line="${test_id},${test_type},${threads},${preset},1,$(echo "$camera_url" | tr ',' ';'),${avg_cpu},${avg_memory},${system_cpu_usage},${rx_mb},${tx_mb},${speed_ratio},${actual_duration},${success},${error_msg}"
    echo "$csv_line" >> "$CSV_FILE"
    
    # Log results with validation warnings
    if [[ $success -eq 1 ]]; then
        log "${GREEN}✓${NC} Test $test_id completed: CPU=${avg_cpu}%, Memory=${avg_memory}MB, SystemCPU=${system_cpu_usage}%, RX=${rx_mb}MB, TX=${tx_mb}MB, Speed=${speed_ratio}x"
    else
        log "${RED}✗${NC} Test $test_id failed: $error_msg"
    fi
    
    # Debug: Log first few lines of monitor file
    if [[ $DEBUG_MODE -eq 1 ]] && [[ -f "$monitor_file" ]]; then
        debug_log "Monitor file sample (first 3 measurements):"
        head -4 "$monitor_file" | while read line; do
            debug_log "  $line"
        done
    fi
    
    # Keep all temp files for analysis
    log "Test files saved to: $test_temp_dir"
    
    return $success
}

# Run concurrent test
run_concurrent_test() {
    local threads=$1
    local preset=$2
    local concurrent_count=$3
    
    log "Running concurrent test: $concurrent_count streams, threads=$threads, preset=$preset"
    
    local pids=()
    local test_ids=()
    local success_count=0
    
    # Start concurrent processes
    for ((i=1; i<=concurrent_count; i++)); do
        local camera_url=$(get_camera_url "$i")
        local test_id="${TEST_COUNTER}_concurrent_${i}"
        
        # Run test in background
        (
            if run_single_test "$threads" "$preset" "$camera_url" "$test_id" "concurrent"; then
                exit 0
            else
                exit 1
            fi
        ) &
        
        pids+=($!)
        test_ids+=("$test_id")
        ((TEST_COUNTER++))
    done
    
    # Wait for all processes and count successes
    for i in "${!pids[@]}"; do
        local pid=${pids[$i]}
        local test_id=${test_ids[$i]}
        
        if wait "$pid"; then
            ((success_count++))
        fi
    done
    
    local success_rate=$(echo "scale=2; $success_count * 100 / $concurrent_count" | bc -l)
    log "Concurrent test completed: $success_count/$concurrent_count successful (${success_rate}%)"
    
    return $(echo "$success_count >= $(echo "$concurrent_count * 0.8" | bc)" | bc)
}

# Find optimal configuration
find_optimal_config() {
    log "Analyzing baseline test results..."
    
    # Parse CSV to find best performing single-stream configuration
    local best_score=0
    local best_line=""
    
    while IFS=, read -r test_id test_type threads preset concurrent camera avg_cpu avg_memory system_cpu speed_ratio duration success error; do
        if [[ "$test_type" == "baseline" ]] && [[ "$success" == "1" ]]; then
            # Calculate score: prioritize speed ratio, then lower CPU usage
            local score=$(echo "scale=4; $speed_ratio * 100 - $avg_cpu" | bc -l 2>/dev/null || echo "0")
            if (( $(echo "$score > $best_score" | bc -l) )); then
                best_score=$score
                best_line="$threads,$preset"
                BEST_THREADS=$threads
                BEST_PRESET=$preset
            fi
        fi
    done < <(tail -n +2 "$CSV_FILE")
    
    log "Optimal configuration found: threads=$BEST_THREADS, preset=$BEST_PRESET (score: $best_score)"
}

# Main execution
main() {
    echo -e "${BLUE}FFmpeg Resource Testing Script - FIXED VERSION${NC}"
    echo "==============================================="
    
    setup
    
    # Phase 1: Baseline tests (single stream with different configs)
    log "${YELLOW}Phase 1: Baseline Tests${NC}"
    for threads in "${THREAD_COUNTS[@]}"; do
        for preset in "${PRESETS[@]}"; do
            local camera_url=$(get_camera_url "1")
            local test_id="${TEST_COUNTER}"
            
            run_single_test "$threads" "$preset" "$camera_url" "$test_id" "baseline"
            ((TEST_COUNTER++))
            
            # Brief pause between tests
            sleep 5
        done
    done
    
    # Find optimal configuration
    find_optimal_config
    
    # Phase 2: Concurrent scaling tests
    log "${YELLOW}Phase 2: Concurrent Scaling Tests${NC}"
    for concurrent in "${CONCURRENT_TESTS[@]}"; do
        run_concurrent_test "$BEST_THREADS" "$BEST_PRESET" "$concurrent"
        
        # Brief pause between concurrent tests
        sleep 10
    done
    
    # Generate summary
    log "${GREEN}Testing completed!${NC}"
    log "Results saved to: $CSV_FILE"
    log "Logs saved to: $LOG_FILE"
    
    echo ""
    echo -e "${BLUE}Test Summary:${NC}"
    echo "============="
    echo "Total tests: $((TEST_COUNTER - 1))"
    echo "Optimal config: threads=$BEST_THREADS, preset=$BEST_PRESET"
    echo "Results file: $CSV_FILE"
    echo ""
    echo "Use the following command to analyze results:"
    echo "  column -t -s, $CSV_FILE | less -S"
}

# Handle interruption
cleanup() {
    log "Script interrupted. Cleaning up..."
    # Kill any remaining FFmpeg processes
    pkill -f "ffmpeg.*scale=1280:720" 2>/dev/null || true
    # Keep temp directory for analysis
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