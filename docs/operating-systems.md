# Operating systems

The module supports three OS families, selected via `os_family`:

| `os_family` | Image | Auto-resolved | SSH user | Auto-updates |
|---|---|---|---|---|
| `"ubuntu"` (default) | Ubuntu LTS aarch64, release in `ubuntu_version` | ✅ Yes (latest OCI-native image) | `ubuntu` | `unattended-upgrades` + `needrestart` |
| `"opensuse"` | openSUSE Leap Minimal VM aarch64, release in `opensuse_leap_version` | ✅ Yes, once imported (newest image of the release imported with the script) | `sles` | `zypper patch` systemd timers |
| `"fcos"` | Fedora CoreOS aarch64 (image-based, Ignition), boot image major in `fcos_version`, running release in `fcos_os_version` | ✅ Yes, once imported with `scripts/import-fcos-aarch64.sh` | `core` | OpenShift-style: an upgrade Plan rolls the pinned release out, one drained node at a time |
| `"opensuse"` + `opensuse_variant = "immutable"` | openSUSE Leap Immutable Mode aarch64 (read-only root), release in `opensuse_leap_version` | ✅ Yes, once imported with `--variant immutable` | `sles` | `transactional-update` systemd timers |

Renovate bumps both releases ([Dependency updates](updates.md#dependency-updates-renovate)).

### Ubuntu (default)

No extra steps needed. The latest image of the `ubuntu_version` LTS release for `VM.Standard.A1.Flex` is resolved automatically at plan time from the tenancy.

The bootstrap trims what a k3s node never uses from the server image: it purges ModemManager, udisks2, networkd-dispatcher, lxd-agent-loader and landscape-common, and masks multipathd and the motd-news, apport and xfs_scrub timers.

With `remove_oci_agent = true` (the default), it also removes the Oracle Cloud Agent and snapd 15 minutes after a successful bootstrap, with a transient timer that runs `/usr/local/sbin/k3s-oci-remove-oci-agent`. That saves ~50 MiB of memory plus ~150 MiB of page cache per node. Until the removal the agent ships `/var/log/k3s-cloud-init.log` to OCI Logging (`enable_oci_logging`), and a node whose bootstrap fails keeps the agent. Without the agent, the OCI console shows no instance metrics and OCI Logging gets no k3s runtime log; set `remove_oci_agent = false` to keep both. Running nodes change only when rebuilt. If one reboots within those 15 minutes, the timer is lost; run the script by hand.

### openSUSE Leap

OCI has no native openSUSE image. Use the included script to import one before running `tofu apply`:

```bash
./scripts/import-opensuse-aarch64.sh
```

The script:
1. Resolves the latest openSUSE Leap Minimal VM Cloud aarch64 QCOW2 of the release (default: the script's `LEAP_VERSION`, kept equal to `opensuse_leap_version`) from `download.opensuse.org`
2. Streams the image (~271 MiB) directly into a temporary OCI Object Storage bucket, no local disk required
3. Imports via the OCI REST API with `firmware: UEFI_64` and `launchMode: CUSTOM`
   (the OCI CLI's `oci compute image import` always defaults to BIOS; `UEFI_64` is required for `VM.Standard.A1.Flex`),
   recording `openSUSE Leap` and the release as the image's OS and OS version
4. Adds `VM.Standard.A1.Flex` shape compatibility
5. Cleans up the temp Object Storage object
6. Prints the image OCID (the module does not need it; see below)

Then set in `terraform.tfvars`:

```hcl
os_family = "opensuse"
# Only when you imported with --compartment-id outside the tenancy root:
# opensuse_image_compartment_ocid = "ocid1.compartment.oc1..."
```

The module finds the image by itself: it lists the images whose OS is `openSUSE Leap` and takes the
newest one of `opensuse_leap_version`. If that release isn't imported yet, it takes the newest
imported image of any release and plans warn. Set `os_image_id` only to pin one image. Images
imported by older versions of the script have no OS recorded: re-run the script with the same
`--leap-version` (and `--image-name`, if you used one) and it records the OS on the existing image.

**Script options:**

```
--compartment-id OCID   Compartment OCID (default: tenancy root)
--region REGION         OCI region (default: from ~/.oci/config)
--leap-version VERSION  openSUSE Leap version (default: LEAP_VERSION in the script)
--variant VARIANT       minimal (default) or immutable (Leap Immutable Mode, see below)
--bucket-name NAME      Temp bucket name (default: opensuse-image-import-tmp)
--keep-bucket           Do not delete the QCOW2 object after import
--image-name NAME       Custom display name for the imported image
```

**Prerequisites:** OCI CLI configured (`~/.oci/config`), `curl`, `python3`.

**Known caveats (verified with Leap 16.0 + VM.Standard.A1.Flex):**

| Caveat | Detail |
|---|---|
| **Image must be re-imported on new Leap releases** | The image is a custom import, so no update reaches it by itself. When Renovate bumps `opensuse_leap_version`, a rebuild keeps booting the newest imported image and plans warn (`opensuse_image_matches_leap_version`) until you run the script for the new release. For a newer build of the same release, import it under a new `--image-name`: the newest import wins |
| **UEFI_64 required at import time** | OCI's `oci compute image import` CLI hard-codes `firmware: BIOS`. The script works around this via a direct REST API call |
| **Shape compatibility not auto-detected** | OCI does not auto-detect the architecture of imported QCOW2 images; the script adds `VM.Standard.A1.Flex` explicitly |
| **Oracle Cloud Agent (OCA) unavailable** | No OCI-native monitoring agent on custom images |

### openSUSE Leap Immutable

Leap's Immutable Mode (the successor of Leap Micro) has a read-only root filesystem: packages
go into a new btrfs snapshot with `transactional-update` and are active after the next reboot,
and a failed update leaves the running snapshot untouched. Import it and select it:

```bash
./scripts/import-opensuse-aarch64.sh --variant immutable
```

```hcl
os_family          = "opensuse"
opensuse_variant   = "immutable"
enable_oci_logging = false # custom images have no Oracle Cloud Agent
```

The image is recorded with OS `openSUSE Leap Immutable`, so both variants can be imported side by
side. What differs from the Minimal image:

- **Each node reboots once during its first boot.** cloud-init installs what the image lacks (jq, tar,
  open-iscsi, nfs-client, cronie, k3s-selinux) into a new snapshot and reboots; the systemd unit
  `k3s-oci-bootstrap.service` then runs the same script again, which installs k3s, and disables
  itself when the script completes. The first boot's log is `/var/log/k3s-cloud-init.phase1.log`;
  if the second phase fails, the unit stays enabled and the next boot retries.
- **Updates** run on the same schedule as on Leap Minimal: `tu-security-patch.timer` (daily,
  `zypper patch --category security`) and `tu-full-patch.timer` (Tue-Thu), each into a new snapshot.
  When a snapshot is waiting, they write kured's sentinels, and kured reboots the node in its window.
  The image's own `transactional-update.timer` and `rebootmgr` are disabled.

### Fedora CoreOS

Fedora CoreOS is image-based. The module runs it the way OpenShift runs its CoreOS nodes: the
cluster decides which OS release the nodes run, and an in-cluster controller rolls it out. Zincati,
FCOS's own updater, is masked. Import the boot image, then select it:

```bash
./scripts/import-fcos-aarch64.sh            # current stable build (--stream testing|next)
```

```hcl
os_family                   = "fcos"
enable_object_storage_state = true  # required (the default)
region                      = "eu-frankfurt-1" # required
enable_oci_logging          = false # custom images have no Oracle Cloud Agent
```

How it differs from the cloud-init OSes:

- **Ignition, with the script in Object Storage.** FCOS reads only Ignition, and OCI's 32,000-byte
  metadata limit is too small for the node script inside an Ignition config. The module uploads the
  script to the `<cluster>-terraform-state` bucket and puts a read-only pre-authenticated request URL
  for it in a small Ignition config, as OpenShift's pointer Ignition config fetches the real one.
  Anyone with that URL can read what user-data holds on other OSes (the shared SSH host key, and the
  cluster secrets if `enable_vault = false`).
- **First boot pivots to the cluster's release** (OpenShift's firstboot pivot). The imported image
  (`fcos_version`) is only a starting point: before k3s starts, the node rebases to `fcos_os_version`
  along FCOS's update graph, one release per reboot when barrier releases lie in between, with
  k3s-selinux, python3 (for the OCI CLI) and cronie layered on the first hop.
- **OS updates are a cluster operation.** The release is pinned in `gitops/fcos-os/plan.yaml` (OpenShift's
  `osImageURL`); Renovate bumps it together with `fcos_os_version` when the stable stream moves. The
  `fcos-os` system-upgrade-controller Plan, added by the first server, rolls it out like OpenShift's
  Machine Config Daemon: in kured's window (Tue-Thu 02:15-04:15 UTC), one node at a time, cordoned and
  drained, then rebased onto the release's image (pinned by digest) and rebooted, through barrier
  releases first. OS reboots never overlap a k3s upgrade: on a node the Plans are `exclusive`
  (system-upgrade-controller keeps their jobs apart), and across nodes their windows don't
  overlap (k3s upgrades start at 23:00-23:59 UTC). kured stays installed and stands down while the Plan's job runs.
- **SSH** as `core`, with the keys from the instance's `ssh_authorized_keys` (Afterburn).
- **Longhorn**: the bootstrap adds a SELinux module that lets Fedora's iscsid log in to Longhorn's
  targets ([Longhorn KB](https://longhorn.io/kb/troubleshooting-volume-attachment-fails-due-to-selinux-denials/)).

### Using any other OS image

Set `os_image_id` to the OCID of any OCI image. **Only Ubuntu, openSUSE and Fedora CoreOS are tested.** Any other OS will need its own bootstrap logic, fork the repo and adapt `files/lib/bootstrap-ubuntu.sh` as a starting point.
