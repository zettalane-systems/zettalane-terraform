#!/bin/bash

# MayaNAS NFS Client Performance Test
# Runs on client VM to test NFS share performance
# Tests sequential 1M throughput with high-performance mount options

set -e

# Configuration
RESULTS_DIR="/tmp/perf-results"
TEST_NUMJOBS=10
RUNTIME=180  # 3 minutes per test (like FSX test)
DROP_CACHES=false  # Set to true to drop caches between tests (slower but more accurate)

# Parse arguments - list of NFS shares to test
if [ $# -eq 0 ]; then
    echo "Usage: $0 [--runtime SECONDS] [--drop-caches] <nfs_share1> [<nfs_share2> ...]"
    echo "Example: $0 --runtime 180 \"10.100.0.5:/pool/share1\" \"10.100.0.6:/pool/share2\""
    echo "Options:"
    echo "  --runtime SECONDS    Test duration per phase (default: 180)"
    echo "  --drop-caches        Drop server cache between tests (default: false)"
    exit 1
fi

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --runtime)
            RUNTIME="$2"
            shift 2
            ;;
        --drop-caches)
            DROP_CACHES=true
            shift
            ;;
        *)
            break
            ;;
    esac
done

NFS_SHARES=("$@")

echo "=========================================="
echo "MayaNAS NFS Performance Test"
echo "Testing ${#NFS_SHARES[@]} NFS share(s)"
echo "=========================================="

# Install required packages if not available
if ! command -v fio >/dev/null 2>&1; then
    apt-get update -q >/dev/null 2>&1
    apt-get install -y fio >/dev/null 2>&1
fi

if ! command -v jq >/dev/null 2>&1; then
    apt-get install -y jq >/dev/null 2>&1
fi

if ! command -v nfs-common >/dev/null 2>&1; then
    apt-get install -y nfs-common >/dev/null 2>&1
fi

# Install dstat for system monitoring
if ! command -v dstat >/dev/null 2>&1; then
    apt-get install -y dstat >/dev/null 2>&1
fi

# Apply NFS client performance tuning
sysctl -w net.core.rmem_default=262144 >/dev/null 2>&1
sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1
sysctl -w net.core.wmem_default=262144 >/dev/null 2>&1
sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1

# Function to wait for CPU to be idle before starting tests
wait_for_idle_cpu() {
    local phase="$1"
    local max_wait=60
    local elapsed=0

    echo "$(date): Waiting for CPU to be idle before $phase test..."

    while [ $elapsed -lt $max_wait ]; do
        # Get CPU idle percentage
        if command -v mpstat >/dev/null 2>&1; then
            cpu_idle=$(mpstat 1 1 | awk '/Average/ {print $NF}' | sed 's/%//')
        else
            cpu_idle=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | sed 's/%id,//')
        fi

        # Convert to integer for comparison
        cpu_idle_int=${cpu_idle%.*}
        if [ -n "$cpu_idle_int" ] && [ "$cpu_idle_int" -gt 90 ]; then
            echo "$(date): CPU idle (${cpu_idle}% idle), starting $phase test"
            return 0
        fi

        # CPU is busy, show top processes
        if [ $elapsed -eq 0 ]; then
            echo "$(date): CPU busy (${cpu_idle}% idle), top 5 CPU consumers:"
            ps aux --sort=-%cpu | head -6
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "$(date): WARNING - CPU still busy after ${max_wait}s (${cpu_idle}% idle), proceeding anyway"
    echo "$(date): Top 5 CPU consumers:"
    ps aux --sort=-%cpu | head -6
    return 1
}

# Create results directory
mkdir -p "$RESULTS_DIR"
SUMMARY_FILE="$RESULTS_DIR/nfs_performance_summary.json"

