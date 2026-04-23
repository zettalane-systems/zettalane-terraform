#!/bin/bash
# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.


# MayaScale FIO Performance Test Script
# Comprehensive performance testing for NVMe-oF volumes with multiple workload patterns

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] ✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $1${NC}"
}

log_section() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Usage
usage() {
    cat << EOF
MayaScale FIO Performance Test Script

Usage: $0 [OPTIONS]

OPTIONS:
    --device DEVICE          NVMe device(s) to test (e.g., /dev/nvme0n1 or /dev/nvme0n1:/dev/nvme1n1)
                             If not specified, auto-detects all NVMe-oF devices (TCP or RDMA)
    --test-mode MODE         Test mode: quick, full (default: full)
    --runtime SECONDS        Runtime per test in seconds (default: 30 for both modes)
    --output-dir DIR         Directory for test results (default: /tmp/fio-results)
    --target-iops IOPS       Target IOPS for validation (optional)
    --target-latency-us US   Target latency in microseconds (optional)
    --target-bandwidth-mbps  Target bandwidth in MB/s (optional)
    --skip-write-tests       Skip write tests (read-only testing)
    --csv-output FILE        Generate CSV summary (optional)
    --write-size SIZE        Constrain write tests to SIZE (e.g., 100G) for initialized region (AWS)
    -h, --help               Show this help

TEST MODES:
    quick          - Peak + optimal finding (30s, 4-5 tests: QD1, QD8, QD16, QD32 with varying jobs)
    full           - Complete curve + optimal exploration (30s, 12-17 tests: adaptive based on CPU cores)

EXAMPLES:
    # Auto-detect all NVMe-oF devices (TCP or RDMA) and run full test
    $0 --test-mode full

    # Test specific single device
    $0 --device /dev/nvme0n1 --test-mode quick

    # Test multiple devices together (aggregated IOPS)
    $0 --device /dev/nvme0n1:/dev/nvme1n1 --test-mode full

    # Quick test with performance targets (auto-detect)
    $0 --test-mode quick --target-iops 250000

    # Full test with CSV output (auto-detect devices)
    $0 --test-mode full --csv-output results.csv

    # Read-only testing
    $0 --test-mode full --skip-write-tests
EOF
}

# Parse arguments
DEVICE=""
TEST_MODE="full"
RUNTIME=""
OUTPUT_DIR="/tmp/fio-results"
TARGET_IOPS=""
TARGET_LATENCY=""
TARGET_BANDWIDTH=""
SKIP_WRITE_TESTS=false
CSV_OUTPUT=""
WRITE_SIZE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --device)
            DEVICE="$2"
            shift 2
            ;;
        --test-mode)
            TEST_MODE="$2"
            shift 2
            ;;
        --runtime)
            RUNTIME="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --target-iops)
            TARGET_IOPS="$2"
            shift 2
            ;;
        --target-latency-us)
            TARGET_LATENCY="$2"
            shift 2
            ;;
        --target-bandwidth-mbps)
            TARGET_BANDWIDTH="$2"
            shift 2
            ;;
        --skip-write-tests)
            SKIP_WRITE_TESTS=true
            shift
            ;;
        --csv-output)
            CSV_OUTPUT="$2"
            shift 2
            ;;
        --write-size)
            WRITE_SIZE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Auto-detect NVMe-oF devices if no device specified
if [ -z "$DEVICE" ]; then
    log "Auto-detecting NVMe-oF devices (TCP or RDMA)..."

    # Find all NVMe controllers using TCP or RDMA transport
    DETECTED_DEVICES=""
    for ctrl in /sys/class/nvme/nvme*/; do
        if [ -f "${ctrl}transport" ]; then
            transport=$(cat "${ctrl}transport" 2>/dev/null)
            if [ "$transport" = "tcp" ] || [ "$transport" = "rdma" ]; then
                # Get controller name (e.g., nvme0)
                ctrl_name=$(basename "$ctrl")
                # Find namespace devices for this controller (exclude partitions)
                for ns in /dev/${ctrl_name}n*; do
                    if [ -b "$ns" ]; then
                        # Skip partitions (e.g., nvme1n1p1, nvme1n1p2, etc.)
                        # Only include base namespace devices (e.g., nvme1n1)
                        if [[ ! "$ns" =~ p[0-9]+$ ]]; then
                            if [ -z "$DETECTED_DEVICES" ]; then
                                DETECTED_DEVICES="$ns"
                            else
                                DETECTED_DEVICES="${DETECTED_DEVICES}:${ns}"
                            fi
                        fi
                    fi
                done
            fi
        fi
    done

    if [ -z "$DETECTED_DEVICES" ]; then
        log_error "No NVMe-oF devices found (TCP or RDMA)"
        log_error "Run connect_volumes.sh first or specify --device manually"
        exit 1
    fi

    DEVICE="$DETECTED_DEVICES"
    DEVICE_COUNT=$(echo "$DEVICE" | tr ':' '\n' | wc -l)
    log_success "Auto-detected $DEVICE_COUNT NVMe-oF device(s): $DEVICE"
