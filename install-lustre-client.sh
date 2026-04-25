#!/bin/bash
# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

#
# install-lustre-client.sh — install Lustre 2.17 client on any modern Linux.
#
# Uses Whamcloud's downloads.whamcloud.com package repositories. On RHEL
# family (Rocky/RHEL/Alma 9 or 10), installs the DKMS variant so modules
# are rebuilt for whatever kernel is running — including future kernel
# upgrades. On Ubuntu, uses lustre-source + module-assistant to build
# modules for the running kernel.
#
# After this script completes you can:
#     sudo modprobe lustre
#     sudo mount -t lustre <MGS>@tcp:/<fsname> /mnt/lustre
#
# Run as root (sudo).
#
set -euo pipefail

log() { echo "[install-lustre-client] $*"; }
fail() { echo "[install-lustre-client] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Must run as root (sudo)"

. /etc/os-release

# Lustre 2.17 everywhere — matches the server version, and the source tarball
# is userspace-agnostic. For Ubuntu we always pull Whamcloud's ubuntu2404 debs
# because the SOURCE in that .deb builds against any Ubuntu kernel in the 6.x
# series (including 22.04's HWE 6.8 kernel).
LUSTRE_VERSION="2.17.0"
BASE_URL="https://downloads.whamcloud.com/public/lustre/lustre-${LUSTRE_VERSION}"

case "$ID-$VERSION_ID" in
    rocky-10*|rhel-10*|almalinux-10*|centos-10*)
        REPO=el10.1
        PKG_MGR=dnf
        ;;
    rocky-9*|rhel-9*|almalinux-9*|centos-9*)
        REPO=el9.7
        PKG_MGR=dnf
        ;;
    ubuntu-22.04|ubuntu-24.04)
        # Source tarball from ubuntu2404/ client debs — builds on any Ubuntu
        # userspace. Works against running kernel (6.8 HWE on 22.04,
        # 6.17 HWE on 24.04). The Whamcloud source tree is kernel-version-agnostic.
        REPO=ubuntu2404
        PKG_MGR=apt
        ;;
    sles-15.7|sles-15-sp7)
        REPO=sles15sp7
        PKG_MGR=zypper
        ;;
    *)
        fail "Unsupported OS: $ID $VERSION_ID (supported: Rocky/RHEL/Alma/CentOS 9/10, Ubuntu 22.04/24.04, SLES 15 SP7)"
        ;;
esac

log "Detected: $ID $VERSION_ID → Whamcloud repo: $REPO"

case "$PKG_MGR" in

    dnf)
        cat > /etc/yum.repos.d/lustre-client.repo <<EOF
[lustre-client]
name=Lustre ${LUSTRE_VERSION} Client (Whamcloud)
baseurl=${BASE_URL}/${REPO}/client/
gpgcheck=0
enabled=1
EOF
        # DKMS build deps (libyaml-devel etc.) live in CRB / powertools — enable it.
        dnf install -y dnf-plugins-core 2>&1 | tail -5 || true
        dnf config-manager --set-enabled crb        2>/dev/null \
            || dnf config-manager --set-enabled powertools 2>/dev/null \
            || log "WARN: could not enable CRB/powertools — libyaml-devel may fail"
        log "Installing epel-release"
        dnf install -y epel-release                    || fail "epel-release install failed"
        log "Installing kernel-devel + build deps for $(uname -r)"
        dnf install -y "kernel-devel-$(uname -r)" kernel-headers libyaml-devel \
                       gcc make dkms elfutils-libelf-devel \
            || log "WARN: some DKMS build deps missing; install may still succeed"
        log "Installing lustre-client-dkms + userspace tools"
        dnf install -y lustre-client-dkms lustre-client
        ;;

    apt)
        # Do NOT use apt install for the lustre-client-utils binary .deb — its
        # userspace binaries require GLIBC 2.38 (Ubuntu 24.04+) and will fail on
        # older Ubuntu. Instead, unpack the source .deb with dpkg -x and build
        # userspace + kernel modules from source. Works on Ubuntu 22.04 and 24.04.
        log "Installing build deps for Lustre 2.17 source build on kernel $(uname -r)"
        apt-get update -qq
        apt-get install -y --no-install-recommends \
            linux-headers-$(uname -r) build-essential gcc-12 \
            flex bison pkg-config zlib1g-dev libssl-dev \
            libmount-dev libyaml-dev libnl-3-dev libnl-genl-3-dev libkeyutils-dev \
            wget ca-certificates \
            || fail "apt install of build deps failed"

        log "Downloading Whamcloud lustre-source_${LUSTRE_VERSION}-1_all.deb"
        DEB_URL="${BASE_URL}/${REPO}/client/lustre-source_${LUSTRE_VERSION}-1_all.deb"
        DEB_PATH="/tmp/lustre-source_${LUSTRE_VERSION}.deb"
        wget -q "$DEB_URL" -O "$DEB_PATH" \
            || fail "Could not fetch $DEB_URL"

        log "Unpacking with dpkg -x (avoids userspace binary install)"
        SRC_ROOT=$(mktemp -d)
        dpkg -x "$DEB_PATH" "$SRC_ROOT"
        cd "$SRC_ROOT/usr/src"
        tar xjf lustre-*.tar.bz2
        cd modules/lustre

        log "Configuring with CC=gcc-12 (matches internal team's proven recipe)"
        ./configure --disable-server \
                    --with-linux=/usr/src/linux-headers-$(uname -r) \
                    CC=gcc-12 \
                    >/var/log/lustre-configure.log 2>&1 \
            || fail "configure failed — see /var/log/lustre-configure.log"

        log "Building kernel modules + userspace (takes ~3-5 min)"
        make -j$(nproc) CC=gcc-12 >/var/log/lustre-make.log 2>&1 \
            || fail "make failed — see /var/log/lustre-make.log"

        log "Installing modules + userspace tools built against this kernel"
        make install CC=gcc-12 >/var/log/lustre-install.log 2>&1 \
            || fail "make install failed — see /var/log/lustre-install.log"

        depmod -a
        cd /
        rm -rf "$SRC_ROOT" "$DEB_PATH"
        ;;

    zypper)
        zypper ar -f "${BASE_URL}/${REPO}/client/" lustre-client || true
        zypper --gpg-auto-import-keys refresh
        zypper install -y kernel-devel lustre-client-dkms lustre-client
        ;;

