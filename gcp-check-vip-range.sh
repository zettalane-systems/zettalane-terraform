#!/bin/bash
#
# gcp-check-vip-range.sh — inspect and pick the VIP secondary range for a MayaNAS HA pair.
#
# On GCP the floating VIPs are alias IPs, which must come from a secondary IP range on the
# subnet. The deploy adds one named mayanas-alias-range, a /24 from 10.100.0.0/16. This
# tool shows what your VPC already has, and picks or creates a block that fits.
#
#   gcp-check-vip-range.sh -p PROJ [--list]               list every secondary range
#   gcp-check-vip-range.sh -p PROJ -r REG                 ... and what the deploy will do
#   gcp-check-vip-range.sh -p PROJ -r REG --auto          print the CIDR to use
#   gcp-check-vip-range.sh -p PROJ -r REG --auto --create create mayanas-alias-range at it
#   gcp-check-vip-range.sh -p PROJ -r REG --delete        remove it once the cluster is gone
#
# --auto prints ONE CIDR and nothing else on stdout, so it can be used directly:
#   ./deploy-lustre.sh ... --vip-range "$(./gcp-check-vip-range.sh -p P -r R --auto)"
#
# Why this exists: terraform picks a candidate with contains(), which is string equality,
# so a range that OVERLAPS a candidate without matching it exactly (10.100.108.128/25 vs
# the 10.100.108.0/24 candidate) is invisible and the deploy dies at boot with "Invalid
# IPCidrRange ... conflicts with existing subnetwork". This computes real interval
# overlap. Secondary range CIDRs must be unique across the whole VPC, not just the
# subnet, so changing region does not avoid a collision.

set -u

RANGE_NAME="mayanas-alias-range"

usage() {
    cat >&2 <<EOF
usage: $(basename "$0") -p <project> [-r <region>] [-n <net>] [-s <subnet>] [mode]
       $(basename "$0") <project> <region> [network] [subnet]

  --list             list every secondary range in the VPC (the default).
                     -r is optional; give it to also see what the deploy would use.
  --auto             print just the CIDR to pass to deploy-lustre.sh --vip-range
  --auto --create    also create $RANGE_NAME at that CIDR if the subnet has none
  --delete           remove $RANGE_NAME from the subnet, once no cluster is using it.
                     Deploys leave it in place deliberately: further HA pairs draw
                     their VIPs from it, so removing it is always a deliberate act.

  -p, --project <ID>      GCP project (required)
  -r, --region <REGION>   region, e.g. us-central1 (required except for --list)
  -z, --zone <ZONE>       zone instead of region, e.g. us-central1-f
  -n, --network <NAME>    VPC network (default: default)
  -s, --subnet <NAME>     subnet (default: default)
EOF
    exit 2
}

PROJECT=""; REGION=""; NETWORK="default"; SUBNET="default"; MODE="list"; CREATE=no
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--project|--project-id) PROJECT="${2:-}"; shift 2 ;;
        -r|--region)               REGION="${2:-}";  shift 2 ;;
        -z|--zone)                 REGION="${2%-*}"; shift 2 ;;   # us-west1-b -> us-west1
        -n|--network)              NETWORK="${2:-}"; shift 2 ;;
        -s|--subnet)               SUBNET="${2:-}";  shift 2 ;;
        -a|--auto)                 MODE="auto"; shift ;;
        -L|--list)                 MODE="list"; shift ;;
        -D|--delete|--remove)      MODE="delete"; shift ;;
        -c|--create)               CREATE=yes; shift ;;
        -h|--help)                 usage ;;
        -*)                        echo "unknown option: $1" >&2; usage ;;
        *)                         POS+=("$1"); shift ;;
    esac
done
# Positional form, for callers that predate the flags.
[ -n "$PROJECT" ] || PROJECT="${POS[0]:-}"
[ -n "$REGION" ]  || REGION="${POS[1]:-}"
[ "${#POS[@]}" -ge 3 ] && NETWORK="${POS[2]}"
[ "${#POS[@]}" -ge 4 ] && SUBNET="${POS[3]}"