# Initialize summary JSON
cat > "$SUMMARY_FILE" << EOF
{
  "timestamp": "$(date -Iseconds)",
  "test_type": "nfs_client",
  "num_shares": ${#NFS_SHARES[@]},
  "shares": []
}
EOF
chmod 644 "$SUMMARY_FILE"

# Clean up any stale mounts from previous interrupted runs
for i in {1..10}; do
    STALE_MOUNT="/mnt/nfs-test-$i"
    if mountpoint -q "$STALE_MOUNT" 2>/dev/null; then
        umount "$STALE_MOUNT" 2>/dev/null || umount -f "$STALE_MOUNT" 2>/dev/null || true
    fi
done

# Mount all NFS shares first
echo "Mounting NFS shares..."
MOUNT_POINTS=()
SHARE_INDEX=0
for NFS_SHARE in "${NFS_SHARES[@]}"; do
    SHARE_INDEX=$((SHARE_INDEX + 1))
    MOUNT_POINT="/mnt/nfs-test-$SHARE_INDEX"
    MOUNT_POINTS+=("$MOUNT_POINT")

    mkdir -p "$MOUNT_POINT"

    if mount -t nfs4 -o rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,actimeo=0,nocto,nconnect=16 "$NFS_SHARE" "$MOUNT_POINT" 2>/dev/null; then
        echo "  ✓ Mounted: $NFS_SHARE -> $MOUNT_POINT"
    else
        echo "  ✗ Failed: $NFS_SHARE"
    fi
done
echo ""

# Test each NFS share individually
SHARE_INDEX=0
for NFS_SHARE in "${NFS_SHARES[@]}"; do
    SHARE_INDEX=$((SHARE_INDEX + 1))
    MOUNT_POINT="${MOUNT_POINTS[$((SHARE_INDEX - 1))]}"

    # Skip if mount failed
    if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        continue
    fi

    echo "=========================================="
    echo "Individual Test: NFS Share $SHARE_INDEX/${#NFS_SHARES[@]}"
    echo "$NFS_SHARE"
    echo "=========================================="

    # Test configuration
    TEST_DIR="$MOUNT_POINT/fio-test"
    mkdir -p "$TEST_DIR"

    # Run tests for different file sizes and I/O modes (buffered vs direct)
    SHARE_RESULTS="[]"
    for IO_MODE in "direct"; do
        DIRECT_FLAG="--direct=1"
        FSYNC_FLAGS=""
        IO_ENGINE="psync"
        IO_DEPTH="1"
        IO_DESC="Direct I/O (no cache, sequential)"

        echo ""
        echo "=========================================="
        echo "I/O Mode: $IO_DESC"
        echo "=========================================="

    for TEST_FILE_SIZE in 2G 4G 6G; do
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        TEST_START_TIME=$(date +%s)

        # Calculate total aggregate size
        TOTAL_SIZE_BYTES=$(echo "$TEST_FILE_SIZE" | sed 's/G//')
        TOTAL_SIZE_BYTES=$((TOTAL_SIZE_BYTES * TEST_NUMJOBS))
        TOTAL_AGGREGATE_SIZE="${TOTAL_SIZE_BYTES}G"

        # Clean up old test files
        rm -rf "$TEST_DIR"/seqtest* 2>/dev/null || true

        echo ""
        echo "Testing: ${NFS_SHARE} - ${TOTAL_AGGREGATE_SIZE} (${IO_MODE})"
        echo "  Write test (${TEST_NUMJOBS} jobs × ${TEST_FILE_SIZE})..."

        if [ "$DROP_CACHES" = "true" ]; then
            if ssh -i /home/ubuntu/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 mayanas@${SERVER_IP} "sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'" 2>/dev/null; then
                echo "  ✓ Server cache dropped before Write"
            fi
        fi

        # Wait for idle CPU before write test
        wait_for_idle_cpu "write" >/dev/null 2>&1

        # Sequential write test with dstat monitoring
        DSTAT_WRITE_FILE="$RESULTS_DIR/dstat_write_${IO_MODE}_${TEST_FILE_SIZE}_share${SHARE_INDEX}.csv"

        dstat -cdnm --output "$DSTAT_WRITE_FILE" 5 >/dev/null 2>&1 &
        DSTAT_PID=$!

        WRITE_START=$(date +%s)
        WRITE_OUTPUT=$(fio \
            --name=seqtest \
            --directory="$TEST_DIR" \
            --size="$TEST_FILE_SIZE" \
            --numjobs="$TEST_NUMJOBS" \
            --bs=1M \
            --ioengine=$IO_ENGINE \
            --iodepth=$IO_DEPTH \
            $DIRECT_FLAG \
            $FSYNC_FLAGS \
            --fallocate=none \
            --overwrite=0 \
            --rw=write \
            --group_reporting \
            --output-format=json 2>&1)
        WRITE_END=$(date +%s)
        WRITE_DURATION=$((WRITE_END - WRITE_START))

        kill $DSTAT_PID 2>/dev/null || true
        wait $DSTAT_PID 2>/dev/null || true

        WRITE_MBPS=$(echo "$WRITE_OUTPUT" | jq -r '.jobs[0].write.bw / 1024' 2>/dev/null || echo "0")
        if [ "$WRITE_MBPS" = "null" ] || [ -z "$WRITE_MBPS" ]; then
            WRITE_MBPS=0
        fi
        printf "    Write: %d MB/s (%ds)\n" "$(printf "%.0f" "$WRITE_MBPS")" "$WRITE_DURATION"

        # Extract server IP from NFS share (format: "IP:/path")
        SERVER_IP=$(echo "$NFS_SHARE" | cut -d':' -f1)

        # Drop cache on server via SSH before read test (only if enabled)
        if [ "$DROP_CACHES" = "true" ]; then
            echo "  Dropping cache on server ${SERVER_IP}..."
            if ssh -i /home/ubuntu/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 mayanas@${SERVER_IP} "sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'" 2>/dev/null; then
                echo "  ✓ Server cache dropped before Read"
            else
                echo "  ✗ Failed to drop server cache"
            fi
        fi

        echo "  Read test (${TEST_NUMJOBS} jobs × ${TEST_FILE_SIZE})..."

        # Wait for idle CPU before read test
        wait_for_idle_cpu "read" >/dev/null 2>&1

        # Sequential read test with dstat monitoring
        DSTAT_READ_FILE="$RESULTS_DIR/dstat_read_${IO_MODE}_${TEST_FILE_SIZE}_share${SHARE_INDEX}.csv"

        dstat -cdnm --output "$DSTAT_READ_FILE" 5 >/dev/null 2>&1 &
        DSTAT_PID=$!

        READ_START=$(date +%s)
        READ_OUTPUT=$(fio \
            --name=seqtest \
            --directory="$TEST_DIR" \
            --size="$TEST_FILE_SIZE" \
            --numjobs="$TEST_NUMJOBS" \
            --bs=1M \
            --ioengine=$IO_ENGINE \
            --iodepth=$IO_DEPTH \
            $DIRECT_FLAG \
            --rw=read \
            --group_reporting \
            --output-format=json 2>&1)
        READ_END=$(date +%s)
        READ_DURATION=$((READ_END - READ_START))

        kill $DSTAT_PID 2>/dev/null || true
        wait $DSTAT_PID 2>/dev/null || true

        READ_MBPS=$(echo "$READ_OUTPUT" | jq -r '.jobs[0].read.bw / 1024' 2>/dev/null || echo "0")
        if [ "$READ_MBPS" = "null" ] || [ -z "$READ_MBPS" ]; then
            READ_MBPS=0
        fi
        printf "    Read:  %d MB/s (%ds)\n" "$(printf "%.0f" "$READ_MBPS")" "$READ_DURATION"

        TOTAL_DURATION=$((WRITE_DURATION + READ_DURATION))

        # Append test result to share results
        TEST_RESULT=$(jq -n \
            --arg ts "$TIMESTAMP" \
            --arg share "$NFS_SHARE" \
            --arg size "$TEST_FILE_SIZE" \
            --arg total_size "$TOTAL_AGGREGATE_SIZE" \
            --arg io_mode "$IO_MODE" \
            --argjson jobs "$TEST_NUMJOBS" \
            --argjson write_mbps "$WRITE_MBPS" \
            --argjson read_mbps "$READ_MBPS" \
            --argjson write_dur "$WRITE_DURATION" \
            --argjson read_dur "$READ_DURATION" \
            --argjson total_dur "$TOTAL_DURATION" \
            '{
                timestamp: $ts,
                nfs_share: $share,
                test_file_size: $size,
                total_aggregate_size: $total_size,
                io_mode: $io_mode,
                num_jobs: $jobs,
                sequential_write_mbps: $write_mbps,
                sequential_read_mbps: $read_mbps,
                write_duration_seconds: $write_dur,
                read_duration_seconds: $read_dur,
                total_duration_seconds: $total_dur
            }')

        SHARE_RESULTS=$(echo "$SHARE_RESULTS" | jq --argjson result "$TEST_RESULT" '. + [$result]')

        # Clean up test files
        rm -f "$TEST_DIR/seqtest*"
    done
    done  # End IO_MODE loop

    # Calculate aggregate stats for this share
    AVG_WRITE=$(echo "$SHARE_RESULTS" | jq '[.[].sequential_write_mbps] | add / length')
    AVG_READ=$(echo "$SHARE_RESULTS" | jq '[.[].sequential_read_mbps] | add / length')

    # Add share results to summary
    SHARE_SUMMARY=$(jq -n \
        --arg share "$NFS_SHARE" \
        --argjson avg_write "$AVG_WRITE" \
        --argjson avg_read "$AVG_READ" \
        --argjson tests "$SHARE_RESULTS" \
        '{
            nfs_share: $share,
            average_write_mbps: $avg_write,
            average_read_mbps: $avg_read,
            tests: $tests
        }')

    # Update summary file
    TMP_FILE=$(mktemp)
    jq --argjson share "$SHARE_SUMMARY" '.shares += [$share]' "$SUMMARY_FILE" > "$TMP_FILE"
    mv "$TMP_FILE" "$SUMMARY_FILE"
    chmod 644 "$SUMMARY_FILE"
done

# Parallel Active-Active Test (if multiple shares)
if [ ${#NFS_SHARES[@]} -gt 1 ]; then
    echo ""
    echo "=========================================="
    echo "Parallel Active-Active Test"
    echo "Testing all ${#NFS_SHARES[@]} shares simultaneously"
    echo "=========================================="

    # Build directory list for FIO (colon-separated)
    FIO_DIRS=""
    for MOUNT_POINT in "${MOUNT_POINTS[@]}"; do
        if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
            TEST_DIR="$MOUNT_POINT/fio-test-parallel"
            mkdir -p "$TEST_DIR"
            if [ -z "$FIO_DIRS" ]; then
                FIO_DIRS="$TEST_DIR"
            else
                FIO_DIRS="${FIO_DIRS}:${TEST_DIR}"
            fi
        fi
    done

    # Run parallel tests for each I/O mode
    PARALLEL_RESULTS="[]"
    DIRECT_FLAG="--direct=1"
    FSYNC_FLAGS=""
    IO_ENGINE="psync"
    IO_DEPTH="1"
    IO_DESC="Direct I/O (no cache, sequential)"

        echo ""
        echo "=========================================="
        echo "I/O Mode: $IO_DESC"
        echo "=========================================="

        for TEST_FILE_SIZE in 2G 4G 6G; do
            TIMESTAMP=$(date +%Y%m%d_%H%M%S)

            # Calculate total aggregate size across all shares
            SIZE_NUM=$(echo "$TEST_FILE_SIZE" | sed 's/G//')
            TOTAL_SIZE_GB=$((SIZE_NUM * TEST_NUMJOBS * ${#MOUNT_POINTS[@]}))
            TOTAL_AGGREGATE_SIZE="${TOTAL_SIZE_GB}G"

            # Clean up old parallel test files
            for MOUNT_POINT in "${MOUNT_POINTS[@]}"; do
                rm -rf "$MOUNT_POINT/fio-test-parallel"/* 2>/dev/null || true
            done

            sync
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

            echo ""
            echo "Testing: All shares parallel - ${TOTAL_AGGREGATE_SIZE} (${IO_MODE})"
            echo "  Write test (${TEST_NUMJOBS} jobs × ${TEST_FILE_SIZE} × ${#MOUNT_POINTS[@]} shares)..."

            wait_for_idle_cpu "write" >/dev/null 2>&1

            # Parallel write test
            WRITE_START=$(date +%s)
            WRITE_OUTPUT=$(fio \
                --name=parallel_write \
                --directory="$FIO_DIRS" \
                --size="$TEST_FILE_SIZE" \
                --numjobs="$TEST_NUMJOBS" \
                --bs=1M \
                --ioengine=$IO_ENGINE \
                --iodepth=$IO_DEPTH \
                $DIRECT_FLAG \
                $FSYNC_FLAGS \
                --fallocate=none \
                --overwrite=0 \
                --rw=write \
                --group_reporting \
                --output-format=json 2>&1)
            WRITE_END=$(date +%s)
            WRITE_DURATION=$((WRITE_END - WRITE_START))

            WRITE_MBPS=$(echo "$WRITE_OUTPUT" | jq -r '.jobs[0].write.bw / 1024' 2>/dev/null || echo "0")
            if [ "$WRITE_MBPS" = "null" ] || [ -z "$WRITE_MBPS" ]; then
                WRITE_MBPS=0
            fi
            printf "    Write: %d MB/s (%ds)\n" "$(printf "%.0f" "$WRITE_MBPS")" "$WRITE_DURATION"

            sync
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

            echo "  Read test (${TEST_NUMJOBS} jobs × ${TEST_FILE_SIZE} × ${#MOUNT_POINTS[@]} shares)..."

            wait_for_idle_cpu "read" >/dev/null 2>&1

            # Parallel read test
            READ_START=$(date +%s)
            READ_OUTPUT=$(fio \
                --name=parallel_read \
                --directory="$FIO_DIRS" \
                --size="$TEST_FILE_SIZE" \
                --numjobs="$TEST_NUMJOBS" \
                --bs=1M \
                --ioengine=$IO_ENGINE \
                --iodepth=$IO_DEPTH \
                $DIRECT_FLAG \
                --rw=read \
                --group_reporting \
                --output-format=json 2>&1)
            READ_END=$(date +%s)
            READ_DURATION=$((READ_END - READ_START))

            READ_MBPS=$(echo "$READ_OUTPUT" | jq -r '.jobs[0].read.bw / 1024' 2>/dev/null || echo "0")
            if [ "$READ_MBPS" = "null" ] || [ -z "$READ_MBPS" ]; then
                READ_MBPS=0
            fi
            printf "    Read:  %d MB/s (%ds)\n" "$(printf "%.0f" "$READ_MBPS")" "$READ_DURATION"

            TOTAL_DURATION=$((WRITE_DURATION + READ_DURATION))

            # Append parallel test result
            TEST_RESULT=$(jq -n \
                --arg ts "$TIMESTAMP" \
                --arg size "$TEST_FILE_SIZE" \
                --arg total_size "$TOTAL_AGGREGATE_SIZE" \
                --arg io_mode "$IO_MODE" \
                --argjson num_shares "${#NFS_SHARES[@]}" \
                --argjson jobs "$TEST_NUMJOBS" \
                --argjson write_mbps "$WRITE_MBPS" \
                --argjson read_mbps "$READ_MBPS" \
                --argjson write_dur "$WRITE_DURATION" \
                --argjson read_dur "$READ_DURATION" \
                --argjson total_dur "$TOTAL_DURATION" \
                '{
                    timestamp: $ts,
                    test_file_size: $size,
                    total_aggregate_size: $total_size,
                    io_mode: $io_mode,
                    num_shares: $num_shares,
                    num_jobs: $jobs,
                    sequential_write_mbps: $write_mbps,
                    sequential_read_mbps: $read_mbps,
                    write_duration_seconds: $write_dur,
                    read_duration_seconds: $read_dur,
                    total_duration_seconds: $total_dur
                }')

            PARALLEL_RESULTS=$(echo "$PARALLEL_RESULTS" | jq --argjson result "$TEST_RESULT" '. + [$result]')
    done

    # Add parallel results to summary
    TMP_FILE=$(mktemp)
    jq --argjson parallel "$PARALLEL_RESULTS" '. + {parallel_test: $parallel}' "$SUMMARY_FILE" > "$TMP_FILE"
    mv "$TMP_FILE" "$SUMMARY_FILE"
    chmod 644 "$SUMMARY_FILE"
fi

# Unmount all shares
echo ""
echo "Unmounting NFS shares..."
for MOUNT_POINT in "${MOUNT_POINTS[@]}"; do
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null
        rmdir "$MOUNT_POINT" 2>/dev/null
    fi
done

echo ""
# Calculate overall aggregate statistics
TMP_FILE=$(mktemp)
jq '. + {
    aggregate_write_mbps: ([.shares[].average_write_mbps] | add / length),
    aggregate_read_mbps: ([.shares[].average_read_mbps] | add / length)
}' "$SUMMARY_FILE" > "$TMP_FILE"
mv "$TMP_FILE" "$SUMMARY_FILE"
chmod 644 "$SUMMARY_FILE"

# Ensure all result files are readable for scp by non-root user
chmod -R 644 "$RESULTS_DIR"/*.{json,csv} 2>/dev/null || true
chmod 755 "$RESULTS_DIR"

echo "=========================================="
echo "NFS Performance Testing Complete"
echo "=========================================="

# Display summary
NUM_SHARES=$(jq -r '.num_shares' "$SUMMARY_FILE")
AGG_WRITE=$(jq -r '.aggregate_write_mbps // 0 | floor' "$SUMMARY_FILE")
AGG_READ=$(jq -r '.aggregate_read_mbps // 0 | floor' "$SUMMARY_FILE")

echo "Shares tested: $NUM_SHARES"
echo ""
echo "Individual Share Results (average across all tests):"
jq -r '.shares[] | "  \(.nfs_share):\n    Average Write: \(.average_write_mbps | floor) MB/s\n    Average Read:  \(.average_read_mbps | floor) MB/s"' "$SUMMARY_FILE"

# Display parallel test results if available
if jq -e '.parallel_test' "$SUMMARY_FILE" >/dev/null 2>&1; then
    echo ""
    echo "Parallel Active-Active Results (all shares simultaneously):"

    # Get direct I/O results from parallel test (most important)
    PARALLEL_DIRECT_WRITE=$(jq -r '[.parallel_test[] | select(.io_mode == "direct")] | map(.sequential_write_mbps) | add / length | floor' "$SUMMARY_FILE" 2>/dev/null || echo "0")
    PARALLEL_DIRECT_READ=$(jq -r '[.parallel_test[] | select(.io_mode == "direct")] | map(.sequential_read_mbps) | add / length | floor' "$SUMMARY_FILE" 2>/dev/null || echo "0")

    if [ "$PARALLEL_DIRECT_WRITE" != "0" ] && [ "$PARALLEL_DIRECT_READ" != "0" ]; then
        echo "  Direct I/O (true wire speed):"
        echo "    Aggregate Write: ${PARALLEL_DIRECT_WRITE} MB/s"
        echo "    Aggregate Read:  ${PARALLEL_DIRECT_READ} MB/s"
    fi
fi

echo ""
echo "Results: $SUMMARY_FILE"

exit 0
