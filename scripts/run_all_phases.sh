#!/bin/bash

# Master script to run both Phase 1 and Phase 2 testing
# This script coordinates the execution of baseline and concurrent testing

echo "FFmpeg Resource Testing - Two-Phase Approach"
echo "============================================="

# Check dependencies first
echo "Checking dependencies..."
command -v ffmpeg >/dev/null 2>&1 || { 
    echo "❌ Error: ffmpeg is required but not installed"
    exit 1 
}
command -v bc >/dev/null 2>&1 || { 
    echo "❌ Error: bc is required but not installed"
    exit 1 
}
echo "✅ Dependencies OK"

echo ""
echo "Phase Structure:"
echo "- Phase 1: Baseline testing (single streams, different configurations)"
echo "- Phase 2: Concurrent testing (multiple streams, starting with 2 cameras, thread 1, preset fast)"
echo ""

# Function to run phase with error handling
run_phase() {
    local phase_script=$1
    local phase_name=$2
    
    echo "🚀 Starting $phase_name..."
    echo "========================================"
    
    if [[ -f "$phase_script" ]]; then
        if bash "$phase_script"; then
            echo "✅ $phase_name completed successfully"
            return 0
        else
            echo "❌ $phase_name failed"
            return 1
        fi
    else
        echo "❌ Error: $phase_script not found"
        return 1
    fi
}

# Make scripts executable
chmod +x phase1_baseline.sh phase2_concurrent.sh

# Run Phase 1
if run_phase "phase1_baseline.sh" "Phase 1 (Baseline Testing)"; then
    echo ""
    echo "📊 Phase 1 Results Summary:"
    echo "- Baseline results: test_results/phase1_baseline_results.csv"
    echo "- Optimal configuration saved for Phase 2"
    echo ""
    
    # Ask user if they want to continue to Phase 2
    read -p "Continue to Phase 2? (y/n): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        
        # Run Phase 2
        if run_phase "phase2_concurrent.sh" "Phase 2 (Concurrent Testing)"; then
            echo ""
            echo "🎉 All phases completed successfully!"
            echo ""
            echo "📈 Final Results:"
            echo "- Phase 1 (Baseline): test_results/phase1_baseline_results.csv"
            echo "- Phase 2 (Concurrent): test_results/phase2_concurrent_results.csv"
            echo ""
            echo "📋 Analysis Commands:"
            echo "Phase 1 Results:"
            echo "  column -t -s, test_results/phase1_baseline_results.csv | less -S"
            echo ""
            echo "Phase 2 Results:"
            echo "  column -t -s, test_results/phase2_concurrent_results.csv | less -S"
            echo ""
            echo "🔍 View Logs:"
            echo "- Phase 1 Log: test_results/phase1_baseline.log"
            echo "- Phase 2 Log: test_results/phase2_concurrent.log"
            
        else
            echo "❌ Phase 2 failed"
            exit 1
        fi
    else
        echo ""
        echo "ℹ️  Phase 2 skipped by user"
        echo "To run Phase 2 later: bash phase2_concurrent.sh"
    fi
else
    echo "❌ Phase 1 failed - cannot continue to Phase 2"
    exit 1
fi

echo ""
echo "Testing complete! 🏁"