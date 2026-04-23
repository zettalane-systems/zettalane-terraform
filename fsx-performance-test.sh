#!/bin/bash
# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.


# MayaScale FSx/ZFS Mirror Performance Test
# Tests NFS over ZFS mirrors or local ZFS performance
# Outputs JSON metrics for validation by parent script

# Note: set -e disabled to allow graceful error handling
# Most commands have explicit error handling with || true or || echo "0"

# Usage
usage() {
    cat << EOF
MayaScale FSx/ZFS Mirror Performance Test

Runs FIO tests and outputs JSON metrics (no validation).
Based on Google Filestore testing methodology.

Usage: $0 --mode MODE [OPTIONS] [NFS_SHARES...]

REQUIRED:
    --mode MODE              Test mode: nfs or zfs

MODE-SPECIFIC (positional arguments after options):
    For nfs mode: List NFS shares as positional arguments (e.g., "10.0.1.10:/pool/share1")
    For zfs mode: --zfs-path /PATH (local ZFS path)

OPTIONAL:
    --runtime SECONDS        Runtime per test (default: 300)
    --numjobs NUM            Number of parallel FIO jobs (default: 10)
    --output-file FILE       JSON output file (default: stdout)
    --nconnect NUM           NFS nconnect value (default: 16)
    --rdma                   Use NFS over RDMA transport (port 20049)
    --sequential-only        Skip random I/O tests (only sequential read/write)
    --iops-shares SHARE...   NFS shares to run IOPS tests on (if not specified, no IOPS tests)
    --mount-base NAME        Mount base name: mayanas or mayascale (default: mayascale)
    --zfs-path /PATH         Local ZFS path (required for zfs mode)
    --server-ram-gb NUM      Server RAM in GB (for NFS mode, auto-detected if not specified)
    -h, --help               Show this help

EXAMPLES:
    # NFS client testing (single share)
    $0 --mode nfs "10.0.1.10:/data-pool-1/share1"

    # NFS client testing (multiple shares)
    $0 --mode nfs "10.0.1.10:/data-pool-1/share1" "10.0.1.11:/data-pool-2/share1"

    # Sequential-only testing (skip random I/O, faster for NFS validation)
    $0 --mode nfs --sequential-only --runtime 180 "10.0.1.10:/data-pool-1/share1"

    # NFS over RDMA testing (requires RDMA hardware and server support)
    $0 --mode nfs --rdma "10.0.1.10:/data-pool-1/share1"

    # Quick validation (60s per test instead of 300s)
    $0 --mode nfs --runtime 60 "10.0.1.10:/data-pool-1/share1"

    # Local ZFS testing (on storage node)
    $0 --mode zfs --zfs-path /data-pool-1/share1

OUTPUT:
    JSON format with IOPS and throughput metrics
EOF
}

# Parse arguments
MODE=""
NFS_MOUNTS=()
IOPS_SHARES=()
ZFS_PATH=""
RUNTIME=300
NUMJOBS=10  # Default number of parallel FIO jobs
OUTPUT_FILE=""
NCONNECT=16
NFS_RDMA=false
SEQUENTIAL_ONLY=false
MOUNT_BASE="${MOUNT_BASE:-mayascale}"  # Default to mayascale, can override via env var
SERVER_RAM_GB=""  # Server RAM for NFS mode (auto-detected if not specified)

while [[ $# -gt 0 ]]; do
    case $1 in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --zfs-path)
            ZFS_PATH="$2"
            shift 2
            ;;
        --runtime)
            RUNTIME="$2"
            shift 2
            ;;
        --numjobs)
            NUMJOBS="$2"
            shift 2
            ;;
        --output-file)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --nconnect)
            NCONNECT="$2"
            shift 2
            ;;
        --mount-base)
            MOUNT_BASE="$2"
            shift 2
            ;;
        --server-ram-gb)
            SERVER_RAM_GB="$2"
            shift 2
            ;;
        --iops-shares)
            shift
            # Collect all IOPS shares until next option or end
            while [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; do
                IOPS_SHARES+=("$1")
                shift
            done
            ;;
        --rdma)
            NFS_RDMA=true
            shift
            ;;
        --sequential-only)
            SEQUENTIAL_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            # End of options marker
            shift
            break
            ;;
        *)
            # Positional arguments (NFS shares for nfs mode) - collect and continue
            NFS_MOUNTS+=("$1")
            shift
            ;;
    esac
done

# Remaining arguments after -- are also NFS shares
NFS_MOUNTS+=("$@")

# Validate inputs
if [ -z "$MODE" ]; then
    echo "Error: --mode is required" >&2
    usage
    exit 1
fi

if [ "$MODE" != "nfs" ] && [ "$MODE" != "zfs" ]; then
    echo "Error: --mode must be 'nfs' or 'zfs'" >&2
    usage
    exit 1
fi