if [ "$CREATE" = yes ]; then
    [ "$MODE" = delete ] && { echo "--create and --delete are opposites" >&2; usage; }
    # Creating is meaningless without a value to create, so --create alone means
    # --auto --create rather than an error about flag combinations.
    MODE="auto"
fi

# Fail LOUDLY on bad arguments. Everything else degrades to silence so this can never
# block a deploy -- which means a typo would otherwise look exactly like "nothing to do".
[ -n "$PROJECT" ] || usage
# A region is what makes a subnet identifiable, so every mode that acts on one needs it.
# Plain listing does not: ranges are unique VPC-wide, and seeing all of them at once is
# the point.
if [ -z "$REGION" ] && [ "$MODE" != list ]; then
    echo "--$MODE needs a region: -r <region> (or -z <zone>)" >&2
    usage
fi

if ! command -v gcloud >/dev/null 2>&1; then
    # In --auto the caller is a deploy: stay silent and let terraform select, since its own
    # range_analysis fails loudly on a broken gcloud. When a human asked for a listing,
    # silence would just be baffling.
    [ "$MODE" = auto ] && exit 0
    echo "gcloud not found. Install the Google Cloud CLI and run 'gcloud auth login'." >&2
    exit 1
fi

TMPA=$(mktemp) || exit 0
TMPC=$(mktemp) || exit 0
TMPE=$(mktemp) || exit 0
trap 'rm -f "$TMPA" "$TMPC" "$TMPE"' EXIT

# One query for everything. --flatten is REQUIRED: without it gcloud joins each subnet's
# ranges with ';' into a single value ("10.9.0.0/24;10.100.108.128/25"), pairing the wrong
# name with the wrong CIDR and defeating every comparison below.
gcloud compute networks subnets list \
    --project="$PROJECT" \
    --flatten='secondaryIpRanges[]' \
    --format='value(region.basename(),name,secondaryIpRanges.rangeName,secondaryIpRanges.ipCidrRange)' \
    --filter="network:$NETWORK" \
    --quiet > "$TMPA" 2>"$TMPE" || {
        # Loud in EVERY mode, including --auto. Staying silent here was wrong: an expired
        # token exits non-zero with the fix printed on stderr, and swallowing that left the
        # caller with an empty range and no idea why -- the deploy would go on to pick a
        # block with no knowledge of the VPC. Absent gcloud is different (handled above):
        # there is no error text to relay and terraform reports it clearly enough.
        echo "Could not list subnets in project '$PROJECT':" >&2
        sed 's/^/  /' "$TMPE" >&2
        echo "  Check the project ID and compute.subnetworks.list permission." >&2
        exit 1
    }
# An unreadable project does NOT set a non-zero status -- gcloud prints "Some requests did
# not succeed" and exits 0 with an empty list, which is indistinguishable from a VPC that
# genuinely has no secondary ranges. Choosing a range off that would be a guess.
if grep -q 'did not succeed' "$TMPE" 2>/dev/null; then
    echo "gcloud could not read every subnet in network '$NETWORK':" >&2
    sed 's/^/  /' "$TMPE" >&2
    echo "  Refusing to work from a partial list — check the project ID and permissions." >&2
    exit 1
fi

# This subnet's own range, if it has one. Additional HA pairs take their VIPs from the same
# range, so reusing it is required for multi-pair, not merely tidy. Match the name EXACTLY:
# a prefix match would also catch mayanas-alias-range1, which exists in real VPCs.
OURS=$(awk -F'\t' -v r="$REGION" -v s="$SUBNET" -v n="$RANGE_NAME" \
    '$1==r && $2==s && $3==n {print $4}' "$TMPA")

