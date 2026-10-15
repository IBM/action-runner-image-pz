### **LXD Image Used by GitHub Actions Runner**

This guide describes how to build an LXD container or VM image with the GitHub Actions runner preinstalled, and how to start a runner from it. For Incus, see the [Incus guide](Incus_Image_Used_by_GitHub_Actions_Runner.md).

Supported: Ubuntu **22.04**, **24.04** and **26.04** on **ppc64le**, **s390x** and **x86_64**.

---

### **Prerequisites**

1. **LXD**
   The build scripts install LXD automatically when the `lxd` command is not found: snapd is installed if needed, LXD is installed from the latest LTS snap channel, and it is initialized with the preseed file for the host architecture (`scripts/assets/lxd_init_host_<arch>.yml`). Snap auto-refresh is held for LXD to avoid disrupting running builds.

   If LXD is already installed, the scripts do not upgrade it: they report whether a newer LTS channel is available and hold snap auto-refresh for LXD. To install it manually instead:
   ```bash
   sudo snap install lxd --channel=<latest-lts>/stable   # for example 5.21/stable
   sudo lxd init                                          # or: sudo lxd init --preseed < scripts/assets/lxd_init_host_$(uname -m).yml
   ```

2. Run the scripts from the repository root with `sudo`.

---

### **Building the GitHub Actions Runner Image**

Use `run.sh` and choose **LXD Container** or **LXD VM**, or call the scripts directly:

```bash
sudo ./scripts/lxd_container.sh <os> <version> [worker_type] [worker_cpu] [setup_type] [flags]
sudo ./scripts/lxd_vm.sh        <os> <version> [worker_type] [worker_cpu] [setup_type] [flags]
```

| Argument | Description |
|---|---|
| `os` | `ubuntu` |
| `version` | `22.04`, `24.04` or `26.04` |
| `worker_type` | Optional image-name suffix, for example `-2xlarge` (pass `""` to skip) |
| `worker_cpu` | Optional image-name suffix, for example `-p10` (pass `""` to skip) |
| `setup_type` | `minimal` (default) or `complete` |

Example, a complete Ubuntu 26.04 container image:
```bash
sudo ./scripts/lxd_container.sh ubuntu 26.04 "" "" complete
```

The build:
1. Launches a build instance from the LXD `ubuntu:<version>` image.
2. Copies the build scripts into it and runs the selected setup (`scripts/helpers/setup_install.sh`).
3. Creates the `runner` user (passwordless sudo), installs `/opt/register-runner.sh` and the `gha-runner.service` unit.
4. Snapshots the instance and publishes the snapshot as an image named `<os>-<version>-<arch><worker_type><worker_cpu>` (LXD VMs get a `-vm` suffix), for example `ubuntu-26.04-ppc64le` or `ubuntu-26.04-ppc64le-2xlarge-p10-vm`.
5. Launches and deletes a throwaway instance from the new image to prime LXD's storage (the "primer"), and exports the image under `/opt/distro/`.

The published image is tagged with the build commit, OS, version and setup type. Re-running the build with the same commit and options finds the existing image and skips the rebuild.

#### **Build Flags**

| Flag | Effect |
|---|---|
| `--lxd-debug` | Keep the build instance after the build (non-ephemeral) for inspection |
| `--skip-snap-lxd` | Do not install snapd/LXD and `configure-snap.sh` *inside* the image |
| `--skip-lxd-snapshot` | Do not snapshot the build instance. Publishing needs the snapshot, so this also skips publish, primer and export |
| `--skip-lxd-publish` | Do not publish an image (also skips primer and export) |
| `--skip-lxd-img-primer` | Do not prime the published image |
| `--skip-lxd-img-export` | Do not export the published image to `/opt/distro/` |
| `--delete-lxd-img` | Delete an existing image with the same name before building |

---

### **Next Steps: Configure and Start the Runner**

1. **Create the runner instance** from the published image:
   ```bash
   lxc launch <image-name> <instance-name>         # container
   lxc launch <image-name> <instance-name> --vm    # VM image (name ends in -vm)
   ```
   Add flags as needed (for example `-c security.nesting=true` to run Docker inside a container).

2. **Register and start the runner.** The image contains everything needed under `/opt/runner-cache`. Either use the bundled helper, which registers an ephemeral, unattended runner and starts it:
   ```bash
   lxc exec <instance-name> -- su - runner -c \
     "/opt/register-runner.sh -r <owner>/<repo> -t <registration-token> -l <labels> -n <runner-name>"
   ```
   or configure it by hand:
   ```bash
   lxc exec <instance-name> -- su - runner
   cd /opt/runner-cache
   ./config.sh --url https://github.com/<owner>/<repo> --token <registration-token>
   ./run.sh
   ```
   Get the registration token from your repository's **Settings → Actions → Runners → New self-hosted runner** page. Choose **Linux**; the architecture choice only changes the download commands shown there, which you do not need because the runner is preinstalled. See the [official GitHub documentation](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners#adding-a-self-hosted-runner-to-a-repository) for details.

3. **Target the runner** in your workflow with the labels used during configuration (`runs-on: [self-hosted, <label>]`).

---

### **Key Notes**

- Ensure that the required permissions and tools are available before running the script.
- Set `GITHUB_TOKEN` in the environment to avoid GitHub API rate limits during the build.
- For troubleshooting LXD initialization or network configurations, refer to the [official LXD documentation](https://documentation.ubuntu.com/lxd/).
