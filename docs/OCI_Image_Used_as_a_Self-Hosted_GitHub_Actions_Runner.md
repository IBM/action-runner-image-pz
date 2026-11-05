### **OCI Image Used as a Self-Hosted GitHub Actions Runner**

A **self-hosted runner** is a system you deploy and manage to execute jobs from GitHub Actions workflows on GitHub.com. This document outlines the steps to build and configure an OCI (Docker/Podman) image for a self-hosted runner.

#### **Additional Resources**
Refer to GitHub's official documentation on self-hosted runners for detailed information:
- [About Self-Hosted Runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners)
- [Adding a Self-Hosted Runner](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners)
- [Hardening Self-Hosted Runners](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)

---

### **Prerequisites**
1. **Docker or Podman**
   - `scripts/docker.sh` installs Docker automatically when it is missing, using the host's `images/<os>/scripts/build/install-docker.sh` (Ubuntu and CentOS hosts).
   - `scripts/podman.sh` installs Podman automatically only on CentOS hosts; on other hosts install it first (for example `sudo apt-get install podman`).
2. Run the scripts from the repository root: the repository is the build context.

---

### **Building the Runner Images**

Use `run.sh` and choose **Docker** or **Podman**, or call the scripts directly:

```bash
sudo ./scripts/docker.sh <os> <version>
sudo ./scripts/podman.sh <os> <version>
```

| `os` | `version` | Dockerfile |
|---|---|---|
| `ubuntu` | `22.04`, `24.04`, `26.04` | `dockerfiles/Dockerfile.ubuntu.<version>` |
| `centos` | `9` | `dockerfiles/Dockerfile.centos.9` |
| `ubi` | `9`, `10` | `dockerfiles/Dockerfile.ubi.<version>` |

The image is tagged `runner:<os>.<version>`, for example `runner:ubuntu.26.04` (Podman shows it as `localhost/runner:ubuntu.26.04`). It contains the GitHub Actions runner, built from source for the host architecture: the latest release with `patches/runner-sdk8-<arch>.patch`, or upstream main with `patches/runner-main-sdk8-<arch>.patch` if the release fails to patch or build (test failures do not trigger this fallback). It is installed in `/opt/runner-cache` and owned by the `runner` user. OCI images always use the minimal setup: the runner plus the tools needed to build it (git, curl, sudo, the .NET 8 SDK and compilers).

#### **RHEL (UBI) Images**