else
    # Validate manually specified device(s)
    # Support both single device and colon-separated list
    for dev in $(echo "$DEVICE" | tr ':' ' '); do
        if [ ! -b "$dev" ]; then
            log_error "Device $dev does not exist or is not a block device"
            exit 1
        fi
    done
    DEVICE_COUNT=$(echo "$DEVICE" | tr ':' '\n' | wc -l)
    log "Using specified device(s): $DEVICE ($DEVICE_COUNT device(s))"
fi

# Detect available CPU cores and calculate reasonable limits
AVAILABLE_CPUS=$(nproc)
# Cap numjobs at vCPU count to avoid context switching overhead
# Rule: numjobs should not exceed vCPU count for optimal performance
MAX_NUMJOBS=$AVAILABLE_CPUS
[ $MAX_NUMJOBS -lt 4 ] && MAX_NUMJOBS=4   # Minimum for testing
[ $MAX_NUMJOBS -gt 64 ] && MAX_NUMJOBS=64 # Maximum reasonable value (supports c4-standard-48-lssd with 60 vCPUs)

log "System: $AVAILABLE_CPUS CPU cores, max numjobs capped at $MAX_NUMJOBS (to avoid CPU oversubscription)"

# Validate test mode
case "$TEST_MODE" in
    quick)
        # Quick: Hit known sweet spots for fast validation
        RUNTIME=${RUNTIME:-30}
        QUICK_MODE_TESTS=(
            "1:1"      # Baseline latency
            "8:8"      # Low-medium concurrency
            "16:16"    # Write optimal (validated: 306K IOPS @ 836µs)
            "16:32"    # Read optimal (validated: 834K IOPS @ 612µs)
        )

        # Add peak exploration only if system has enough cores
        if [ $MAX_NUMJOBS -ge 32 ]; then
            QUICK_MODE_TESTS+=("32:32")  # Peak attempt
        fi
        ;;
    full)
        # Full: Complete performance curve analysis with optimal point exploration
        RUNTIME=${RUNTIME:-30}

        # Full test matrix - hardcoded for complete coverage
        # Tests will be skipped automatically if numjobs > available vCPUs
        # Format: "QD:numjobs"
        FULL_MODE_TESTS=(
            # Phase 1: Baseline latency
            "1:1"      # Minimum latency baseline

            # Phase 2: Low concurrency scaling
            "2:1"      # 2 outstanding I/Os
            "4:2"      # 8 outstanding I/Os
            "8:4"      # 32 outstanding I/Os

            # Phase 3: Medium concurrency (sweet spot search)
            "8:8"      # 64 outstanding I/Os
            "16:4"     # 64 outstanding I/Os (different ratio)
            "16:8"     # 128 outstanding I/Os
            "16:12"    # 192 outstanding I/Os (fills gap)
            "16:16"    # 256 outstanding I/Os (write peak validated!)

            # Phase 4: High concurrency (read optimal range)
            "16:20"    # 320 outstanding I/Os (fills gap, find write peak precisely)
            "16:24"    # 384 outstanding I/Os (fills gap)
            "16:32"    # 512 outstanding I/Os (read peak validated!)

            # Phase 5: Peak exploration (requires 24+ vCPUs)
            "24:24"    # 576 outstanding I/Os (explore qd24)
            "24:32"    # 768 outstanding I/Os (fills gap to 32:32)
            "28:32"    # 896 outstanding I/Os (find 1ms crossover point)
            "32:32"    # 1024 outstanding I/Os (peak attempt)

            # Phase 6: Ultra-high concurrency (requires 36+ vCPUs)
            "28:36"    # 1008 outstanding I/Os (fills gap between 28:32 and 32:36)
            "32:36"    # 1152 outstanding I/Os (fills gap)
            "32:40"    # 1280 outstanding I/Os (fills gap)
            "32:48"    # 1536 outstanding I/Os (ultra tier exploration)
            "32:52"    # 1664 outstanding I/Os (fills gap to 60)
            "32:56"    # 1792 outstanding I/Os (fills gap to 60)
            "32:60"    # 1920 outstanding I/Os (GCP c4-standard-48-lssd max)

            # Phase 7: Very high queue depths (requires 48+ vCPUs, 12+ SSDs)
            "40:48"    # 1920 outstanding I/Os (explore QD40)
            "40:52"    # 2080 outstanding I/Os (fills gap)
            "40:56"    # 2240 outstanding I/Os (fills gap)
            "40:60"    # 2400 outstanding I/Os (QD40 max for 60 vCPU)
            "44:48"    # 2112 outstanding I/Os (explore QD44)
            "44:52"    # 2288 outstanding I/Os (fills gap)
            "44:56"    # 2464 outstanding I/Os (fills gap)
            "44:60"    # 2640 outstanding I/Os (QD44 max for 60 vCPU)
            "48:48"    # 2304 outstanding I/Os (explore QD48)
            "48:52"    # 2496 outstanding I/Os (fills gap)
            "48:56"    # 2688 outstanding I/Os (fills gap)
            "48:60"    # 2880 outstanding I/Os (QD48 max for 60 vCPU)

            # Phase 8: Extreme concurrency (requires 64+ vCPUs for n2-highcpu-64)
            "48:64"    # 3072 outstanding I/Os (absolute max exploration)
            "56:64"    # 3584 outstanding I/Os (QD56 max)
            "64:64"    # 4096 outstanding I/Os (absolute peak for 64 vCPU systems)
        )

        log "Test matrix: ${#FULL_MODE_TESTS[@]} configurations defined (will skip tests where numjobs > $MAX_NUMJOBS vCPUs)"
        ;;
    *)
        log_error "Invalid test mode: $TEST_MODE (must be 'quick' or 'full')"
        usage
        exit 1
        ;;
