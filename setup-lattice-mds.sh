#!/bin/bash
# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.
#
# setup-lattice-mds.sh — Configure and bring up a single-node Lattice pNFS
#                        MDS with a co-located single-node RonDB, wired to
#                        EXTERNAL MayaNAS NFS shares as flex-file data
#                        servers (ds[0]/ds[1]).
#
# Runs ON the MDS VM (deploy-pnfs.sh scp's it there and runs it with sudo).
# Data servers = the two MayaNAS active-active VIP/NFS shares (plain NFSv4).
#
# Requires a PREBUILT MDS (the lattice-mds image): RonDB at /opt/rondb, plus
# pnfs-mds, mds-admin and lattice-genconfig in /usr/local/bin. Nothing is fetched,
# cloned or compiled here, so a stock OS image is not a usable substitute.
#
# What it does (per-deployment work only):
#   1. Verify the image prerequisites are actually present
#   2. RonDB config via Lattice's own sizing tool (lattice-genconfig
#      --host-memory) -> proper IndexMemory/TransactionMemory/TotalMemoryConfig;
#      bring up ndb_mgmd + one ndbmtd (NoOfReplicas=1)
#   3. Create RonDB index-stat system tables BEFORE first schema build
#      (else ordered-index scans abort with NDB 4243/4350)
#   4. Write /etc/pnfs-mds/mds.conf (ds[i]=DSi); rondb.conf from genconfig
#   5. NFS-mount each DS on the MDS at /mnt/dsN (v4.2) — fast-path FH capture
#   6. Start pnfs-mds (auto-creates the RonDB schema on first run)
#
set -euo pipefail

# ---- Args ---------------------------------------------------------------
DS=()                  # data servers (flex-file DS). Repeat --ds, e.g.
                       #   --ds VIP1:/pool/share --ds VIP2:/pool/share [--ds ...]
                       # or the back-compat --ds0/--ds1/--ds2/--ds3. Any count >= 1.
MDS_IP=""              # MDS private IP (advertised hostname + RonDB mgmd host)
HOST_MEMORY=""         # RonDB sizing hint for lattice-genconfig; ""=> autodetect host RAM
WORKER_THREADS=""      # defaults to nproc
NFS_PORT="2049"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ds)             DS+=("$2"); shift 2 ;;
    --ds0)            DS[0]="$2"; shift 2 ;;
    --ds1)            DS[1]="$2"; shift 2 ;;
    --ds2)            DS[2]="$2"; shift 2 ;;
    --ds3)            DS[3]="$2"; shift 2 ;;
    --mds-ip)         MDS_IP="$2"; shift 2 ;;
    --host-memory)    HOST_MEMORY="$2"; shift 2 ;;
    # Accepted and ignored: nothing is fetched or built here. Still consumed because
    # callers pass --rondb-url and an unknown arg exits 2.
    --rondb-url|--repo-url|--repo-ref) shift 2 ;;
    --worker-threads) WORKER_THREADS="$2"; shift 2 ;;
    -h|--help)        usage ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[lattice-mds]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