# First free /24, scanning from a region-derived offset so each region deterministically
# lands somewhere different -- the same rule terraform uses, kept so this tool and the
# module agree on which range a given region gets.
cut -f4 "$TMPA" | grep -v '^$' | awk -v region="$REGION" '
    BEGIN {
        n = 0                                    # awk subscripts are STRINGS: without
                                                 # this the first range lands in lo[""]
        for (i = 1; i <= length(region); i++) h += i * 3
        start = h % 256
    }
    function ip2int(a,   p) { split(a, p, "."); return p[1]*16777216 + p[2]*65536 + p[3]*256 + p[4] }
    {
        split($0, c, "/"); if (c[1] == "") next
        lo[n] = ip2int(c[1])
        hi[n] = lo[n] + 2 ^ (32 - c[2]) - 1      # inclusive last address
        n++
    }
    END {
        for (k = 0; k < 256; k++) {
            i  = (start + k) % 256
            cs = ip2int("10.100." i ".0"); ce = cs + 255
            free = 1
            for (j = 0; j < n; j++)
                if (cs <= hi[j] && lo[j] <= ce) { free = 0; break }   # interval overlap
            if (free) print "10.100." i ".0/24"
        }
    }
' > "$TMPC"
FREE=$(head -1 "$TMPC")

# ---- listing mode -------------------------------------------------------------------
if [ "$MODE" = list ]; then
    echo "Secondary IP ranges in VPC '$NETWORK' (project $PROJECT)"
    echo
    if [ -s "$TMPA" ]; then
        printf '  %-14s %-10s %-22s %s\n' REGION SUBNET NAME CIDR
        awk -F'\t' '{ printf "  %-14s %-10s %-22s %s\n", $1, $2, $3, $4 }' "$TMPA"
    else
        echo "  (none — this VPC has no secondary ranges at all)"
    fi
    # Without a region there is no target subnet to report on -- the listing IS the
    # answer. Ranges are unique VPC-wide, so it is complete on its own.
    if [ -z "$REGION" ]; then
        echo "Pass -r <region> to see what a deploy into that region would use."
        exit 0
    fi
    echo
    echo "Target subnet: $SUBNET/$REGION"
    if [ -n "$OURS" ]; then
        echo "  $RANGE_NAME = $OURS — already present, the deploy will reuse it."
        echo "  Nothing to do: deploy without --vip-range."
    elif [ -n "$FREE" ]; then
        echo "  no $RANGE_NAME yet. First block free across the whole VPC: $FREE"
        echo "  Deploy as usual, or pin it:"
        echo "    $(basename "$0") -p $PROJECT -r $REGION --auto --create"
        echo "    ./deploy-lustre.sh ... --vip-range $FREE"
    else
        echo "  no $RANGE_NAME, and every /24 in 10.100.0.0/16 is taken."
        echo "  Choose a block outside it:  ./deploy-lustre.sh ... --vip-range 10.120.7.0/24"
    fi
    exit 0
fi

# ---- delete mode --------------------------------------------------------------------
# A deploy leaves the range behind on purpose, because further HA pairs in the subnet take
# their VIPs from it and removing it would strip a running cluster's addresses. So there
# is no automatic cleanup anywhere -- this is the deliberate act, and it checks first.
if [ "$MODE" = delete ]; then
    if [ -z "$OURS" ]; then
        echo "No $RANGE_NAME in $SUBNET/$REGION — nothing to remove."
        exit 0
    fi

    # Refuse while anything still holds an alias IP from it. GCP may reject the removal
    # too, but by then we would have said "removing..." -- and its error does not name the
    # instances, which is the thing you actually need to know.
    IN_USE=$(gcloud compute instances list \
        --project="$PROJECT" \
        --filter="zone~$REGION" \
        --flatten='networkInterfaces[].aliasIpRanges[]' \
        --format='value(name,networkInterfaces.aliasIpRanges.subnetworkRangeName,networkInterfaces.aliasIpRanges.ipCidrRange)' \
        --quiet 2>/dev/null | awk -F'\t' -v n="$RANGE_NAME" '$2==n { print "  " $1 "  " $3 }')

    if [ -n "$IN_USE" ]; then
        echo "Refusing to remove $RANGE_NAME=$OURS from $SUBNET/$REGION." >&2
        echo "These instances still hold alias IPs from it:" >&2
        printf '%s\n' "$IN_USE" >&2
        echo "Destroy those clusters first:  ./deploy-lustre.sh ... --destroy" >&2
        exit 1
    fi

    echo "Removing $RANGE_NAME=$OURS from $SUBNET/$REGION (no instance is using it)…"
    ERR=$(gcloud compute networks subnets update "$SUBNET" \
              --project="$PROJECT" --region="$REGION" \
              --remove-secondary-ranges="$RANGE_NAME" \
              --quiet 2>&1) && { echo "Removed $RANGE_NAME=$OURS."; exit 0; }

    echo "Could not remove $RANGE_NAME=$OURS:" >&2
    printf '  %s\n' "$ERR" | head -3 >&2
    # A stopped VM keeps its alias IPs, and so does anything outside this region's
    # instance list, so GCP can still hold a reference we did not see.
    echo "  Something may still reference it. Check for stopped VMs, then retry." >&2
    exit 1
