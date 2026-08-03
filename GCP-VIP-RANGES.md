# GCP VIP ranges — pre-flight check and manual override

On GCP the HA pair serves Lustre through two **floating IPs**. GCP implements these as
*alias IPs*, which must be drawn from a **secondary IP range** on the subnet — so the
deploy needs one named `mayanas-alias-range`, a `/24` inside `10.100.0.0/16`.

Almost always this is invisible: the deploy finds a free block, creates the range, and
you never think about it. This page is for the cases where you want to look first, or
where something collided.

---

## Check before you deploy

```bash
./gcp-check-vip-range.sh -p my-project -r us-central1
```

Read-only. It takes a couple of seconds and creates nothing.

It accepts a zone as well, so you can paste the same value you would give the deploy:

```bash
./gcp-check-vip-range.sh -p my-project -z us-central1-f
```

### Modes

| Command | What it does |
|---|---|
| `-p P` | **lists** every secondary range in the VPC. No region needed — CIDRs are VPC-wide |
| `-p P -r R` | the same list, plus what the deploy will do in your subnet |
| `-p P -r R --auto` | prints **one CIDR** and nothing else — the block to pass to `--vip-range` |
| `-p P -r R --auto --create` | also **creates** `mayanas-alias-range` at that block |
| `-p P -r R --delete` | **removes** `mayanas-alias-range`, once no instance is using it |

`--list` names the default explicitly if you prefer to be unambiguous.

Because `--auto` prints nothing but the CIDR, it composes:

```bash
./deploy-lustre.sh ... --vip-range "$(./gcp-check-vip-range.sh -p my-project -r us-west1 --auto)"
```

The listing looks like this:

```
Secondary IP ranges in VPC 'default' (project my-project)

  REGION         SUBNET     NAME                   CIDR
  us-central1    default    mayanas-alias-range    10.100.198.0/24
  us-west1       default    gke-pods               10.9.0.0/24
  us-west1       default    mayanas-alias-range    10.100.109.0/24

Target subnet: default/us-west1
  mayanas-alias-range = 10.100.109.0/24 — already present, the deploy will reuse it.
  Nothing to do: deploy without --vip-range.
```

If the subnet has no range yet it names the first free block instead, and if every `/24`
in `10.100.0.0/16` is taken it says so and exits non-zero — see
[Choosing your own range](#choosing-your-own-range).

In `--auto` without `--create`, a line on stderr saying `would create ...` is normal. It
tells you what the deploy is going to do; it has not done it.

### Options

| | |
|---|---|
| `-p, --project <ID>` | GCP project (required) |
| `-r, --region <REGION>` | region, e.g. `us-central1` (required except for listing) |
| `-z, --zone <ZONE>` | zone instead of region, e.g. `us-central1-f` |
| `-n, --network <NAME>` | VPC network (default `default`) |
| `-s, --subnet <NAME>` | subnet (default `default`) |
| `-L, --list` | list the VPC's secondary ranges (the default) |
| `-a, --auto` | print just the CIDR, for `--vip-range` |
| `-c, --create` | create the range (implies `--auto`). The deploy passes this for you |
| `-D, --delete` | remove the range when you are finished with the region |

---

## Choosing your own range

Pass `--vip-range` to the deploy and it will use exactly that block:

```bash
./deploy-lustre.sh --cloud gcp -p my-project -z us-central1-f -n lustre \
    -k ~/.ssh/id_rsa.pub --vip-range 10.120.7.0/24
```

Reach for this when:

- **`10.100.0.0/16` is already yours.** If your VPC uses that space, name a block outside
  it. Any free `/24` works; it does not need to be in `10.100.x`.
- **Your addressing plan says where VIPs live.** Firewall rules, IPAM records or peering
  routes may expect storage addresses in a particular block.
- **You are joining an existing range.** If a subnet already has `mayanas-alias-range`
  and you want a second HA pair to share it, pass that CIDR.

The range must be free across the **whole VPC**, not just the subnet — see below.

---

## Troubleshooting

### The deploy stopped with `Failed to create mayanas-alias-range ... Invalid IPCidrRange`

The block chosen for the VIPs overlaps a range your VPC already uses. The message names
both the block it tried and the one it collided with.

Let the pre-flight check pick a free block and create it, then redeploy naming it:

```bash
./gcp-check-vip-range.sh -p my-project -r us-central1 --auto --create   # prints the block it made
./deploy-lustre.sh ... --vip-range <that block>
```

Or, if your addressing plan already says where storage VIPs live, skip the check and pass
that block directly — `--vip-range` is taken as given.

Running the check bare first is worth a moment: it lists what your VPC already holds and
names the same block read-only, so you can confirm it suits your network before anything
is created.

### The deploy stopped saying the subnet already has a different `mayanas-alias-range`

The subnet carries a range that does not contain this deploy's VIPs. The deploy will not
delete it, because another HA pair may be using it. Either join it:

```bash
./deploy-lustre.sh ... --vip-range <the existing CIDR>
```

or, if nothing is using it, remove it and deploy again:

```bash
./gcp-check-vip-range.sh -p my-project -r <region> --delete
```

### `gcloud` errors, or the check prints nothing unexpectedly

The check needs an authenticated `gcloud` on the machine you run it from — the same one
the deploy needs:

```bash
gcloud auth login
gcloud config set project my-project
```

It also needs permission to read subnets (`compute.subnetworks.get` / `.list`), and
`compute.subnetworks.update` if you use `--create` or run the deploy.

---

## Things worth knowing

**Range CIDRs are unique across the whole VPC, not per subnet.** A block in use in
`us-central1` cannot be reused in `us-west1`. Deploying to a different region does not
sidestep a collision — pick a different block instead.

**The range outlives any single cluster, deliberately.** `--destroy` removes the cluster
and leaves `mayanas-alias-range` in place, because additional HA pairs in the same subnet
take their VIPs from it. Removing it while another pair is running would strip that
cluster's addresses. So nothing removes it automatically — clean it up when you are
finished with the region:

```bash
./gcp-check-vip-range.sh -p my-project -r us-west1 --delete
```

It refuses if any instance still holds an alias IP from the range, and names them:

```
Refusing to remove mayanas-alias-range=10.100.109.0/24 from default/us-west1.
These instances still hold alias IPs from it:
  lustre-node1  10.100.109.101/32
  lustre-node2  10.100.109.102/32
```

A stopped VM keeps its alias IPs, so a range can legitimately still be spoken for by a
cluster that is not running. If you are certain, the underlying command is:

```bash
gcloud compute networks subnets update <subnet> --region <region> \
    --remove-secondary-ranges=mayanas-alias-range
```

**Each region gets its own block.** The same range name exists independently per subnet,
so `us-central1` and `europe-west1` each hold a `mayanas-alias-range` at different CIDRs.

**Ordinary VPCs are unaffected.** GKE pod and service ranges, and most default
allocations, live outside `10.100.0.0/16` and do not collide.

---

Questions, or a VPC layout this does not cover?
[support@zettalane.com](mailto:support@zettalane.com) ·
[zettalane.com](https://www.zettalane.com/)
