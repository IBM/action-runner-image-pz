### **Incus Image Used by GitHub Actions Runner**

This guide describes how to build an [Incus](https://linuxcontainers.org/incus/) container or VM image with the GitHub Actions runner preinstalled, and how to start a runner from it. The flow mirrors the [LXD guide](LXD_IMAGE_Used_by_GitHub_Actions_Runner.md); the differences are how Incus is installed and where the Ubuntu base image comes from.

Supported: Ubuntu **22.04**, **24.04** and **26.04** images on **ppc64le**, **s390x** and **x86_64** hosts running Ubuntu, Debian or a RHEL-family distribution (CentOS, AlmaLinux, Rocky, RHEL, Fedora).

> Ubuntu 22.04 **ppc64le VM** images cannot be built from the **Incus Images** source: GRUB 2.06 in 22.04 does not install in the distrobuilder chroot. Use 24.04/26.04, or the **Cloud Images** source.

---

### **Prerequisites**

1. **Incus**
   The build scripts run `install-incus.sh` for the host OS before every build. It builds and installs Incus from source (with its raft and cowsql dependencies), initializes it with `scripts/assets/incus_init_host_<arch>.yml`, and is skipped when Incus is already installed, the daemon is healthy and its bridge is up. The installer log is written to `/tmp/install-incus.log`.

   The installer can be tuned with environment variables:

   | Variable | Default | Description |
   |---|---|---|
   | `INCUS_VERSION` | `v7.0.1` | Incus release tag to build |
   | `RAFT_VERSION` | `v0.22.1` | raft release tag to build |
   | `USE_LVM` | `true` | Create an LVM storage pool on a loop file |
   | `LVM_LOOP_SIZE` | `200G` | Size of the loop file (`/var/lib/incus/disks/incus-lvm.img`) |
   | `LVM_VG_NAME` | `vg_incus` | LVM volume group name |
   | `CONFIG_FILE` | `scripts/assets/incus_init_host_<arch>.yml` | Preseed file passed to `incus admin init` |
   | `INCUS_IDMAP` | `1000000:1000000000` | root's `/etc/subuid` and `/etc/subgid` range (`base:size`); every container is mapped onto all of it. Images get `1000000:999000000` so the nested range fits inside the job container |

   Pass `--skip-snap-incus` to skip the installer when you manage Incus yourself; Incus must then already be installed and running. The same flag also skips installing Incus inside the image.

2. Run the scripts from the repository root with `sudo`.

---

### **Base Image Source**

Each build starts from an Ubuntu base image that is imported into Incus once (alias `ubuntu-<version>` for containers, `ubuntu-<version>-vm` for VMs) and reused by later builds. The image records where it came from; if you switch the source, the base image is replaced.

| Source | Flag | x86_64 | ppc64le / s390x |
|---|---|---|---|
| **Cloud Images** (default) | `--use-cloud-img` | [Ubuntu cloud images](https://cloud-images.ubuntu.com/releases/) | Ubuntu cloud images |
| **Incus Images** | `--use-incus-img` | Containers: Incus image server (`images:ubuntu/<version>`); VMs: built with distrobuilder | Built locally with distrobuilder |

Distrobuilder builds use the upstream [lxc-ci `ubuntu.yaml`](https://github.com/lxc/lxc-ci/blob/main/images/ubuntu.yaml) image definition with `patches/lxc-ci.patch` applied (adds GRUB for ppc64le and zipl for s390x VMs). Distrobuilder itself is built from source with `patches/distrobuilder.patch` and rebuilt whenever that patch changes. Packages are fetched from the FAU mirror, falling back to the official Ubuntu mirror (`ports.ubuntu.com` for ppc64le/s390x, `archive.ubuntu.com` for x86_64). The build log is kept at `/tmp/distrobuilder-build.log`.

---

### **Building the GitHub Actions Runner Image**

Use `run.sh` and choose **Incus Container** or **Incus VM**, or call the scripts directly:

```bash
sudo ./scripts/incus_container.sh <os> <version> [worker_type] [worker_cpu] [setup_type] [flags]
sudo ./scripts/incus_vm.sh        <os> <version> [worker_type] [worker_cpu] [setup_type] [flags]
```

| Argument | Description |
|---|---|
| `os` | `ubuntu` |
| `version` | `22.04`, `24.04` or `26.04` |
| `worker_type` | Optional image-name suffix, for example `-2xlarge` (pass `""` to skip) |
| `worker_cpu` | Optional image-name suffix, for example `-p10` (pass `""` to skip) |
| `setup_type` | `minimal` (default) or `complete` |

Examples:
```bash
# Complete Ubuntu 26.04 container from the Ubuntu cloud image
sudo ./scripts/incus_container.sh ubuntu 26.04 "" "" complete --use-cloud-img

# Minimal Ubuntu 26.04 VM built with distrobuilder
sudo ./scripts/incus_vm.sh ubuntu 26.04 "" "" minimal --use-incus-img
```

The build:
1. Ensures Incus is installed and the base image is present (see above).
2. Launches a build instance from the base image, copies the build scripts into it and runs the selected setup (`scripts/helpers/setup_install.sh`).
3. Creates the `runner` user (passwordless sudo), installs `/opt/register-runner.sh` and the `gha-runner.service` unit.
4. Snapshots the instance and publishes the snapshot as an image named `<os>-<version>-<arch><worker_type><worker_cpu>` (VMs get a `-vm` suffix), for example `ubuntu-26.04-s390x` or `ubuntu-26.04-ppc64le-2xlarge-p10-vm`. Container publishing is serialized with `/var/lock/incus-publish.lock`, so parallel container builds on one host are safe.
5. Launches and deletes a throwaway instance from the new image to prime Incus' storage (the "primer"), and exports the image under `/opt/distro/`.

The published image is tagged with the build commit, OS, version, setup type and base image source. Re-running the build with the same commit and options finds the existing image and skips the rebuild.

#### **Build Flags**

| Flag | Effect |
|---|---|
| `--use-cloud-img` | Use the Ubuntu cloud image as base image (default) |
| `--use-incus-img` | Use the Incus image server / distrobuilder as base image |
| `--skip-snap-incus` | Do not run the Incus installer on the host, nor install Incus *inside* the image |
| `--skip-incus-base-img` | (VM only) Do not build/import the base image; use the existing `ubuntu-<version>-vm` |
| `--incus-debug` | Keep the build instance after the build (non-ephemeral) for inspection |
| `--skip-snap-lxd` | Do not install snapd/LXD and `configure-snap.sh` *inside* the image |
| `--skip-incus-snapshot` | Do not snapshot the build instance. Publishing needs the snapshot, so this also skips publish, primer and export |
| `--skip-incus-publish` | Do not publish an image (also skips primer and export) |
| `--skip-incus-img-primer` | Do not prime the published image |
| `--skip-incus-img-export` | Do not export the published image to `/opt/distro/` |
| `--delete-incus-img` | Delete an existing image with the same name before building |

---

### **Next Steps: Configure and Start the Runner**

1. **Create the runner instance** from the published image:
   ```bash
   incus launch <image-name> <instance-name>         # container
   incus launch <image-name> <instance-name> --vm    # VM image (name ends in -vm)
   ```
   Add flags as needed (for example `-c security.nesting=true` to run Docker inside a container).

2. **Register and start the runner.** Either use the bundled helper, which registers an ephemeral, unattended runner and starts it:
   ```bash
   incus exec <instance-name> -- su - runner -c \
     "/opt/register-runner.sh -r <owner>/<repo> -t <registration-token> -l <labels> -n <runner-name>"
   ```
   or configure it by hand:
   ```bash
   incus exec <instance-name> -- su - runner
   cd /opt/runner-cache
   ./config.sh --url https://github.com/<owner>/<repo> --token <registration-token>
   ./run.sh
   ```
   Get the registration token from your repository's **Settings → Actions → Runners → New self-hosted runner** page (choose **Linux**; the runner is already installed, so skip the download commands). See the [official GitHub documentation](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners#adding-a-self-hosted-runner-to-a-repository) for details.

3. **Target the runner** in your workflow with the labels used during configuration (`runs-on: [self-hosted, <label>]`).

---

### **Key Notes**

- Set `GITHUB_TOKEN` in the environment to avoid GitHub API rate limits during the build.
- For Incus administration and troubleshooting, refer to the [official Incus documentation](https://linuxcontainers.org/incus/docs/main/).