fi

# ---- auto mode ----------------------------------------------------------------------
# Reuse wins over selecting a new block: a second HA pair in this subnet MUST draw its
# VIPs from the range the first one created.
if [ -n "$OURS" ]; then
    echo "$OURS"
    [ "$CREATE" = yes ] && echo "$RANGE_NAME already exists in $SUBNET/$REGION — reusing $OURS" >&2
    exit 0
fi

[ -n "$FREE" ] || {
    echo "No free /24 left in 10.100.0.0/16 in VPC '$NETWORK'." >&2
    echo "  Every candidate overlaps a secondary range already in this VPC. Secondary" >&2
    echo "  range CIDRs must be unique VPC-wide, so another region will not help." >&2
    echo "  Choose a free block yourself and pass it:  --vip-range 10.120.7.0/24" >&2
    exit 1
}

if [ "$CREATE" != yes ]; then
    echo "$FREE"
    echo "would create $RANGE_NAME=$FREE in $SUBNET/$REGION (--create to do it)" >&2
    exit 0
fi

# Create with the operator's credentials rather than leaving it to the node's startup
# script, so the instance service account does not need subnet-edit rights on the
# customer's VPC -- and so gcloud, not our arithmetic, has the final say. A rejection
# means something changed since the scan, so try the next candidate.
TRIES=0
MAX_TRIES=5
while read -r CAND; do
    [ -n "$CAND" ] || continue
    TRIES=$((TRIES + 1))
    ERR=$(gcloud compute networks subnets update "$SUBNET" \
              --project="$PROJECT" --region="$REGION" \
              --add-secondary-ranges="$RANGE_NAME=$CAND" \
              --quiet 2>&1) && {
        echo "$CAND"
        echo "created $RANGE_NAME=$CAND in $SUBNET/$REGION" >&2
        echo "  deploy with:  ./deploy-lustre.sh ... --vip-range $CAND" >&2
        exit 0
    }

    # Only a CIDR conflict is worth another candidate. Anything else (permission denied,
    # quota, subnet gone) will reject every candidate identically.
    case "$ERR" in
        *conflict*|*Invalid\ IPCidrRange*|*overlap*) ;;
        *)
            echo "Creating $RANGE_NAME=$CAND failed:" >&2
            printf '  %s\n' "$ERR" | head -3 >&2
            echo "  Not a CIDR conflict, so other candidates would fail the same way." >&2
            echo "  Check compute.subnetworks.update permission, or pass --vip-range." >&2
            exit 1 ;;
    esac
    [ "$TRIES" -lt "$MAX_TRIES" ] || {
        echo "$MAX_TRIES candidates rejected as conflicting in $SUBNET/$REGION." >&2
        echo "  The VPC may be changing underneath us. Retry, or pass --vip-range <CIDR>." >&2
        exit 1 ; }
done < "$TMPC"

echo "Could not create $RANGE_NAME in $SUBNET/$REGION." >&2
echo "  Every free candidate was rejected by GCP. Check permissions" >&2
echo "  (compute.subnetworks.update) or pass a range explicitly: --vip-range 10.120.7.0/24" >&2
exit 1