if [ "$MODE" = "nfs" ] && [ ${#NFS_MOUNTS[@]} -eq 0 ]; then
    echo "Error: NFS shares must be provided as positional arguments for nfs mode" >&2
    echo "Example: $0 --mode nfs \"10.0.1.10:/pool/share1\" \"10.0.1.11:/pool/share2\"" >&2
    usage
    exit 1
fi

if [ "$MODE" = "zfs" ] && [ -z "$ZFS_PATH" ]; then
    echo "Error: --zfs-path is required for zfs mode" >&2
    usage
    exit 1
fi

# Ensure fio and jq are installed (suppress all output)
if ! command -v fio &> /dev/null; then
    echo "Installing fio..." >&2
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq &> /dev/null
        sudo apt-get install -qq -y fio &> /dev/null
    elif command -v yum &> /dev/null; then
        sudo yum install -q -y fio &> /dev/null
    elif command -v dnf &> /dev/null; then
        sudo dnf install -q -y fio &> /dev/null
    else
        echo "Error: Could not install fio" >&2
        exit 1
    fi
fi

if ! command -v jq &> /dev/null; then
    echo "Installing jq..." >&2
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq &> /dev/null
        sudo apt-get install -qq -y jq &> /dev/null
    elif command -v yum &> /dev/null; then
        sudo yum install -q -y jq &> /dev/null
    elif command -v dnf &> /dev/null; then
        sudo dnf install -q -y jq &> /dev/null
    else
        echo "Error: Could not install jq" >&2
        exit 1
    fi
fi

# Ensure NFS client tools are installed for NFS mode
if [ "$MODE" = "nfs" ]; then
    if ! mount.nfs -V &> /dev/null && ! mount.nfs4 -V &> /dev/null; then
        echo "Installing NFS client tools..." >&2
        if command -v apt-get &> /dev/null; then
            sudo apt-get update -qq &> /dev/null
            sudo apt-get install -qq -y nfs-common &> /dev/null
        elif command -v yum &> /dev/null; then
            sudo yum install -q -y nfs-utils &> /dev/null
        elif command -v dnf &> /dev/null; then
            sudo dnf install -q -y nfs-utils &> /dev/null
        else
            echo "Error: Could not install NFS client tools" >&2
            exit 1
        fi
    fi

    # Check RDMA availability if requested
    if [ "$NFS_RDMA" = true ]; then
        echo "Checking NFS RDMA availability..." >&2
        # Check for RDMA devices first
        if [ ! -d /sys/class/infiniband ] || [ -z "$(ls /sys/class/infiniband 2>/dev/null)" ]; then
            echo "  No RDMA devices found - falling back to TCP" >&2
            NFS_RDMA=false
        else
            # Load xprtrdma module for NFS client RDMA
            if ! modprobe xprtrdma 2>/dev/null; then
                echo "  Could not load xprtrdma module - falling back to TCP" >&2
                NFS_RDMA=false
            else
                echo "  Found RDMA devices: $(ls /sys/class/infiniband 2>/dev/null | tr '\n' ' ')" >&2
            fi
        fi
    fi
fi

# Create temp directory for FIO results (JSON files)
# Use /tmp/perf-results for all outputs so validate script can collect them
RESULTS_DIR="/tmp/perf-results"
mkdir -p "$RESULTS_DIR"

# Also create a temp dir for intermediate fio JSON outputs (will be cleaned up)
FIO_TEMP_DIR=$(mktemp -d)
trap "rm -rf $FIO_TEMP_DIR" EXIT

# Setup test directories based on mode
FIO_DIRS=""
MOUNT_POINTS=()  # Track all mount points for cleanup

if [ "$MODE" = "nfs" ]; then
    # Cleanup any stale mounts from previous runs
    echo "Checking for stale NFS mounts..." >&2
    for i in {1..10}; do
        STALE_MOUNT="/mnt/${MOUNT_BASE}-nfs-$i"
        if mountpoint -q "$STALE_MOUNT" 2>/dev/null; then
            echo "  Unmounting stale mount: $STALE_MOUNT" >&2
            umount "$STALE_MOUNT" 2>/dev/null || umount -f "$STALE_MOUNT" 2>/dev/null || true
        fi
        # Remove test directories from previous runs
        if [ -d "$STALE_MOUNT/fio-test" ]; then
            rm -rf "$STALE_MOUNT/fio-test" 2>/dev/null || true
        fi
    done

    # Combine NFS_MOUNTS and IOPS_SHARES into a single list of all shares to mount
    ALL_SHARES=("${NFS_MOUNTS[@]}")
    for iops_share in "${IOPS_SHARES[@]}"; do
        # Add IOPS share if not already in the list
        if [[ ! " ${ALL_SHARES[@]} " =~ " ${iops_share} " ]]; then
            ALL_SHARES+=("$iops_share")
        fi
    done

    # Track mapping of mount point to original NFS path
    declare -A MOUNT_TO_NFS_MAP
    declare -A IP_TO_NODE_NUM  # Map IP address to node number
    declare -A REACHABLE_SERVERS  # Track which servers responded to ping
    declare -a UNIQUE_IPS      # Track unique IPs in order
    NODE_COUNTER=0

    # Extract all unique server IPs and check reachability
    echo "Checking server reachability..." >&2
    for NFS_MOUNT in "${ALL_SHARES[@]}"; do
        NFS_IP=$(echo "$NFS_MOUNT" | cut -d: -f1)
        if [ -z "${REACHABLE_SERVERS[$NFS_IP]}" ]; then
            if ping -c 1 -W 2 "$NFS_IP" &>/dev/null; then
                REACHABLE_SERVERS[$NFS_IP]=1
                echo "  ✓ $NFS_IP reachable" >&2
            else
                REACHABLE_SERVERS[$NFS_IP]=0
                echo "  ✗ $NFS_IP unreachable" >&2
            fi
        fi
    done

    # Count reachable servers
    NUM_REACHABLE=0
    for ip in "${!REACHABLE_SERVERS[@]}"; do
        [ "${REACHABLE_SERVERS[$ip]}" = "1" ] && ((NUM_REACHABLE++))
    done
    echo "Reachable servers: $NUM_REACHABLE" >&2

    # Mount shares from reachable servers only
    echo "Mounting NFS shares..." >&2
    SHARE_INDEX=0
    for NFS_MOUNT in "${ALL_SHARES[@]}"; do
        SHARE_INDEX=$((SHARE_INDEX + 1))

        # Extract IP and share name
        NFS_IP=$(echo "$NFS_MOUNT" | cut -d: -f1)
        NFS_SHARE=$(echo "$NFS_MOUNT" | cut -d/ -f3)

        # Skip unreachable servers
        if [ "${REACHABLE_SERVERS[$NFS_IP]}" != "1" ]; then
            echo "  [$SHARE_INDEX/${#ALL_SHARES[@]}] Skipping: $NFS_MOUNT (server unreachable)" >&2
            continue
        fi

        # Assign node number based on first occurrence of IP
        if [ -z "${IP_TO_NODE_NUM[$NFS_IP]}" ]; then
            NODE_COUNTER=$((NODE_COUNTER + 1))
            IP_TO_NODE_NUM[$NFS_IP]=$NODE_COUNTER
            UNIQUE_IPS+=("$NFS_IP")
        fi
        NODE_NUM=${IP_TO_NODE_NUM[$NFS_IP]}

        # Mount point: /mnt/mayascale1-share1, /mnt/mayascale2-share1, etc.
        MOUNT_POINT="/mnt/${MOUNT_BASE}${NODE_NUM}-${NFS_SHARE}"
        mkdir -p "$MOUNT_POINT"

        echo "  [$SHARE_INDEX/${#ALL_SHARES[@]}] Mounting: $NFS_MOUNT" >&2
        echo "      → $MOUNT_POINT" >&2

        # Build mount options based on transport
        if [ "$NFS_RDMA" = true ]; then
            MOUNT_OPTS="proto=rdma,port=20049,rsize=1048576,wsize=1048576"
            echo "      Transport: RDMA (port 20049)" >&2
        else
            MOUNT_OPTS="nconnect=$NCONNECT,rsize=1048576,wsize=1048576"
            echo "      Transport: TCP (nconnect=$NCONNECT)" >&2
        fi

        if mount -t nfs -o "$MOUNT_OPTS" "$NFS_MOUNT" "$MOUNT_POINT" 2>&1; then
            TEST_DIR="$MOUNT_POINT/fio-test"
            mkdir -p "$TEST_DIR"
            # Track mount point for cleanup and map to NFS path
            MOUNT_POINTS+=("$MOUNT_POINT")
            MOUNT_TO_NFS_MAP["$MOUNT_POINT"]="$NFS_MOUNT"
            # Add directory to colon-separated list for FIO
            if [ -z "$FIO_DIRS" ]; then
                FIO_DIRS="$TEST_DIR"
            else
                FIO_DIRS="${FIO_DIRS}:${TEST_DIR}"
            fi
            echo "      ✓ Mounted -> $TEST_DIR" >&2
        else
            echo "      ✗ Failed to mount" >&2
        fi
    done

    if [ -z "$FIO_DIRS" ]; then
        echo "Error: Failed to mount any NFS shares" >&2
        exit 1
    fi

    DIRECT_FLAG="1"
    MOUNTED_BY_SCRIPT=true
    # Set TARGET to comma-separated list of all NFS shares
    TARGET="${NFS_MOUNTS[*]}"

    # Display test plan summary
    echo "" >&2
    echo "=== Test Plan Summary ===" >&2
    echo "Reachable servers: $NUM_REACHABLE" >&2
    echo "Successfully mounted: ${#MOUNT_POINTS[@]}/${#ALL_SHARES[@]} shares" >&2
    if [ $NUM_REACHABLE -ge 2 ]; then
        echo "  Concurrent tests:       YES ($NUM_REACHABLE servers)" >&2
    else
        echo "  Concurrent tests:       SKIP (need 2+ servers, have $NUM_REACHABLE)" >&2
    fi
    if [ ${#NFS_MOUNTS[@]} -gt 1 ]; then
        echo "  Sequential (perf-test): ${#NFS_MOUNTS[@]} shares requested" >&2
    else
        echo "  Sequential (perf-test): ${#NFS_MOUNTS[@]} share" >&2
    fi
    if [ ${#IOPS_SHARES[@]} -gt 1 ]; then
        echo "  IOPS (perf-iops):       ${#IOPS_SHARES[@]} shares requested" >&2
    elif [ ${#IOPS_SHARES[@]} -eq 1 ]; then
        echo "  IOPS (perf-iops):       ${#IOPS_SHARES[@]} share" >&2
    else
        echo "  Concurrent IOPS:        SKIP (no IOPS shares)" >&2
    fi
    echo "" >&2
else
    # Use local ZFS path
    if [ ! -d "$ZFS_PATH" ]; then
        echo "Error: ZFS path does not exist: $ZFS_PATH" >&2
        exit 1
    fi

    TEST_DIR="$ZFS_PATH/fio-test"
    mkdir -p "$TEST_DIR"
    FIO_DIRS="$TEST_DIR"
    DIRECT_FLAG="0"  # ZFS requires buffered I/O
    MOUNTED_BY_SCRIPT=false
    TARGET="$ZFS_PATH"
fi

echo "" >&2
echo "Starting FSx performance tests ($MODE mode)..." >&2
if [ "$MODE" = "nfs" ]; then
    if [ "$NFS_RDMA" = true ]; then
        echo "NFS Transport: RDMA (port 20049)" >&2
    else
        echo "NFS Transport: TCP (nconnect=$NCONNECT)" >&2
    fi
fi
echo "Direct I/O: $DIRECT_FLAG" >&2
echo "Runtime: ${RUNTIME}s per test" >&2
echo "" >&2

# FIO parameters optimized for NFS performance testing
# Note: Google Filestore methodology (libaio, high iodepth) doesn't work for general NFS
# Using psync + iodepth=1 allows NFS protocol to handle queuing/batching optimally
# Parallelism comes from numjobs and nconnect, not deep I/O queues

# Auto-detect RAM and calculate appropriate test size to defeat cache
# Use --server-ram-gb if specified, otherwise detect local RAM
if [ -n "$SERVER_RAM_GB" ]; then
    TOTAL_RAM_GB="$SERVER_RAM_GB"
    echo "Using specified RAM: ${TOTAL_RAM_GB}GB" >&2
else
    TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    echo "Detected local RAM: ${TOTAL_RAM_GB}GB" >&2
fi

# Calculate test size: 25% larger than RAM to force cache eviction via LRU pressure
# With working set > available cache, reads will hit storage instead of cache
# LRU eviction creates cache misses at "edges" of sequential reads in continuous tests
TOTAL_TEST_SIZE_GB=$((TOTAL_RAM_GB * 125 / 100))
echo "Calculated total test size: ${TOTAL_TEST_SIZE_GB}GB (RAM + 25% overhead)" >&2

# NUMJOBS is configured via --numjobs parameter (default: 10)
# Calculate file size per job
FILESIZE_GB=$((TOTAL_TEST_SIZE_GB / NUMJOBS))
FILESIZE="${FILESIZE_GB}G"

echo "Test configuration: ${NUMJOBS} jobs × ${FILESIZE} = ${TOTAL_TEST_SIZE_GB}GB total" >&2

# Note: dstat monitoring is handled by the calling script (validate-mayanas.sh)
# This script focuses solely on running performance tests

# Function to run tests on a single directory/share
run_test_on_share() {
    local test_dir="$1"
    local share_index="$2"
    local result_prefix="$3"
    local nfs_mount="$4"  # NFS mount path for IOPS share check

    echo "  Testing share ${share_index}: $test_dir" >&2

    #######################################
    # Sequential Write
    #######################################
    fio --name=fiotest \
        --directory="$test_dir" \
        --size=$FILESIZE \
        --rw=write \
        --bs=1m \
        --ioengine=psync \
        --iodepth=1 \
        --numjobs=$NUMJOBS \
        --direct=$DIRECT_FLAG \
        --runtime=$RUNTIME \
        --time_based \
        --ramp_time=2 \
        --group_reporting \
        --output-format=json \
        --output="$FIO_TEMP_DIR/${result_prefix}_write.json" 2>&1 | grep -v "^fio-" || true

    local write_bw=$(jq -r '.jobs[0].write.bw / 1024' "$FIO_TEMP_DIR/${result_prefix}_write.json" 2>/dev/null || echo "0")
    local write_start_epoch=$(jq -r '.jobs[0].job_start / 1000 | floor' "$FIO_TEMP_DIR/${result_prefix}_write.json" 2>/dev/null || echo "0")
    local write_end_epoch=$(jq -r '.timestamp // 0' "$FIO_TEMP_DIR/${result_prefix}_write.json" 2>/dev/null || echo "0")
    echo "    Write: ${write_bw%.*} MB/s" >&2

    #######################################
    # Sequential Read
    #######################################
    fio --name=fiotest \
        --directory="$test_dir" \
        --size=$FILESIZE \
        --rw=read \
        --bs=1m \
        --ioengine=psync \
        --iodepth=1 \
        --numjobs=$NUMJOBS \
        --direct=$DIRECT_FLAG \
        --runtime=$RUNTIME \
        --time_based \
        --ramp_time=2 \
        --group_reporting \
        --output-format=json \
        --output="$FIO_TEMP_DIR/${result_prefix}_read.json" 2>&1 | grep -v "^fio-" || true

    local read_bw=$(jq -r '.jobs[0].read.bw / 1024' "$FIO_TEMP_DIR/${result_prefix}_read.json" 2>/dev/null || echo "0")
    local read_start_epoch=$(jq -r '.jobs[0].job_start / 1000 | floor' "$FIO_TEMP_DIR/${result_prefix}_read.json" 2>/dev/null || echo "0")
    local read_end_epoch=$(jq -r '.timestamp // 0' "$FIO_TEMP_DIR/${result_prefix}_read.json" 2>/dev/null || echo "0")
    echo "    Read: ${read_bw%.*} MB/s" >&2

    # Random I/O (if not skipped)
    local randwrite_iops="0"
    local randwrite_lat="0"
    local randread_iops="0"
    local randread_lat="0"

    # Check if this share should run IOPS tests
    local run_iops=false
    if [ ${#IOPS_SHARES[@]} -gt 0 ]; then
        # IOPS shares specified - only run on matching shares
        for iops_share in "${IOPS_SHARES[@]}"; do
            if [ "$nfs_mount" = "$iops_share" ]; then
                run_iops=true
                break
            fi
        done
    fi

    if [ "$SEQUENTIAL_ONLY" = false ] && [ "$run_iops" = true ]; then
        #######################################
        # 4K Random Write
        #######################################
        fio --name=fiotest \
            --directory="$test_dir" \
            --size=$FILESIZE \
            --rw=randwrite \
            --bs=4k \
            --ioengine=libaio \
            --iodepth=8 \
            --numjobs=$NUMJOBS \
            --direct=$DIRECT_FLAG \
            --runtime=$RUNTIME \
            --time_based \
            --ramp_time=2 \
            --group_reporting \
            --output-format=json \
            --output="$FIO_TEMP_DIR/${result_prefix}_randwrite.json" 2>&1 | grep -v "^fio-" || true

        randwrite_iops=$(jq -r '.jobs[0].write.iops' "$FIO_TEMP_DIR/${result_prefix}_randwrite.json" 2>/dev/null || echo "0")
        randwrite_lat=$(jq -r '.jobs[0].write.lat_ns.mean / 1000' "$FIO_TEMP_DIR/${result_prefix}_randwrite.json" 2>/dev/null || echo "0")
        echo "    Random Write: ${randwrite_iops%.*} IOPS @ ${randwrite_lat%.*} µs" >&2

        #######################################
        # 4K Random Read
        #######################################
        fio --name=fiotest \
            --directory="$test_dir" \
            --size=$FILESIZE \
            --rw=randread \
            --bs=4k \
            --ioengine=libaio \
            --iodepth=8 \
            --numjobs=$NUMJOBS \
            --direct=$DIRECT_FLAG \
            --runtime=$RUNTIME \
            --time_based \
            --ramp_time=2 \
            --group_reporting \
            --output-format=json \
            --output="$FIO_TEMP_DIR/${result_prefix}_randread.json" 2>&1 | grep -v "^fio-" || true

        randread_iops=$(jq -r '.jobs[0].read.iops' "$FIO_TEMP_DIR/${result_prefix}_randread.json" 2>/dev/null || echo "0")
        randread_lat=$(jq -r '.jobs[0].read.lat_ns.mean / 1000' "$FIO_TEMP_DIR/${result_prefix}_randread.json" 2>/dev/null || echo "0")
        echo "    Random Read: ${randread_iops%.*} IOPS @ ${randread_lat%.*} µs" >&2
    fi

    # Return results as JSON with timing information
    jq -n \
        --argjson write "${write_bw%.*}" \
        --argjson read "${read_bw%.*}" \
        --argjson write_start "${write_start_epoch%.*}" \
        --argjson write_end "${write_end_epoch%.*}" \
        --argjson read_start "${read_start_epoch%.*}" \
        --argjson read_end "${read_end_epoch%.*}" \
        --argjson randwrite_iops "${randwrite_iops%.*}" \
        --argjson randwrite_lat "${randwrite_lat%.*}" \
        --argjson randread_iops "${randread_iops%.*}" \
        --argjson randread_lat "${randread_lat%.*}" \
        '{
            write_mbps: $write,
            read_mbps: $read,
            write_start_epoch: $write_start,
            write_end_epoch: $write_end,
            read_start_epoch: $read_start,
            read_end_epoch: $read_end,
            randwrite_iops: $randwrite_iops,
            randwrite_lat_us: $randwrite_lat,
            randread_iops: $randread_iops,
            randread_lat_us: $randread_lat
        }'
}

#######################################
# Main Test Logic
#######################################

# For multiple NFS shares, test in phases: sequential first, then IOPS
if [ "$MODE" = "nfs" ] && [ ${#ALL_SHARES[@]} -gt 0 ]; then
    # Arrays to store per-share results for all shares
    declare -a SHARE_WRITE_BW
    declare -a SHARE_READ_BW
    declare -a SHARE_WRITE_START
    declare -a SHARE_WRITE_END
    declare -a SHARE_READ_START
    declare -a SHARE_READ_END
    declare -a SHARE_RANDWRITE_IOPS
    declare -a SHARE_RANDREAD_IOPS

    #######################################
    # PHASE 1: Sequential tests on NFS_MOUNTS shares (perf-test)
    #######################################
    if [ ${#NFS_MOUNTS[@]} -gt 0 ]; then
        echo "=== Phase 1: Sequential Bandwidth Tests ===" >&2
        echo "Testing ${#NFS_MOUNTS[@]} perf-test share(s) individually..." >&2
        echo "" >&2

        # Build FIO_DIRS for sequential shares only
        SEQ_FIO_DIRS=""
        share_index=1
        for nfs_mount in "${NFS_MOUNTS[@]}"; do
            # Find the mount point for this NFS mount
            mount_point=""
            for mp in "${!MOUNT_TO_NFS_MAP[@]}"; do
                if [ "${MOUNT_TO_NFS_MAP[$mp]}" = "$nfs_mount" ]; then
                    mount_point="$mp"
                    break
                fi
            done

            if [ -z "$mount_point" ]; then
                echo "Error: Could not find mount point for $nfs_mount" >&2
                continue
            fi

            test_dir="${mount_point}/fio-test"
            echo "Testing share ${share_index}/${#NFS_MOUNTS[@]}: $test_dir" >&2

            # Add to SEQ_FIO_DIRS for concurrent test
            if [ -z "$SEQ_FIO_DIRS" ]; then
                SEQ_FIO_DIRS="$test_dir"
            else
                SEQ_FIO_DIRS="${SEQ_FIO_DIRS}:${test_dir}"
            fi

            # Run sequential tests only
            result=$(run_test_on_share "$test_dir" "$share_index" "seq${share_index}" "$nfs_mount")

            # Extract sequential results
            SHARE_WRITE_BW+=("$(echo "$result" | jq -r '.write_mbps')")
            SHARE_READ_BW+=("$(echo "$result" | jq -r '.read_mbps')")
            SHARE_WRITE_START+=("$(echo "$result" | jq -r '.write_start_epoch')")
            SHARE_WRITE_END+=("$(echo "$result" | jq -r '.write_end_epoch')")
            SHARE_READ_START+=("$(echo "$result" | jq -r '.read_start_epoch')")
            SHARE_READ_END+=("$(echo "$result" | jq -r '.read_end_epoch')")
            # No IOPS for sequential shares
            SHARE_RANDWRITE_IOPS+=("0")
            SHARE_RANDREAD_IOPS+=("0")

            echo "" >&2
            ((share_index++))
        done

        # Calculate sequential aggregates
        SEQWRITE_BW=0
        SEQREAD_BW=0
        for i in "${!SHARE_WRITE_BW[@]}"; do
            SEQWRITE_BW=$(echo "$SEQWRITE_BW + ${SHARE_WRITE_BW[$i]}" | bc)
            SEQREAD_BW=$(echo "$SEQREAD_BW + ${SHARE_READ_BW[$i]}" | bc)
        done

        echo "=== Individual Sequential Share Summary ===" >&2
        echo "  Summed Write: ${SEQWRITE_BW%.*} MB/s" >&2
        echo "  Summed Read: ${SEQREAD_BW%.*} MB/s" >&2
        echo "" >&2
    fi

    #######################################
    # PHASE 2: Concurrent sequential test on NFS_MOUNTS shares
    #######################################
    CONCURRENT_WRITE_BW="0"
    CONCURRENT_READ_BW="0"
    CONCURRENT_WRITE_START="0"
    CONCURRENT_WRITE_END="0"
    CONCURRENT_READ_START="0"
    CONCURRENT_READ_END="0"

    # Only run concurrent test if multiple servers reachable
    if [ $NUM_REACHABLE -ge 2 ]; then
        echo "=== Phase 2: Concurrent Sequential Test ===" >&2
        echo "Testing $NUM_REACHABLE servers together..." >&2
        echo "Testing: $SEQ_FIO_DIRS" >&2
    else
        echo "=== Phase 2: Concurrent Sequential Test ===" >&2
        echo "Skipping concurrent test (need 2+ servers, have $NUM_REACHABLE)" >&2
        echo "" >&2
    fi

    if [ $NUM_REACHABLE -ge 2 ]; then

        # Calculate concurrent numjobs
        SEQ_CONCURRENT_NUMJOBS=$((NUMJOBS * NUM_REACHABLE))
        echo "Using ${SEQ_CONCURRENT_NUMJOBS} jobs (${NUMJOBS} per server)" >&2
        echo "" >&2

        # Concurrent sequential write test
        echo "Running concurrent 1M sequential write test..." >&2
        fio --name=fiotest \
            --directory="$SEQ_FIO_DIRS" \
            --size=$FILESIZE \
            --rw=write \
            --bs=1m \
            --ioengine=psync \
            --iodepth=1 \
            --numjobs=$SEQ_CONCURRENT_NUMJOBS \
            --direct=$DIRECT_FLAG \
            --runtime=$RUNTIME \
            --time_based \
            --ramp_time=2 \
            --group_reporting \
            --output-format=json \
            --output="$FIO_TEMP_DIR/concurrent_seqwrite.json" 2>&1 | grep -v "^fio-" || true

        CONCURRENT_WRITE_BW=$(jq -r '.jobs[0].write.bw / 1024' "$FIO_TEMP_DIR/concurrent_seqwrite.json" 2>/dev/null || echo "0")
        CONCURRENT_WRITE_START=$(jq -r '.jobs[0].job_start / 1000 | floor' "$FIO_TEMP_DIR/concurrent_seqwrite.json" 2>/dev/null || echo "0")
        CONCURRENT_WRITE_END=$(jq -r '.timestamp' "$FIO_TEMP_DIR/concurrent_seqwrite.json" 2>/dev/null || echo "0")

        echo "  Concurrent Write: ${CONCURRENT_WRITE_BW%.*} MB/s" >&2

        # Concurrent sequential read test
        echo "Running concurrent 1M sequential read test..." >&2
        fio --name=fiotest \
            --directory="$SEQ_FIO_DIRS" \
            --size=$FILESIZE \
            --rw=read \
            --bs=1m \
            --ioengine=psync \
            --iodepth=1 \
            --numjobs=$SEQ_CONCURRENT_NUMJOBS \
            --direct=$DIRECT_FLAG \
            --runtime=$RUNTIME \
            --time_based \
            --ramp_time=2 \
            --group_reporting \
            --output-format=json \
            --output="$FIO_TEMP_DIR/concurrent_seqread.json" 2>&1 | grep -v "^fio-" || true

        CONCURRENT_READ_BW=$(jq -r '.jobs[0].read.bw / 1024' "$FIO_TEMP_DIR/concurrent_seqread.json" 2>/dev/null || echo "0")
        CONCURRENT_READ_START=$(jq -r '.jobs[0].job_start / 1000 | floor' "$FIO_TEMP_DIR/concurrent_seqread.json" 2>/dev/null || echo "0")
        CONCURRENT_READ_END=$(jq -r '.timestamp' "$FIO_TEMP_DIR/concurrent_seqread.json" 2>/dev/null || echo "0")

        echo "  Concurrent Read: ${CONCURRENT_READ_BW%.*} MB/s" >&2
        echo "" >&2
    fi

    #######################################
    # PHASE 3: Individual IOPS tests on IOPS_SHARES (if specified)
    #######################################
    CONCURRENT_RANDWRITE_IOPS="0"
    CONCURRENT_RANDREAD_IOPS="0"

    if [ ${#IOPS_SHARES[@]} -gt 0 ] && [ "$SEQUENTIAL_ONLY" = false ]; then
        echo "=== Phase 3: Individual IOPS Tests ===" >&2
        echo "Testing ${#IOPS_SHARES[@]} perf-iops share(s) individually..." >&2
        echo "" >&2

        # Build FIO_DIRS for IOPS shares only
        IOPS_FIO_DIRS=""
        share_index=1
        for iops_mount in "${IOPS_SHARES[@]}"; do
            # Find the mount point for this IOPS share
            mount_point=""
            for mp in "${!MOUNT_TO_NFS_MAP[@]}"; do
                if [ "${MOUNT_TO_NFS_MAP[$mp]}" = "$iops_mount" ]; then
                    mount_point="$mp"
                    break
                fi
            done

            if [ -z "$mount_point" ]; then
                echo "Error: Could not find mount point for $iops_mount" >&2
                continue
            fi

            test_dir="${mount_point}/fio-test"
            echo "Testing share ${share_index}/${#IOPS_SHARES[@]}: $test_dir" >&2

            # Add to IOPS_FIO_DIRS for concurrent test
            if [ -z "$IOPS_FIO_DIRS" ]; then
                IOPS_FIO_DIRS="$test_dir"
            else
                IOPS_FIO_DIRS="${IOPS_FIO_DIRS}:${test_dir}"
            fi

            # Run 4K random write test
            echo "  Running 4K random write test..." >&2
            fio --name=fiotest \
                --directory="$test_dir" \
                --size=$FILESIZE \
                --rw=randwrite \
                --bs=4k \
                --ioengine=libaio \
                --iodepth=8 \
                --numjobs=$NUMJOBS \
                --direct=$DIRECT_FLAG \
                --runtime=$RUNTIME \
                --time_based \
                --ramp_time=2 \
                --group_reporting \
                --output-format=json \
                --output="$FIO_TEMP_DIR/iops${share_index}_randwrite.json" 2>&1 | grep -v "^fio-" || true

            randwrite_iops=$(jq -r '.jobs[0].write.iops' "$FIO_TEMP_DIR/iops${share_index}_randwrite.json" 2>/dev/null || echo "0")
            randwrite_lat=$(jq -r '.jobs[0].write.lat_ns.mean / 1000' "$FIO_TEMP_DIR/iops${share_index}_randwrite.json" 2>/dev/null || echo "0")
            echo "    Random Write: ${randwrite_iops%.*} IOPS @ ${randwrite_lat%.*} µs" >&2

            # Run 4K random read test
            echo "  Running 4K random read test..." >&2
            fio --name=fiotest \
                --directory="$test_dir" \
                --size=$FILESIZE \
                --rw=randread \
                --bs=4k \
                --ioengine=libaio \
                --iodepth=8 \
                --numjobs=$NUMJOBS \
                --direct=$DIRECT_FLAG \
                --runtime=$RUNTIME \
                --time_based \
                --ramp_time=2 \
                --group_reporting \
                --output-format=json \
                --output="$FIO_TEMP_DIR/iops${share_index}_randread.json" 2>&1 | grep -v "^fio-" || true

            randread_iops=$(jq -r '.jobs[0].read.iops' "$FIO_TEMP_DIR/iops${share_index}_randread.json" 2>/dev/null || echo "0")
            randread_lat=$(jq -r '.jobs[0].read.lat_ns.mean / 1000' "$FIO_TEMP_DIR/iops${share_index}_randread.json" 2>/dev/null || echo "0")
            echo "    Random Read: ${randread_iops%.*} IOPS @ ${randread_lat%.*} µs" >&2

            # Add to results arrays (append after sequential shares)
            SHARE_WRITE_BW+=("0")  # No sequential tests for IOPS shares
            SHARE_READ_BW+=("0")
            SHARE_WRITE_START+=("0")
            SHARE_WRITE_END+=("0")
            SHARE_READ_START+=("0")
            SHARE_READ_END+=("0")
            SHARE_RANDWRITE_IOPS+=("$randwrite_iops")
            SHARE_RANDREAD_IOPS+=("$randread_iops")
            SHARE_RANDWRITE_LAT+=("$randwrite_lat")
            SHARE_RANDREAD_LAT+=("$randread_lat")

            echo "" >&2
            ((share_index++))
        done

        # Calculate IOPS aggregates
        RANDWRITE_IOPS=0
        RANDREAD_IOPS=0
        # Sum only the IOPS shares (skip the first NFS_MOUNTS entries)
        for ((i=${#NFS_MOUNTS[@]}; i<${#SHARE_RANDWRITE_IOPS[@]}; i++)); do
            RANDWRITE_IOPS=$(echo "$RANDWRITE_IOPS + ${SHARE_RANDWRITE_IOPS[$i]}" | bc)
            RANDREAD_IOPS=$(echo "$RANDREAD_IOPS + ${SHARE_RANDREAD_IOPS[$i]}" | bc)
        done

        echo "=== Individual IOPS Share Summary ===" >&2
        echo "  Summed Random Write: ${RANDWRITE_IOPS%.*} IOPS" >&2
        echo "  Summed Random Read: ${RANDREAD_IOPS%.*} IOPS" >&2
        echo "" >&2
    fi

    #######################################
    # PHASE 4: Concurrent IOPS test on IOPS_SHARES (if specified)
    #######################################
    # Only run concurrent IOPS test if multiple servers reachable
    if [ $NUM_REACHABLE -ge 2 ] && [ ${#IOPS_SHARES[@]} -gt 0 ] && [ "$SEQUENTIAL_ONLY" = false ]; then
        echo "=== Phase 4: Concurrent IOPS Test ===" >&2
        echo "Testing $NUM_REACHABLE servers together..." >&2
        echo "Testing: $IOPS_FIO_DIRS" >&2

        # Calculate concurrent numjobs
        IOPS_CONCURRENT_NUMJOBS=$((NUMJOBS * NUM_REACHABLE))
        echo "Using ${IOPS_CONCURRENT_NUMJOBS} jobs (${NUMJOBS} per server)" >&2
        echo "" >&2
    elif [ ${#IOPS_SHARES[@]} -gt 0 ] && [ "$SEQUENTIAL_ONLY" = false ]; then
        echo "=== Phase 4: Concurrent IOPS Test ===" >&2
        echo "Skipping concurrent IOPS test (need 2+ servers, have $NUM_REACHABLE)" >&2
        echo "" >&2
    fi

    if [ $NUM_REACHABLE -ge 2 ] && [ ${#IOPS_SHARES[@]} -gt 0 ] && [ "$SEQUENTIAL_ONLY" = false ]; then

        # Concurrent random write test
        echo "Running concurrent 4K random write test..." >&2
        fio --name=fiotest \
            --directory="$IOPS_FIO_DIRS" \
            --size=$FILESIZE \
            --rw=randwrite \
            --bs=4k \
            --ioengine=libaio \
            --iodepth=8 \
            --numjobs=$IOPS_CONCURRENT_NUMJOBS \
            --direct=$DIRECT_FLAG \
            --runtime=$RUNTIME \
            --time_based \
            --ramp_time=2 \
            --group_reporting \
            --output-format=json \
            --output="$FIO_TEMP_DIR/concurrent_randwrite.json" 2>&1 | grep -v "^fio-" || true

        CONCURRENT_RANDWRITE_IOPS=$(jq -r '.jobs[0].write.iops' "$FIO_TEMP_DIR/concurrent_randwrite.json" 2>/dev/null || echo "0")
        CONCURRENT_RANDWRITE_LAT=$(jq -r '.jobs[0].write.lat_ns.mean / 1000' "$FIO_TEMP_DIR/concurrent_randwrite.json" 2>/dev/null || echo "0")
        echo "  Concurrent Random Write: ${CONCURRENT_RANDWRITE_IOPS%.*} IOPS @ ${CONCURRENT_RANDWRITE_LAT%.*} µs" >&2

        # Concurrent random read test
        echo "Running concurrent 4K random read test..." >&2
        fio --name=fiotest \
            --directory="$IOPS_FIO_DIRS" \
            --size=$FILESIZE \
            --rw=randread \
            --bs=4k \
            --ioengine=libaio \
            --iodepth=8 \
            --numjobs=$IOPS_CONCURRENT_NUMJOBS \
            --direct=$DIRECT_FLAG \
            --runtime=$RUNTIME \
            --time_based \
            --ramp_time=2 \
            --group_reporting \
            --output-format=json \
            --output="$FIO_TEMP_DIR/concurrent_randread.json" 2>&1 | grep -v "^fio-" || true

        CONCURRENT_RANDREAD_IOPS=$(jq -r '.jobs[0].read.iops' "$FIO_TEMP_DIR/concurrent_randread.json" 2>/dev/null || echo "0")
        CONCURRENT_RANDREAD_LAT=$(jq -r '.jobs[0].read.lat_ns.mean / 1000' "$FIO_TEMP_DIR/concurrent_randread.json" 2>/dev/null || echo "0")
        echo "  Concurrent Random Read: ${CONCURRENT_RANDREAD_IOPS%.*} IOPS @ ${CONCURRENT_RANDREAD_LAT%.*} µs" >&2
        echo "" >&2
    fi

    #######################################
    # Add concurrent results to shares array for JSON output
    #######################################

    # Add concurrent results to shares array (with colon-separated NFS share names)
    CONCURRENT_NFS_SHARE=$(IFS=:; echo "${ALL_SHARES[*]}")

    # Save original share count before adding concurrent entry
    ORIGINAL_NUM_SHARES="${#ALL_SHARES[@]}"

    # Append to ALL_SHARES array for JSON generation
    ALL_SHARES+=("$CONCURRENT_NFS_SHARE")

    SHARE_WRITE_BW+=("$CONCURRENT_WRITE_BW")
    SHARE_READ_BW+=("$CONCURRENT_READ_BW")
    SHARE_WRITE_START+=("$CONCURRENT_WRITE_START")
    SHARE_WRITE_END+=("$CONCURRENT_WRITE_END")
    SHARE_READ_START+=("$CONCURRENT_READ_START")
    SHARE_READ_END+=("$CONCURRENT_READ_END")
    SHARE_RANDWRITE_IOPS+=("$CONCURRENT_RANDWRITE_IOPS")
    SHARE_RANDREAD_IOPS+=("$CONCURRENT_RANDREAD_IOPS")
    SHARE_RANDWRITE_LAT+=("$CONCURRENT_RANDWRITE_LAT")
    SHARE_RANDREAD_LAT+=("$CONCURRENT_RANDREAD_LAT")

    echo "" >&2
    echo "=== Final Results ===" >&2
    echo "  Concurrent Write: ${CONCURRENT_WRITE_BW%.*} MB/s" >&2
    echo "  Concurrent Read: ${CONCURRENT_READ_BW%.*} MB/s" >&2
    if [ "$SEQUENTIAL_ONLY" = false ]; then
        echo "  Concurrent Random Write: ${CONCURRENT_RANDWRITE_IOPS%.*} IOPS" >&2
        echo "  Concurrent Random Read: ${CONCURRENT_RANDREAD_IOPS%.*} IOPS" >&2
    fi

    # Set defaults for latency (not meaningful for aggregate)
    RANDWRITE_LAT="0"
    RANDREAD_LAT="0"

else
    # Single share or ZFS mode - run once with all directories
    echo "Running 1M sequential write test..." >&2
fio --name=fiotest \
    --directory="$FIO_DIRS" \
    --size=$FILESIZE \
    --rw=write \
    --bs=1m \
    --ioengine=psync \
    --iodepth=1 \
    --numjobs=$NUMJOBS \
    --direct=$DIRECT_FLAG \
    --runtime=$RUNTIME \
    --time_based \
    --ramp_time=2 \
    --group_reporting \
    --output-format=json \
    --output="$FIO_TEMP_DIR/1m_seqwrite.json" 2>&1 | grep -v "^fio-" || true

SEQWRITE_BW=$(jq -r '.jobs[0].write.bw / 1024' "$FIO_TEMP_DIR/1m_seqwrite.json" 2>/dev/null || echo "0")
SEQWRITE_END=$(jq -r '.timestamp // 0' "$FIO_TEMP_DIR/1m_seqwrite.json" 2>/dev/null || echo "0")
SEQWRITE_RUNTIME_MS=$(jq -r '.jobs[0].job_runtime // 0' "$FIO_TEMP_DIR/1m_seqwrite.json" 2>/dev/null || echo "0")
SEQWRITE_START=$(echo "$SEQWRITE_END - ($SEQWRITE_RUNTIME_MS / 1000)" | bc 2>/dev/null || echo "0")

echo "  1M Sequential Write: ${SEQWRITE_BW%.*} MB/s" >&2

#######################################
# Test 2: 1M Sequential Read Throughput
# Reuses files from Test 1 (same --name)
#######################################
echo "Running 1M sequential read test..." >&2
fio --name=fiotest \
    --directory="$FIO_DIRS" \
    --size=$FILESIZE \
    --rw=read \
    --bs=1m \
    --ioengine=psync \
    --iodepth=1 \
    --numjobs=$NUMJOBS \
    --direct=$DIRECT_FLAG \
    --runtime=$RUNTIME \
    --time_based \
    --ramp_time=2 \
    --group_reporting \
    --output-format=json \
    --output="$FIO_TEMP_DIR/1m_seqread.json" 2>&1 | grep -v "^fio-" || true

SEQREAD_BW=$(jq -r '.jobs[0].read.bw / 1024' "$FIO_TEMP_DIR/1m_seqread.json" 2>/dev/null || echo "0")
SEQREAD_END=$(jq -r '.timestamp // 0' "$FIO_TEMP_DIR/1m_seqread.json" 2>/dev/null || echo "0")
SEQREAD_RUNTIME_MS=$(jq -r '.jobs[0].job_runtime // 0' "$FIO_TEMP_DIR/1m_seqread.json" 2>/dev/null || echo "0")
SEQREAD_START=$(echo "$SEQREAD_END - ($SEQREAD_RUNTIME_MS / 1000)" | bc 2>/dev/null || echo "0")

echo "  1M Sequential Read: ${SEQREAD_BW%.*} MB/s" >&2

# Initialize random I/O variables (may be skipped)
RANDWRITE_IOPS="0"
RANDWRITE_LAT="0"
RANDREAD_IOPS="0"
RANDREAD_LAT="0"

if [ "$SEQUENTIAL_ONLY" = false ]; then
    #######################################
    # Test 3: 4K Random Write IOPS
    # Reuses files from Test 1 (same --name)
    # Uses libaio + iodepth=8 for optimal queue depth (empirically determined for NFS/ZFS)
    #######################################
    echo "Running 4K random write test..." >&2
    fio --name=fiotest \
        --directory="$FIO_DIRS" \
        --size=$FILESIZE \
        --rw=randwrite \
        --bs=4k \
        --ioengine=libaio \
        --iodepth=8 \
        --numjobs=$NUMJOBS \
        --direct=$DIRECT_FLAG \
        --runtime=$RUNTIME \
        --time_based \
        --ramp_time=2 \
        --group_reporting \
        --output-format=json \
        --output="$FIO_TEMP_DIR/4k_randwrite.json" 2>&1 | grep -v "^fio-" || true

    RANDWRITE_IOPS=$(jq -r '.jobs[0].write.iops' "$FIO_TEMP_DIR/4k_randwrite.json" 2>/dev/null || echo "0")
    RANDWRITE_LAT=$(jq -r '.jobs[0].write.lat_ns.mean / 1000' "$FIO_TEMP_DIR/4k_randwrite.json" 2>/dev/null || echo "0")

    echo "  4K Random Write: ${RANDWRITE_IOPS%.*} IOPS @ ${RANDWRITE_LAT%.*} µs" >&2

    #######################################
    # Test 4: 4K Random Read IOPS
    # Reuses files from Test 1 (same --name)
    # Uses libaio + iodepth=8 for optimal queue depth (empirically determined for NFS/ZFS)
    #######################################
    echo "Running 4K random read test..." >&2
    fio --name=fiotest \
        --directory="$FIO_DIRS" \
        --size=$FILESIZE \
        --rw=randread \
        --bs=4k \
        --ioengine=libaio \
        --iodepth=8 \
        --numjobs=$NUMJOBS \
        --direct=$DIRECT_FLAG \
        --runtime=$RUNTIME \
        --time_based \
        --ramp_time=2 \
        --group_reporting \
        --output-format=json \
        --output="$FIO_TEMP_DIR/4k_randread.json" 2>&1 | grep -v "^fio-" || true

    RANDREAD_IOPS=$(jq -r '.jobs[0].read.iops' "$FIO_TEMP_DIR/4k_randread.json" 2>/dev/null || echo "0")
    RANDREAD_LAT=$(jq -r '.jobs[0].read.lat_ns.mean / 1000' "$FIO_TEMP_DIR/4k_randread.json" 2>/dev/null || echo "0")

    echo "  4K Random Read: ${RANDREAD_IOPS%.*} IOPS @ ${RANDREAD_LAT%.*} µs" >&2
else
    echo "Skipping random I/O tests (--sequential-only)" >&2
fi

    # For single share mode, create arrays for consistency with multi-share code
    SHARE_WRITE_BW=("$SEQWRITE_BW")
    SHARE_READ_BW=("$SEQREAD_BW")
    SHARE_RANDWRITE_IOPS=("$RANDWRITE_IOPS")
    SHARE_RANDREAD_IOPS=("$RANDREAD_IOPS")
    SHARE_RANDWRITE_LAT=("$RANDWRITE_LAT")
    SHARE_RANDREAD_LAT=("$RANDREAD_LAT")
fi

# Note: dstat monitoring stop is handled by the calling script

#######################################
# Cleanup
#######################################
echo "" >&2
echo "Cleaning up..." >&2

if [ "$MOUNTED_BY_SCRIPT" = true ]; then
    # Unmount all NFS mounts
    for MOUNT_POINT in "${MOUNT_POINTS[@]}"; do
        # Remove test directory
        rm -rf "$MOUNT_POINT/fio-test" 2>/dev/null || true
        # Unmount
        if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
            echo "  Unmounting: $MOUNT_POINT" >&2
            umount "$MOUNT_POINT" 2>/dev/null || umount -f "$MOUNT_POINT" 2>/dev/null || true
        fi
    done
else
    # ZFS mode - just remove test directory
    rm -rf "$TEST_DIR" 2>/dev/null || true
fi

#######################################
# Generate JSON output
#######################################
# For NFS mode with multiple shares, create shares array similar to nfs-performance-test.sh
# For single share or ZFS mode, use simplified format
if [ "$MODE" = "nfs" ] && [ ${#ALL_SHARES[@]} -gt 1 ]; then
    # Multi-share format compatible with nfs-performance-test.sh
    # Use per-share results from SHARE arrays
    SHARES_JSON="[]"
    share_idx=0
    for NFS_MOUNT in "${ALL_SHARES[@]}"; do
        SHARE_JSON=$(jq -n \
            --arg share "$NFS_MOUNT" \
            --argjson write "${SHARE_WRITE_BW[$share_idx]:-0}" \
            --argjson read "${SHARE_READ_BW[$share_idx]:-0}" \
            --argjson write_start "${SHARE_WRITE_START[$share_idx]:-0}" \
            --argjson write_end "${SHARE_WRITE_END[$share_idx]:-0}" \
            --argjson read_start "${SHARE_READ_START[$share_idx]:-0}" \
            --argjson read_end "${SHARE_READ_END[$share_idx]:-0}" \
            --argjson randwrite_iops "${SHARE_RANDWRITE_IOPS[$share_idx]:-0}" \
            --argjson randread_iops "${SHARE_RANDREAD_IOPS[$share_idx]:-0}" \
            --argjson randwrite_lat "${SHARE_RANDWRITE_LAT[$share_idx]:-0}" \
            --argjson randread_lat "${SHARE_RANDREAD_LAT[$share_idx]:-0}" \
            '{
                nfs_share: $share,
                sequential_write_mbps: $write,
                sequential_read_mbps: $read,
                write_start_epoch: $write_start,
                write_end_epoch: $write_end,
                read_start_epoch: $read_start,
                read_end_epoch: $read_end,
                randwrite_iops: $randwrite_iops,
                randread_iops: $randread_iops,
                randwrite_latency_us: $randwrite_lat,
                randread_latency_us: $randread_lat
            }')
        SHARES_JSON=$(echo "$SHARES_JSON" | jq --argjson share "$SHARE_JSON" '. + [$share]')
        ((share_idx++))
    done

    # Prepare test_config
    TEST_CONFIG=$(jq -n \
        --arg blocksize "1m" \
        --argjson numjobs "$NUMJOBS" \
        --argjson concurrent_numjobs "${CONCURRENT_NUMJOBS:-0}" \
        --arg filesize "$FILESIZE" \
        --argjson runtime "$RUNTIME" \
        --arg ioengine "psync" \
        --argjson iodepth 1 \
        --argjson direct "$DIRECT_FLAG" \
        --argjson ramp_time 2 \
        '{
            blocksize: $blocksize,
            numjobs: $numjobs,
            concurrent_numjobs: $concurrent_numjobs,
            filesize: $filesize,
            runtime: $runtime,
            ioengine: $ioengine,
            iodepth: $iodepth,
            direct: $direct,
            ramp_time: $ramp_time
        }')

    JSON_OUTPUT=$(jq -n \
        --arg timestamp "$(date -Iseconds)" \
        --arg product "$MOUNT_BASE" \
        --argjson num_shares "$ORIGINAL_NUM_SHARES" \
        --argjson test_config "$TEST_CONFIG" \
        --argjson shares "$SHARES_JSON" \
        '{
            test_mode: "nfs",
            product: $product,
            timestamp: $timestamp,
            num_shares: $num_shares,
            test_config: $test_config,
            shares: $shares
        }')
else
    # Single share or ZFS mode - simplified format
    # Calculate durations from epoch times
    WRITE_DURATION=$((${SEQWRITE_END%.*} - ${SEQWRITE_START%.*}))
    READ_DURATION=$((${SEQREAD_END%.*} - ${SEQREAD_START%.*}))

    JSON_OUTPUT=$(jq -n \
        --arg mode "$MODE" \
        --arg product "$MOUNT_BASE" \
        --arg target "$TARGET" \
        --arg timestamp "$(date -Iseconds)" \
        --arg filesize "$FILESIZE" \
        --argjson randread_iops "${RANDREAD_IOPS%.*}" \
        --argjson randread_lat "${RANDREAD_LAT%.*}" \
        --argjson randwrite_iops "${RANDWRITE_IOPS%.*}" \
        --argjson randwrite_lat "${RANDWRITE_LAT%.*}" \
        --argjson seqread_bw "${SEQREAD_BW%.*}" \
        --argjson seqwrite_bw "${SEQWRITE_BW%.*}" \
        --argjson write_start "${SEQWRITE_START%.*}" \
        --argjson write_end "${SEQWRITE_END%.*}" \
        --argjson read_start "${SEQREAD_START%.*}" \
        --argjson read_end "${SEQREAD_END%.*}" \
        --argjson write_duration "$WRITE_DURATION" \
        --argjson read_duration "$READ_DURATION" \
        '{
            test_mode: $mode,
            product: $product,
            target: $target,
            timestamp: $timestamp,
            file_size_per_job: $filesize,
            sequential_write_mbps: $seqwrite_bw,
            sequential_read_mbps: $seqread_bw,
            write_start_epoch: $write_start,
            write_end_epoch: $write_end,
            read_start_epoch: $read_start,
            read_end_epoch: $read_end,
            write_duration_seconds: $write_duration,
            read_duration_seconds: $read_duration,
            "4k_randread_iops": $randread_iops,
            "4k_randread_latency_us": $randread_lat,
            "4k_randwrite_iops": $randwrite_iops,
            "4k_randwrite_latency_us": $randwrite_lat
        }')
fi

# Output to file or stdout
# Default to nfs_performance_summary.json for both NFS and ZFS modes
if [ -z "$OUTPUT_FILE" ]; then
    OUTPUT_FILE="/tmp/perf-results/nfs_performance_summary.json"
    mkdir -p /tmp/perf-results
    echo "$JSON_OUTPUT" > "$OUTPUT_FILE"
    echo "Results saved to: $OUTPUT_FILE" >&2
    # Also output to stdout for piping
    echo "$JSON_OUTPUT"
else
    echo "$JSON_OUTPUT" > "$OUTPUT_FILE"
    echo "Results saved to: $OUTPUT_FILE" >&2
fi

# Copy fio JSON output files to results directory for reference
if [ -d "$FIO_TEMP_DIR" ] && [ "$(ls -A $FIO_TEMP_DIR/*.json 2>/dev/null)" ]; then
    mkdir -p /tmp/perf-results/fio-json
    cp -f "$FIO_TEMP_DIR"/*.json /tmp/perf-results/fio-json/ 2>/dev/null || true
    echo "Saved fio JSON outputs to: /tmp/perf-results/fio-json/" >&2
fi

echo "" >&2
echo "FSx performance testing completed" >&2