esac

# Verify modules are present
if modinfo lustre >/dev/null 2>&1; then
    log "Lustre module available for kernel $(uname -r)"
else
    fail "Lustre module not found after install — DKMS build may have failed"
fi

# Disable LNet peer auto-discovery (Multi-Rail Auto-Discovery, MR-DD).
#
# MayaNAS HA uses floating VIPs: each Lustre target's NID is a VIP that moves
# to whichever node owns the resource group. During failover, the survivor
# briefly carries BOTH VIPs on the same physical NIC. LNet's MR-DD sees two
# NIDs respond from the same MAC and merges them into a Multi-Rail peer,
# assuming the peer has dual NICs for redundancy. The cache outlives failback,
# and OST RPCs misroute because LNet load-balances between the merged NIDs
# which now point to different physical nodes.
#
# Symptom on the client:
#   lfs check servers
#     OST0000-osc: Input/output error (5)
#     OST0001-osc: Input/output error (5)
#     MGC*: Cannot send after transport endpoint shutdown (108)
#   lnetctl peer show
#     primary nid: 10.x.x.137@tcp
#     Multi-Rail: true
#     peer ni: 10.x.x.116@tcp ... + 10.x.x.137@tcp ...
#
# Set at module load time so fresh clients never hit this.
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/lustre.conf <<'EOF'
# Disable LNet peer auto-discovery — required for MayaNAS floating-VIP HA.
# Without this, a failover that briefly co-locates two VIPs on the survivor's
# NIC merges them into a Multi-Rail peer, misrouting RPCs after failback.
options lnet lnet_peer_discovery_disabled=1
EOF
log "Wrote /etc/modprobe.d/lustre.conf (lnet_peer_discovery_disabled=1)"

# Try loading — non-fatal (user may want to tune before mounting)
if modprobe lustre 2>/dev/null; then
    log "modprobe lustre: OK"
    # If the module was already loaded before /etc/modprobe.d/lustre.conf was
    # in place, also apply at runtime. No-op on a fresh install.
    lnetctl set discovery 0 2>/dev/null && log "lnetctl set discovery 0 applied"
else
    log "WARN: modprobe lustre failed; try 'dmesg | tail' or check your kernel headers"
fi

# Confirm userspace tools
if command -v lfs >/dev/null && command -v mount.lustre >/dev/null; then
    log "Userspace tools installed: $(lfs --version 2>&1 | head -1)"
fi

mkdir -p /mnt/lustre

echo
echo "Lustre client install complete."
echo "Kernel:  $(uname -r)"
echo
echo "Next — mount your filesystem:"
echo "  sudo mount -t lustre <MGS-VIP>@tcp:/<fsname> /mnt/lustre"
echo
echo "Get the exact mount command from your MayaNAS terraform output:"
echo "  cd path/to/zettalane-terraform/gcp/mayanas"
echo "  terraform output -raw lustre_mount_command"