The `ubi` images give workflows a RHEL userspace. They are built from the [Red Hat Universal Base Image](https://catalog.redhat.com/en/software/base-images) and install packages from the public UBI repositories only, so no RHEL subscription is needed, on any Linux host.

| Base image | ppc64le | s390x | x86_64 |
|---|---|---|---|
| `ubi9/ubi` | POWER9 or later | z14 or later | x86-64-v2 or later |
| `ubi10/ubi` | POWER10 or later | z15 or later | x86-64-v3 or later |

- **Build on older hardware with UBI 9.** A UBI 10 image does not run on CPUs below its baseline.
- **Workflows see the UBI package set.** Steps can install from the UBI repositories with `sudo dnf install`. The full RHEL repositories are available only when the container runs on a subscribed RHEL host, and an image that includes those packages can no longer be redistributed under the UBI terms.
- **Redistribution.** If you publish an image, the UBI EULA applies to it. See the [UBI FAQ](https://developers.redhat.com/articles/ubi-faq).
- **Red Hat support.** The image runs on any Linux host, but Red Hat supports UBI containers only on a subscribed RHEL host or OpenShift cluster.
- **`sudo` PAM errors.** See [Troubleshooting](#troubleshooting).

---

### **Network Requirements**

The runner only opens **outbound** HTTPS (port `443`) connections to GitHub; no inbound ports or port mappings are needed. If your network restricts egress, allow the GitHub domains listed in [Communication between self-hosted runners and GitHub](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners#communication-between-self-hosted-runners-and-github).

---

### **Using the Self-Hosted Runner**

The image is not registered with GitHub. Get a registration token from your repository's **Settings → Actions → Runners → New self-hosted runner** page, then register when the container starts.

#### **Register at Start (recommended)**
```bash
docker run --rm runner:ubuntu.26.04 bash -c \
  "/opt/runner-cache/config.sh --unattended --ephemeral --url https://github.com/<owner>/<repo> --token <registration-token> \
   && /opt/runner-cache/run.sh"
```
Replace `docker` with `podman` for Podman. `--ephemeral` makes the runner take a single job and then unregister, which suits throwaway containers.

#### **Pre-Configured Runner Image**
Alternatively, bake the registration into an application-specific image with [`dockerfiles/Dockerfile.test`](../dockerfiles/Dockerfile.test):

```dockerfile
ARG     BASE_IMAGE=runner:ubuntu.26.04
FROM    ${BASE_IMAGE}

ARG     REPO TOKEN

RUN     /opt/runner-cache/config.sh --url ${REPO} --token ${TOKEN}

CMD     /opt/runner-cache/run.sh
```

- **Docker**:
  ```bash
  docker build --build-arg BASE_IMAGE=runner:ubuntu.26.04 --build-arg REPO=https://github.com/<owner>/<repo> --build-arg TOKEN=<registration-token> -f dockerfiles/Dockerfile.test --tag runner:test .
  docker run runner:test
  ```
- **Podman**:
  ```bash
  podman build --build-arg BASE_IMAGE=runner:ubuntu.26.04 --build-arg REPO=https://github.com/<owner>/<repo> --build-arg TOKEN=<registration-token> --squash-all -f dockerfiles/Dockerfile.test --tag runner:test .
  podman run runner:test
  ```

> **Security note:** a pre-configured image stores the runner's credentials (`/opt/runner-cache/.credentials`, `.runner`) in an image layer. Anyone who can pull the image can act as that runner, so keep such images private, or prefer registering at start.

---

#### **Sample Workflow for Testing**
Create a workflow file (`.github/workflows/Makefile.yml`) in your repository:
```yaml
name: Makefile CI

on:
  push:
    branches: [ "main" ]
  pull_request:
    branches: [ "main" ]

jobs:
  build:
    runs-on: self-hosted
    steps:
    - uses: actions/checkout@v5

    - name: Install Dependencies
      run: sudo apt-get install -y golang-go

    - name: Build
      run: GOPATH=$HOME/go GOCACHE=/tmp/go make
```

---

### **Example Run Output**
When starting the runner:
```
√ Connected to GitHub

Current runner version: '2.338.0'
2026-10-13 01:56:33Z: Listening for Jobs
2026-10-13 01:56:40Z: Running job: build
2026-10-13 01:57:39Z: Job build completed with result: Succeeded
```

#### **GitHub Actions Workflow Status**
Navigate to the GitHub Actions page for your repository to view workflow execution details.

---

### **Troubleshooting**

#### **`sudo` Fails with a PAM Account Management Error**

A `ubi` or `centos` image can show this error during the build, at the `sudo -u runner /opt/runner-cache/config.sh --version` step, or later, when a workflow step runs `sudo`:

```
sudo: PAM account management error: Authentication service cannot retrieve authentication info
sudo: a password is required
```

**Cause:** the container cannot read `/etc/shadow`, which `sudo` needs for its PAM account check. RHEL-based images ship that file with mode `0000`, so even root needs the `CAP_DAC_OVERRIDE` capability to read it. Podman grants that capability by default, so this points to a host setting that removes it. Ubuntu images use mode `0640`, which root can read as the owner.

| Without `CAP_DAC_OVERRIDE` | `sudo` as root (build step) | `sudo` as `runner` (workflow step) |
|---|---|---|
| UBI 9, AlmaLinux 9 | Fails | Fails |
| UBI 10 | Works | Fails |
| Ubuntu 24.04 | Works | Works |

**Find the cause.** Run these as the user who ran the failing build. They do not change any Podman settings:

```bash
cat > /tmp/Containerfile.diag <<'EOF'
FROM registry.access.redhat.com/ubi9/ubi:latest
RUN (( 0x$(awk '/CapEff/{print $2}' /proc/self/status) & 2 )) && echo HAS_DAC_OVERRIDE || echo NO_DAC_OVERRIDE; head -c0 /etc/shadow && echo SHADOW_READABLE || echo SHADOW_UNREADABLE
EOF
podman build --no-cache -f /tmp/Containerfile.diag "$(mktemp -d)"
grep -rn default_capabilities /etc/containers /usr/share/containers ~/.config/containers 2>/dev/null
```

| Output | Meaning | What to do |
|---|---|---|
| `NO_DAC_OVERRIDE`, `SHADOW_UNREADABLE` | The capability is missing | Use a fix below |
| `HAS_DAC_OVERRIDE`, `SHADOW_UNREADABLE` | Something else blocks the read, possibly AppArmor or SELinux | Check `dmesg \| grep -i denied` and adjust that policy |
| `HAS_DAC_OVERRIDE`, `SHADOW_READABLE` | The container can read the file, so this is a different problem | [Report a bug](https://github.com/IBM/action-runner-image-pz/issues/new?template=bug_report.md) with the output |

**Fix.** Use the first option that fits your host. These steps use Podman.

1. **Restore the capability on the host (recommended).** This fixes both builds and running containers. Set `default_capabilities` in `/etc/containers/containers.conf`, or in `~/.config/containers/containers.conf` for rootless Podman. If the file already sets it, add `"DAC_OVERRIDE"` to the existing list and keep the other entries. Otherwise, use Podman's default list:

    ```toml
    [containers]
    default_capabilities = ["CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "NET_BIND_SERVICE", "SETFCAP", "SETGID", "SETPCAP", "SETUID", "SYS_CHROOT"]
    ```

2. **Add the capability per command.** `scripts/podman.sh` does not pass this option, so run the build directly from the repository root, and add the same option when you start the container:

    ```bash
    podman build --no-cache --cap-add=CAP_DAC_OVERRIDE -f dockerfiles/Dockerfile.ubi.9 \
        --build-arg RUNNERPATCH="../patches/runner-sdk8-$(uname -m).patch" \
        --build-arg RUNNERMAINPATCH="../patches/runner-main-sdk8-$(uname -m).patch" \
        --build-arg ARCH="$(uname -m)" \
        --tag runner:ubi.9 .
    podman run --rm --cap-add=CAP_DAC_OVERRIDE runner:ubi.9 sudo -n true
    ```

3. **Change the image.** Use this only when the host cannot grant the capability, for example when Podman runs inside a container that lacks it. In the Dockerfile, start the step that runs `sudo -u runner` with `chmod 0400 /etc/shadow`:

    ```dockerfile
    RUN     chmod 0400 /etc/shadow && \
            mkdir -p /opt/runner-cache && \
            tar -xf /tmp/runner/_package/*.tar.gz -C /opt/runner-cache && \
            chown -R runner:runner /opt/runner-cache && \
            sudo -u runner /opt/runner-cache/config.sh --version
    ```

    This fixes both builds and workflow steps, but it moves away from the RHEL default: any root process in the container can then read the password hashes, even without the capability.

> **Note:** replacing `sudo -u runner` with `runuser` or `USER runner` is not enough. The build passes, but `sudo` still fails in workflow steps.