esac

log_section "MayaScale FIO Performance Test"
log "Device: $DEVICE"
log "Test Mode: $TEST_MODE"
log "Runtime: ${RUNTIME}s per test"
if [ "$TEST_MODE" = "quick" ]; then
    NUM_4K_TESTS=${#QUICK_MODE_TESTS[@]}
    log "Test Configs: $NUM_4K_TESTS 4K tests + 2 sequential = $((NUM_4K_TESTS + 2)) tests total"
    log "  Quick validation targeting known sweet spots (qd16/nj16, qd16/nj32)"
else
    NUM_4K_TESTS=${#FULL_MODE_TESTS[@]}
    log "Test Configs: $NUM_4K_TESTS 4K tests + 2 sequential = $((NUM_4K_TESTS + 2)) tests total"
    log "  4K Random: QD1-48 with varying numjobs to find optimal IOPS/latency"
    log "  Sequential: QD32/nj16 for peak bandwidth"
fi
log "Output Directory: $OUTPUT_DIR"
if [ -n "$TARGET_IOPS" ]; then
    log "Target IOPS: $TARGET_IOPS"
fi
if [ -n "$TARGET_LATENCY" ]; then
    log "Target Latency: ${TARGET_LATENCY}µs"
fi
if [ -n "$TARGET_BANDWIDTH" ]; then
    log "Target Bandwidth: ${TARGET_BANDWIDTH} MB/s"
fi
if [ "$SKIP_WRITE_TESTS" = true ]; then
    log_warning "Write tests will be skipped"
fi

# Ensure fio is installed
if ! command -v fio &> /dev/null; then
    log "Installing fio..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y fio
    elif command -v yum &> /dev/null; then
        sudo yum install -y fio
    else
        log_error "Could not install fio: unsupported package manager"
        exit 1
    fi
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Get device size (for first device if multiple)
FIRST_DEVICE=$(echo "$DEVICE" | cut -d: -f1)
DEVICE_SIZE=$(sudo blockdev --getsize64 "$FIRST_DEVICE" 2>/dev/null || echo "0")
DEVICE_SIZE_GB=$((DEVICE_SIZE / 1024 / 1024 / 1024))
if [ "$DEVICE_COUNT" -gt 1 ]; then
    log "Testing $DEVICE_COUNT devices (first device size: ${DEVICE_SIZE_GB} GB)"
    log "Devices will be tested together for aggregated IOPS"
else
    log "Device Size: ${DEVICE_SIZE_GB} GB"
fi

# Test results storage
declare -A TEST_RESULTS

# Function to run FIO test and capture results
run_fio_test() {
    local test_name=$1
    local rw=$2
    local bs=$3
    local iodepth=$4
    local numjobs=${5:-1}

    log "Running: $test_name (bs=$bs, qd=$iodepth, jobs=$numjobs)..."

    local output_file="$OUTPUT_DIR/${test_name}.json"

    # Constrain tests to initialized region if WRITE_SIZE is set (AWS/OCI)
    # Both have first-write penalty, OCI Samsung also has first-read penalty on uninitialized regions
    local size_param=""
    if [ -n "$WRITE_SIZE" ]; then
        size_param="--size=$WRITE_SIZE"
    fi

    sudo fio --name="$test_name" \
        --filename="$DEVICE" \
        --rw="$rw" \
        --bs="$bs" \
        --iodepth="$iodepth" \
        --numjobs="$numjobs" \
        --ioengine=libaio \
        --direct=1 \
        $size_param \
        --runtime="$RUNTIME" \
        --time_based \
        --group_reporting \
        --output-format=json \
        --output="$output_file" 2>&1 | grep -v "^fio-" || true

    if [ ! -f "$output_file" ]; then
        log_error "Test failed: $test_name"
        return 1
    fi

    # Parse results
    local read_iops=$(jq -r '.jobs[0].read.iops // 0' "$output_file" 2>/dev/null || echo "0")
    local write_iops=$(jq -r '.jobs[0].write.iops // 0' "$output_file" 2>/dev/null || echo "0")
    local read_bw=$(jq -r '.jobs[0].read.bw // 0' "$output_file" 2>/dev/null || echo "0")
    local write_bw=$(jq -r '.jobs[0].write.bw // 0' "$output_file" 2>/dev/null || echo "0")
    local read_lat=$(jq -r '.jobs[0].read.lat_ns.mean // 0' "$output_file" 2>/dev/null || echo "0")
    local write_lat=$(jq -r '.jobs[0].write.lat_ns.mean // 0' "$output_file" 2>/dev/null || echo "0")

    # Convert latency from ns to µs
    read_lat=$(echo "scale=2; $read_lat / 1000" | bc 2>/dev/null || echo "0")
    write_lat=$(echo "scale=2; $write_lat / 1000" | bc 2>/dev/null || echo "0")

    # Convert bandwidth from KB/s to MB/s
    read_bw=$(echo "scale=2; $read_bw / 1024" | bc 2>/dev/null || echo "0")
    write_bw=$(echo "scale=2; $write_bw / 1024" | bc 2>/dev/null || echo "0")

    # Store results
    TEST_RESULTS["${test_name}_read_iops"]=$read_iops
    TEST_RESULTS["${test_name}_write_iops"]=$write_iops
    TEST_RESULTS["${test_name}_read_bw"]=$read_bw
    TEST_RESULTS["${test_name}_write_bw"]=$write_bw
    TEST_RESULTS["${test_name}_read_lat"]=$read_lat
    TEST_RESULTS["${test_name}_write_lat"]=$write_lat

    # Display results
    if (( $(echo "$read_iops > 0" | bc -l) )); then
        log_success "  Read:  IOPS=${read_iops%.*}, BW=${read_bw} MB/s, Lat=${read_lat} µs"
    fi
    if (( $(echo "$write_iops > 0" | bc -l) )); then
        log_success "  Write: IOPS=${write_iops%.*}, BW=${write_bw} MB/s, Lat=${write_lat} µs"
    fi
}

# Run 4K random read tests
# Complete command examples:
#   Single device:
#     fio --name=4k_randread_qd1_nj1 --filename=/dev/nvme0n1 --rw=randread --bs=4k
#         --iodepth=1 --numjobs=1 --ioengine=libaio --direct=1 --runtime=30
#         --time_based --group_reporting --output-format=json
#   Multiple devices (aggregated IOPS):
#     fio --name=4k_randread_qd32_nj16 --filename=/dev/nvme0n1:/dev/nvme1n1 --rw=randread --bs=4k
#         --iodepth=32 --numjobs=16 --ioengine=libaio --direct=1 --runtime=30
#         --time_based --group_reporting --output-format=json

# Warm-up phase: Prime CPU caches, activate turbo boost, warm NVMe devices
# This ensures QD1 tests run under production-like conditions, not cold-start
log_section "System Warm-Up (60s)"
log "Running warm-up workload to:"
log "  • Activate CPU turbo boost and prime caches"
log "  • Wake NVMe devices from power-save state"
log "  • Stabilize kernel scheduler"
log "  • Ensure consistent baseline for all subsequent tests"
log ""
log "Warm-up configuration: Mixed 70% read / 30% write, QD8/NJ4, 60 seconds"

fio --name=warmup \
    --filename="$DEVICE" \
    --rw=randrw --rwmixread=70 \
    --bs=4k --iodepth=8 --numjobs=4 \
    --ioengine=libaio --direct=1 \
    --runtime=60 --time_based \
    --group_reporting \
    --output=/dev/null 2>&1

if [ $? -eq 0 ]; then
    log_success "Warm-up complete - system ready for testing"
else
    log_warning "Warm-up completed with warnings (non-critical)"
fi

log ""
log "Starting performance tests with warmed system state..."
log ""

log_section "4K Random Read Tests"

if [ "$TEST_MODE" = "quick" ]; then
    # Quick mode: Test peak then scale down to find optimal
    for test_config in "${QUICK_MODE_TESTS[@]}"; do
        qd=$(echo "$test_config" | cut -d: -f1)
        numjobs=$(echo "$test_config" | cut -d: -f2)
        run_fio_test "4k_randread_qd${qd}_nj${numjobs}" "randread" "4k" "$qd" "$numjobs"
    done
else
    # Full mode: Comprehensive performance curve with optimal exploration
    for test_config in "${FULL_MODE_TESTS[@]}"; do
        qd=$(echo "$test_config" | cut -d: -f1)
        numjobs=$(echo "$test_config" | cut -d: -f2)

        # Skip test if numjobs exceeds available vCPUs (avoids CPU oversubscription)
        if [ $numjobs -gt $MAX_NUMJOBS ]; then
            log_warning "Skipping 4k_randread_qd${qd}_nj${numjobs}: numjobs ($numjobs) > available vCPUs ($MAX_NUMJOBS)"
            continue
        fi

        run_fio_test "4k_randread_qd${qd}_nj${numjobs}" "randread" "4k" "$qd" "$numjobs"
    done
fi

# Run 4K random write tests (unless skipped)
# Complete command examples:
#   QD1/nj1:   fio --name=4k_randwrite_qd1_nj1 --filename=/dev/nvmeXn1 --rw=randwrite --bs=4k
#                  --iodepth=1 --numjobs=1 --ioengine=libaio --direct=1 --runtime=30
#                  --time_based --group_reporting --output-format=json
#   QD32/nj16: fio --name=4k_randwrite_qd32_nj16 --filename=/dev/nvmeXn1 --rw=randwrite --bs=4k
#                  --iodepth=32 --numjobs=16 --ioengine=libaio --direct=1 --runtime=30
#                  --time_based --group_reporting --output-format=json
if [ "$SKIP_WRITE_TESTS" = false ]; then
    log_section "4K Random Write Tests"

    if [ "$TEST_MODE" = "quick" ]; then
        # Quick mode: Test peak then scale down to find optimal
        for test_config in "${QUICK_MODE_TESTS[@]}"; do
            qd=$(echo "$test_config" | cut -d: -f1)
            numjobs=$(echo "$test_config" | cut -d: -f2)
            run_fio_test "4k_randwrite_qd${qd}_nj${numjobs}" "randwrite" "4k" "$qd" "$numjobs"
        done
    else
        # Full mode: Comprehensive performance curve with optimal exploration
        for test_config in "${FULL_MODE_TESTS[@]}"; do
            qd=$(echo "$test_config" | cut -d: -f1)
            numjobs=$(echo "$test_config" | cut -d: -f2)

            # Skip test if numjobs exceeds available vCPUs (avoids CPU oversubscription)
            if [ $numjobs -gt $MAX_NUMJOBS ]; then
                log_warning "Skipping 4k_randwrite_qd${qd}_nj${numjobs}: numjobs ($numjobs) > available vCPUs ($MAX_NUMJOBS)"
                continue
            fi

            run_fio_test "4k_randwrite_qd${qd}_nj${numjobs}" "randwrite" "4k" "$qd" "$numjobs"
        done
    fi
fi

# REMOVED: 4K mixed 70/30 tests - Not used for validation, adds unnecessary test time
# These tests provide limited value as they don't match real workload patterns
# and are not validated against performance targets
#if [ "$SKIP_WRITE_TESTS" = false ]; then
#    log_section "4K Random Mixed 70% Read / 30% Write Tests"
#    for qd in "${QUEUE_DEPTHS[@]}"; do
#        run_fio_test "4k_randrw_70_30_qd${qd}" "randrw" "4k" "$qd"
#    done
#fi

# Run 128K sequential read tests - Only QD32 for peak bandwidth
# Complete command for QD32/nj16:
#   fio --name=128k_seqread_qd32_nj16 --filename=/dev/nvmeXn1 --rw=read --bs=128k
#       --iodepth=32 --numjobs=16 --ioengine=libaio --direct=1 --runtime=30
#       --time_based --group_reporting --output-format=json
log_section "128K Sequential Read Tests (Peak Bandwidth)"

if [ "$TEST_MODE" = "quick" ]; then
    # Quick mode: Only test peak bandwidth (QD32/nj16)
    run_fio_test "128k_seqread_qd32_nj16" "read" "128k" "32" "16"
else
    # Full mode: Only test peak bandwidth (QD32/nj16)
    run_fio_test "128k_seqread_qd32_nj16" "read" "128k" "32" "16"
fi

# Run 128K sequential write tests - Only QD32 for peak bandwidth
# Complete command for QD32/nj16:
#   fio --name=128k_seqwrite_qd32_nj16 --filename=/dev/nvmeXn1 --rw=write --bs=128k
#       --iodepth=32 --numjobs=16 --ioengine=libaio --direct=1 --runtime=30
#       --time_based --group_reporting --output-format=json
if [ "$SKIP_WRITE_TESTS" = false ]; then
    log_section "128K Sequential Write Tests (Peak Bandwidth)"

    if [ "$TEST_MODE" = "quick" ]; then
        # Quick mode: Only test peak bandwidth (QD32/nj16)
        run_fio_test "128k_seqwrite_qd32_nj16" "write" "128k" "32" "16"
    else
        # Full mode: Only test peak bandwidth (QD32/nj16)
        run_fio_test "128k_seqwrite_qd32_nj16" "write" "128k" "32" "16"
    fi
fi

# Generate summary report
log_section "Performance Summary"

# Find peak performance values
peak_read_iops=0
peak_read_iops_test=""
peak_write_iops=0
peak_write_iops_test=""
peak_read_bw=0
peak_read_bw_test=""
peak_write_bw=0
peak_write_bw_test=""

for key in "${!TEST_RESULTS[@]}"; do
    if [[ $key == *"_read_iops" ]]; then
        value=${TEST_RESULTS[$key]}
        if (( $(echo "$value > $peak_read_iops" | bc -l) )); then
            peak_read_iops=$value
            peak_read_iops_test=${key%_read_iops}
        fi
    elif [[ $key == *"_write_iops" ]]; then
        value=${TEST_RESULTS[$key]}
        if (( $(echo "$value > $peak_write_iops" | bc -l) )); then
            peak_write_iops=$value
            peak_write_iops_test=${key%_write_iops}
        fi
    elif [[ $key == *"_read_bw" ]]; then
        value=${TEST_RESULTS[$key]}
        if (( $(echo "$value > $peak_read_bw" | bc -l) )); then
            peak_read_bw=$value
            peak_read_bw_test=${key%_read_bw}
        fi
    elif [[ $key == *"_write_bw" ]]; then
        value=${TEST_RESULTS[$key]}
        if (( $(echo "$value > $peak_write_bw" | bc -l) )); then
            peak_write_bw=$value
            peak_write_bw_test=${key%_write_bw}
        fi
    fi
done

# Get latencies for peak IOPS tests
peak_read_iops_lat=${TEST_RESULTS["${peak_read_iops_test}_read_lat"]}
peak_write_iops_lat=${TEST_RESULTS["${peak_write_iops_test}_write_lat"]}

log "Peak Read IOPS:      ${peak_read_iops%.*} @ ${peak_read_iops_lat} µs ($peak_read_iops_test)"
if [ "$SKIP_WRITE_TESTS" = false ]; then
    log "Peak Write IOPS:     ${peak_write_iops%.*} @ ${peak_write_iops_lat} µs ($peak_write_iops_test)"
fi
log "Peak Read Bandwidth: ${peak_read_bw} MB/s ($peak_read_bw_test)"
if [ "$SKIP_WRITE_TESTS" = false ]; then
    log "Peak Write Bandwidth: ${peak_write_bw} MB/s ($peak_write_bw_test)"
fi

# Show baseline latency (QD1) for comparison
qd1_read_lat=${TEST_RESULTS["4k_randread_qd1_nj1_read_lat"]}
qd1_write_lat=${TEST_RESULTS["4k_randwrite_qd1_nj1_write_lat"]}
if [ -n "$qd1_read_lat" ] && (( $(echo "$qd1_read_lat > 0" | bc -l) )); then
    log "Baseline Latency:    Read ${qd1_read_lat} µs, Write ${qd1_write_lat} µs (QD1/nj1)"
fi

# Validate against targets if provided
validation_passed=true

if [ -n "$TARGET_IOPS" ]; then
    log ""
    log "Performance Target Validation:"

    # Check read IOPS
    if (( $(echo "$peak_read_iops >= $TARGET_IOPS" | bc -l) )); then
        log_success "  Read IOPS: ${peak_read_iops%.*} >= $TARGET_IOPS ✓"
    else
        log_error "  Read IOPS: ${peak_read_iops%.*} < $TARGET_IOPS ✗"
        validation_passed=false
    fi

    # Check write IOPS
    if [ "$SKIP_WRITE_TESTS" = false ]; then
        if (( $(echo "$peak_write_iops >= $TARGET_IOPS" | bc -l) )); then
            log_success "  Write IOPS: ${peak_write_iops%.*} >= $TARGET_IOPS ✓"
        else
            log_error "  Write IOPS: ${peak_write_iops%.*} < $TARGET_IOPS ✗"
            validation_passed=false
        fi
    fi
fi

if [ -n "$TARGET_BANDWIDTH" ]; then
    if [ -z "$TARGET_IOPS" ]; then
        log ""
        log "Performance Target Validation:"
    fi

    # Check bandwidth
    if (( $(echo "$peak_read_bw >= $TARGET_BANDWIDTH" | bc -l) )); then
        log_success "  Read Bandwidth: ${peak_read_bw} MB/s >= $TARGET_BANDWIDTH MB/s ✓"
    else
        log_error "  Read Bandwidth: ${peak_read_bw} MB/s < $TARGET_BANDWIDTH MB/s ✗"
        validation_passed=false
    fi

    if [ "$SKIP_WRITE_TESTS" = false ]; then
        if (( $(echo "$peak_write_bw >= $TARGET_BANDWIDTH" | bc -l) )); then
            log_success "  Write Bandwidth: ${peak_write_bw} MB/s >= $TARGET_BANDWIDTH MB/s ✓"
        else
            log_error "  Write Bandwidth: ${peak_write_bw} MB/s < $TARGET_BANDWIDTH MB/s ✗"
            validation_passed=false
        fi
    fi
fi

# Check latency for QD1 4K random read
if [ -n "$TARGET_LATENCY" ]; then
    qd1_read_lat=${TEST_RESULTS["4k_randread_qd1_nj1_read_lat"]}
    if [ -n "$qd1_read_lat" ] && (( $(echo "$qd1_read_lat > 0" | bc -l) )); then
        if [ -z "$TARGET_IOPS" ] && [ -z "$TARGET_BANDWIDTH" ]; then
            log ""
            log "Performance Target Validation:"
        fi

        if (( $(echo "$qd1_read_lat <= $TARGET_LATENCY" | bc -l) )); then
            log_success "  4K Random Read Latency (QD1/nj1): ${qd1_read_lat} µs <= ${TARGET_LATENCY} µs ✓"
        else
            log_error "  4K Random Read Latency (QD1/nj1): ${qd1_read_lat} µs > ${TARGET_LATENCY} µs ✗"
            validation_passed=false
        fi
    fi
fi

# Generate CSV output if requested
if [ -n "$CSV_OUTPUT" ]; then
    log ""
    log "Generating CSV output: $CSV_OUTPUT"

    echo "Test Name,Read IOPS,Write IOPS,Read BW (MB/s),Write BW (MB/s),Read Lat (µs),Write Lat (µs)" > "$CSV_OUTPUT"

    for test_name in $(printf '%s\n' "${!TEST_RESULTS[@]}" | sed 's/_read_iops$//' | sed 's/_write_iops$//' | sed 's/_read_bw$//' | sed 's/_write_bw$//' | sed 's/_read_lat$//' | sed 's/_write_lat$//' | sort -u); do
        read_iops=${TEST_RESULTS["${test_name}_read_iops"]:-0}
        write_iops=${TEST_RESULTS["${test_name}_write_iops"]:-0}
        read_bw=${TEST_RESULTS["${test_name}_read_bw"]:-0}
        write_bw=${TEST_RESULTS["${test_name}_write_bw"]:-0}
        read_lat=${TEST_RESULTS["${test_name}_read_lat"]:-0}
        write_lat=${TEST_RESULTS["${test_name}_write_lat"]:-0}

        echo "$test_name,${read_iops%.*},${write_iops%.*},$read_bw,$write_bw,$read_lat,$write_lat" >> "$CSV_OUTPUT"
    done

    log_success "CSV output generated: $CSV_OUTPUT"
fi

log ""
log "Test results saved to: $OUTPUT_DIR"
log ""

# Generate JSON summary for automated parsing
SUMMARY_JSON="$OUTPUT_DIR/performance_summary.json"
cat > "$SUMMARY_JSON" << EOF
{
  "test_mode": "$TEST_MODE",
  "runtime_per_test": $RUNTIME,
  "device": "$DEVICE",
  "system_info": {
    "cpu_cores": $AVAILABLE_CPUS,
    "max_numjobs_used": $MAX_NUMJOBS
  },
  "peak_performance": {
    "read_iops": ${peak_read_iops%.*},
    "read_iops_latency_us": $peak_read_iops_lat,
    "write_iops": ${peak_write_iops%.*},
    "write_iops_latency_us": $peak_write_iops_lat,
    "read_bandwidth_mbps": $peak_read_bw,
    "write_bandwidth_mbps": $peak_write_bw,
    "read_iops_test": "$peak_read_iops_test",
    "write_iops_test": "$peak_write_iops_test"
  },
  "qd1_performance": {
    "read_iops": ${TEST_RESULTS["4k_randread_qd1_nj1_read_iops"]:-0},
    "write_iops": ${TEST_RESULTS["4k_randwrite_qd1_nj1_write_iops"]:-0},
    "read_latency_us": ${TEST_RESULTS["4k_randread_qd1_nj1_read_lat"]:-0},
    "write_latency_us": ${TEST_RESULTS["4k_randwrite_qd1_nj1_write_lat"]:-0},
    "read_latency_ms": $(echo "scale=3; ${TEST_RESULTS["4k_randread_qd1_nj1_read_lat"]:-0} / 1000" | bc | sed 's/^\./0./'),
    "write_latency_ms": $(echo "scale=3; ${TEST_RESULTS["4k_randwrite_qd1_nj1_write_lat"]:-0} / 1000" | bc | sed 's/^\./0./')
  },
  "all_results": {
EOF

# Add all test results to JSON
first_entry=true
for test_name in $(printf '%s\n' "${!TEST_RESULTS[@]}" | sed 's/_read_iops$//' | sed 's/_write_iops$//' | sed 's/_read_bw$//' | sed 's/_write_bw$//' | sed 's/_read_lat$//' | sed 's/_write_lat$//' | sort -u); do
    read_iops=${TEST_RESULTS["${test_name}_read_iops"]:-0}
    write_iops=${TEST_RESULTS["${test_name}_write_iops"]:-0}
    read_bw=${TEST_RESULTS["${test_name}_read_bw"]:-0}
    write_bw=${TEST_RESULTS["${test_name}_write_bw"]:-0}
    read_lat=${TEST_RESULTS["${test_name}_read_lat"]:-0}
    write_lat=${TEST_RESULTS["${test_name}_write_lat"]:-0}

    if [ "$first_entry" = true ]; then
        first_entry=false
    else
        echo "," >> "$SUMMARY_JSON"
    fi

    cat >> "$SUMMARY_JSON" << TESTEOF
    "$test_name": {
      "read_iops": ${read_iops%.*},
      "write_iops": ${write_iops%.*},
      "read_bandwidth_mbps": $read_bw,
      "write_bandwidth_mbps": $write_bw,
      "read_latency_us": $read_lat,
      "write_latency_us": $write_lat
    }
TESTEOF
done

cat >> "$SUMMARY_JSON" << EOF

  },
  "validation": {
    "target_iops": ${TARGET_IOPS:-null},
    "target_latency_us": ${TARGET_LATENCY:-null},
    "target_bandwidth_mbps": ${TARGET_BANDWIDTH:-null},
    "passed": $([ "$validation_passed" = true ] && echo "true" || echo "false")
  }
}
EOF

log "JSON summary written to: $SUMMARY_JSON"

# Final result
if [ -n "$TARGET_IOPS" ] || [ -n "$TARGET_BANDWIDTH" ] || [ -n "$TARGET_LATENCY" ]; then
    if [ "$validation_passed" = true ]; then
        log_success "🎉 All performance targets met!"
        exit 0
    else
        log_error "❌ Performance validation failed"
        exit 1
    fi
else
    log_success "🎉 Performance testing completed successfully!"
    exit 0
fi