[ ${#DS[@]} -ge 1 ] || fail "need at least one --ds ENDPOINT (e.g. --ds VIP:/pool/share)"
[ -n "$MDS_IP" ] || fail "--mds-ip required (MDS private IP)"

: "${WORKER_THREADS:=$(nproc)}"
SUDO="sudo"; [ "$(id -u)" = "0" ] && SUDO=""

RONDB_LINK="/opt/rondb"
RONDB_DATADIR="/var/lib/rondb"
RONDB_CONFDIR="/etc/rondb"
MDS_CONFDIR="/etc/pnfs-mds"
MDS_RUNDIR="/var/lib/pnfs-mds"
MGM_NODE_ID=65         # lattice-genconfig default ndb_mgmd node id
NDB_NODE_ID=1          # first (only) data node

# ---- 1. Prerequisites (supplied by the prebuilt lattice-mds image) ------
# RonDB and the patched pnfs-mds / mds-admin / lattice-genconfig all come from the
# image. This script only does the per-deployment work: genconfig, RonDB init,
# index-stat, mds.conf, the /mnt/dsN mounts and starting the service.
#
# Checked, not assumed: a missing prerequisite here would otherwise surface much later as
# a genconfig or FH-capture failure. lattice-genconfig is installed as a standalone
# script because it runs on every deploy; the rest of the source tree is not in the image.
for _p in "${RONDB_LINK}/bin/ndb_mgmd" \
          "${RONDB_LINK}/lib/libndbclient.so" \
          /usr/local/bin/pnfs-mds \
          /usr/local/bin/lattice-genconfig; do
  [ -e "$_p" ] || fail "missing $_p -- this MDS did not boot the lattice-mds image.
       Redeploy using that image; this script configures an MDS, it does not build one."
done
ok "prebuilt MDS image detected (RonDB + pnfs-mds + lattice-genconfig)"
[ -x /usr/local/bin/mds-admin ] || warn "mds-admin not installed — 'ds list' will be unavailable"
RONDB_LD="${RONDB_LINK}/lib:${RONDB_LINK}/lib64"

# ---- 2. RonDB config via lattice-genconfig (their sizing tool) ----------
$SUDO mkdir -p "$RONDB_CONFDIR" "$RONDB_DATADIR/data" "$RONDB_DATADIR/mgm" "$MDS_CONFDIR" "$MDS_RUNDIR"
[ -n "$HOST_MEMORY" ] || HOST_MEMORY="$(( $(awk '/MemTotal/{print $2}' /proc/meminfo)/1024/1024 ))G"
CFG=$(mktemp -d)
printf '%s\n' "$MDS_IP" > "$CFG/mds.txt"
for ep in "${DS[@]}"; do echo "${ep%%:*}"; done > "$CFG/ds.txt"
# --worker-threads is REQUIRED in practice: upstream's default is 128 while its own
# validator caps it at 64, so genconfig cannot run with default args (introduced in
# 4521b4b, PR #76). We already compute the value; it also sizes RonDB's [api] pool.
log "Generating RonDB config via lattice-genconfig (--host-memory $HOST_MEMORY, --worker-threads $WORKER_THREADS)…"
lattice-genconfig --mds-file "$CFG/mds.txt" --ds-file "$CFG/ds.txt" \
     --host-memory "$HOST_MEMORY" --worker-threads "$WORKER_THREADS" \
     --out "$CFG/out" --force 2>&1 | tee "$CFG/genconfig.log" \
     || fail "lattice-genconfig failed -- see output above and $CFG/genconfig.log"
[ -f "$CFG/out/config.ini" ] || fail "lattice-genconfig produced no config.ini"
$SUDO cp "$CFG/out/config.ini" "$RONDB_CONFDIR/config.ini"
$SUDO cp "$CFG/out/rondb.conf" "$MDS_CONFDIR/rondb.conf"
CONNECT=$(awk -F'=' '/connect_string/{gsub(/[ \r]/,"",$2);print $2}' "$CFG/out/rondb.conf"); : "${CONNECT:=${MDS_IP}:1186}"
ok "RonDB config from lattice-genconfig (connect=$CONNECT)"
grep -E 'IndexMemory|TransactionMemory|TotalMemoryConfig|SharedGlobalMemory' "$RONDB_CONFDIR/config.ini" | sed 's/^/    /'

# bring up ndb_mgmd + ndbmtd (idempotent; --initial only when fs empty)
if ! pgrep -x ndb_mgmd >/dev/null; then
  log "Starting ndb_mgmd…"
  $SUDO "${RONDB_LINK}/bin/ndb_mgmd" --config-file="$RONDB_CONFDIR/config.ini" \
       --configdir="$RONDB_DATADIR/mgm" --ndb-nodeid=$MGM_NODE_ID --initial
  sleep 3
fi
if ! pgrep -x ndbmtd >/dev/null; then
  INIT_FLAG=""; [ -z "$(ls -A "$RONDB_DATADIR/data" 2>/dev/null)" ] && INIT_FLAG="--initial"
  log "Starting ndbmtd $INIT_FLAG …"
  $SUDO "${RONDB_LINK}/bin/ndbmtd" --ndb-connectstring="$CONNECT" --ndb-nodeid=$NDB_NODE_ID $INIT_FLAG
fi
log "Waiting for RonDB to reach STARTED…"
# ndb_waiter is authoritative (exits 0 when all nodes reach STARTED). Fallback:
# `ndb_mgm -e show` shows a started node as "id=N @IP (RonDB-…, Nodegroup: G, *)"
# — there is NO literal "started" in show output; "Nodegroup:" is the signal.
if "${RONDB_LINK}/bin/ndb_waiter" --ndb-connectstring="$CONNECT" --timeout=180 >/dev/null 2>&1; then
  ok "RonDB data node started"
elif "${RONDB_LINK}/bin/ndb_mgm" -c "$CONNECT" -e show 2>/dev/null | grep -qE "id=${NDB_NODE_ID}[[:space:]]+@.*Nodegroup:"; then
  ok "RonDB data node started"
else
  fail "RonDB data node did not start — check $RONDB_DATADIR/data/ndb_${NDB_NODE_ID}_out.log"
fi

# ---- 3. index-stat system tables (MUST precede first schema build) -----
# Ordered indexes come up degraded ("without stats", NDB 4714) if these are
# absent, then scans abort (4350). Create BEFORE the first pnfs-mds start.
log "Creating RonDB index-stat system tables…"
LD_LIBRARY_PATH="$RONDB_LD" $SUDO "${RONDB_LINK}/bin/ndb_index_stat" \
    --ndb-connectstring="$CONNECT" --sys-create-if-not-exist >/dev/null 2>&1 \
    && ok "index-stat tables ready" || warn "ndb_index_stat sys-create returned nonzero (continuing)"

# ---- 4. MDS config (rondb.conf already copied from genconfig) -----------
log "Writing $MDS_CONFDIR/mds.conf…"
$SUDO tee "$MDS_CONFDIR/mds.conf" >/dev/null <<EOF
mds_id = 1
hostname = $MDS_IP
nfs_port = $NFS_PORT
worker_threads = $WORKER_THREADS
catalogue_backend = rondb
catalogue_backend_conf = $MDS_CONFDIR/rondb.conf
inline_enabled = false
grace_period_sec = 0
inode_cache_size = 32768

# Data servers = the two MayaNAS active-active VIP/NFS shares (flex-files DS).
ds_count = ${#DS[@]}
$(for i in "${!DS[@]}"; do echo "ds[$i] = ${DS[$i]}"; done)
EOF

# ---- 5. Mount each DS on the MDS at /mnt/dsN (fast-path FH capture) -----
# pnfs-mds captures the stripe-file handle via name_to_handle_at() on a LOCAL
# NFS mount of each DS (ds_mount_fmt=/mnt/ds%u). Without these mounts the fast
# path is skipped. Mount v4.2 + persist via fstab (survives reboot).
mount_ds() {
  local ep="$2" mp="/mnt/ds$1"; local host="${ep%%:*}" path="${ep#*:}"; local want="$host:$path"
  # Inspect and detach before mkdir. If this MDS previously served data servers that no
  # longer exist, the old mount is stale and every stat() on the path returns ESTALE, so
  # mkdir -p itself fails and set -e ends the script before the detach below could run.
  # findmnt reads /proc/mounts and never stats the path, so it is safe on a stale mount,
  # and umount -l works even when the mount is hung.
  # Detach when the source is a different endpoint, or the same endpoint gone stale.
  local cur; cur=$(findmnt -n -o SOURCE "$mp" 2>/dev/null || true)
  if [ -n "$cur" ] && { [ "$cur" != "$want" ] || ! stat "$mp" >/dev/null 2>&1; }; then
    warn "detaching stale/foreign mount at $mp (was $cur)"
    $SUDO umount -l "$mp" 2>/dev/null || true; sleep 1; cur=""
  fi
  $SUDO mkdir -p "$mp"
  if [ -z "$cur" ]; then
    timeout 25 $SUDO mount -t nfs4 -o vers=4.2,sec=sys "$want" "$mp" \
      || { warn "mount $ep -> $mp failed"; MOUNT_FAIL=1; }
  fi
  # fstab: replace any existing line for this mount point with the correct endpoint
  $SUDO sed -i "\| $mp |d" /etc/fstab
  echo "$want $mp nfs4 _netdev,vers=4.2,sec=sys 0 0" | $SUDO tee -a /etc/fstab >/dev/null
}
MOUNT_FAIL=0
for i in "${!DS[@]}"; do mount_ds "$i" "${DS[$i]}"; done
# An MDS that cannot mount its data servers is not degraded, it is useless: pnfs-mds
# would start, serve layouts for data servers it cannot reach, and the client would
# see NFS4ERR_NOSPC ("No space left on device") minutes later with nothing pointing
# back here. Fail at the mount, where the cause is still visible.
[ "$MOUNT_FAIL" -eq 0 ] || fail "could not mount the data servers -- check that the \
cluster has finished setup (VIPs up, pools imported, shares exported) and that the MDS \
can reach the VIPs on 2049"
ok "DS mounted at $(printf '/mnt/ds%s ' "${!DS[@]}" | sed 's/ $//; s/ /, /g')"

# ---- 6. Start pnfs-mds (systemd unit; After remote-fs for the DS mounts) -
log "Installing + starting pnfs-mds service…"
$SUDO tee /etc/systemd/system/pnfs-mds.service >/dev/null <<EOF
[Unit]
Description=Lattice pNFS Metadata Server
After=network-online.target remote-fs.target
Wants=network-online.target

[Service]
Type=simple
Environment=LD_LIBRARY_PATH=$RONDB_LD
ExecStart=/usr/local/bin/pnfs-mds $MDS_CONFDIR/mds.conf
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now pnfs-mds

sleep 4
if $SUDO systemctl is-active --quiet pnfs-mds; then
  ok "pnfs-mds is running (schema auto-created on first start)"
else
  warn "pnfs-mds not active — logs:"
  $SUDO journalctl -u pnfs-mds --no-pager -n 40 || true
  fail "pnfs-mds failed to start"
fi

echo
ok "MDS ready. Mount from a pNFS client with:"
echo "    sudo mount -t nfs4 -o vers=4.2,sec=sys,nconnect=8 ${MDS_IP}:/ /mnt/pnfs"
for i in "${!DS[@]}"; do echo "  ds[$i] = ${DS[$i]}"; done
