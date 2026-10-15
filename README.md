# GitHub Action Runner Image for IBM Power (ppc64le) and IBM Z (s390x)

GitHub Actions Runner Image Builder for LXD, Incus, Docker, Podman and VMs

Formerly known as GapLib, this repo is a robust collection of setup scripts for configuring custom GitHub Actions runners. These scripts are designed to seamlessly adapt to updates in `actions/runner`, ensuring compatibility and optimal performance across diverse environments, including **VM (host machine)**, **LXD Containers**, **LXD VMs**, **Incus Containers**, **Incus VMs**, **Docker**, and **Podman**.

This repository also includes source code to create VM images for GitHub-hosted runners widely used in Actions workflows. The software installed by a **Complete** setup follows the upstream [actions/runner-images](https://github.com/actions/runner-images) build templates in `images/ubuntu/templates/`, adapted for ppc64le and s390x.


## **Table of Contents**

- [Overview](#overview)
    - [Supported Environments](#supported-environments)
    - [Supported Architectures](#supported-architectures)
    - [Supported Operating Systems](#supported-operating-systems)
- [Scripts](#scripts)
    - [run.sh](#runsh)
    - [Key Features](#key-features)
- [Usage](#usage)
    - [Interactive](#interactive)
    - [Non-interactive](#non-interactive)
- [Upgrading Runner Binary (VM/Host Machine)](#upgrading-runner-binary-vmhost-machine)
- [Setup Options](#setup-options)
    - [Main Menu](#main-menu)
    - [OS and Version Selection](#os-and-version-selection)
    - [Minimal or Complete Setup](#minimal-or-complete-setup)
    - [Incus Base Image Source](#incus-base-image-source)
    - [Worker Category](#worker-category)
    - [Unsupported Architectures](#unsupported-architectures)
- [Software on ppc64le and s390x](#software-on-ppc64le-and-s390x)
- [Further Documentation](#further-documentation)
- [Requirements](#requirements)

---

## **Overview**

### **Supported Environments**

This runner image supports multiple environments on IBM hardware for a seamless runner setup:

- **VM (host machine)**: Direct setup on virtual or host machines.
- **LXD Container**: Lightweight, system container-based virtualization.
- **LXD VM**: Full virtual machines managed via LXD for enhanced isolation.
- **Incus Container**: System containers managed by [Incus](https://linuxcontainers.org/incus/), the community fork of LXD.
- **Incus VM**: Full virtual machines managed by Incus.
- **Docker**: Industry-standard containerization platform.
- **Podman**: Docker-compatible, daemonless container management.

### **Supported Architectures**

- **ppc64le**
- **s390x**
- **x86_64**

### **Supported Operating Systems**

| Environment | Ubuntu 22.04 | Ubuntu 24.04 | Ubuntu 26.04 | CentOS / AlmaLinux 9 |
|---|---|---|---|---|
| VM (host machine) | ✓ | ✓ | ✓ | ✓ (minimal only) |
| LXD Container / LXD VM | ✓ | ✓ | ✓ | – |
| Incus Container / Incus VM | ✓ ¹ | ✓ | ✓ | – |
| Docker / Podman | ✓ | ✓ | ✓ | ✓ |

¹ Ubuntu 22.04 **ppc64le Incus VMs** cannot be built from **Incus Images** (distrobuilder): GRUB 2.06 in 22.04 does not install in the distrobuilder chroot. Use 24.04/26.04, or the **Cloud Images** source.

---

## **Scripts**

### **run.sh**

`run.sh` is the primary script for setting up GitHub Actions runners. It provides an interactive, menu-driven interface for selecting environments, operating systems, versions, and setup types, and then calls the matching script in `scripts/`:

| Environment | Script |
|---|---|
| VM (host machine) | `scripts/vm.sh` |
| LXD Container | `scripts/lxd_container.sh` |
| LXD VM | `scripts/lxd_vm.sh` |
| Incus Container | `scripts/incus_container.sh` |
| Incus VM | `scripts/incus_vm.sh` |
| Docker | `scripts/docker.sh` |
| Podman | `scripts/podman.sh` |

### **Key Features**

- **Interactive Menu**: Guides users through setup options (VM, LXD Container, LXD VM, Incus Container, Incus VM, Docker, or Podman).
- **Architecture Detection**: Ensures compatibility with supported architectures.
- **Custom OS and Version Selection**: Allows users to tailor setup to specific environments.
- **Setup Type Options**: Supports **Minimal** (basic setup) and **Complete** (full setup) configurations.
- **Idempotent image builds**: LXD and Incus images are tagged with the build commit, OS, version and setup type; a rebuild is skipped when a matching image already exists.

---

## **Usage**

### **Interactive**

1. Clone the repository and change into it (the scripts expect to run from the repository root).
2. Execute the setup script:

    ```bash
    bash run.sh
    ```

3. Follow the prompts to:
    - Select your environment (**VM**, **LXD Container**, **LXD VM**, **Incus Container**, **Incus VM**, **Docker**, or **Podman**).
    - Choose your OS and version.
    - Specify the setup type (**Minimal** or **Complete**).
    - For Incus, choose the base image source (**Cloud Images** or **Incus Images**).
    - For LXD and Incus, choose the worker category.

Set `GITHUB_TOKEN` in the environment to avoid GitHub API rate limits during the build; `run.sh` passes it through to the build scripts.

### **Non-interactive**

Every environment script can also be called directly (this is what `run.sh` does):

```bash
sudo ./scripts/<environment>.sh <os> <version> [worker_type] [worker_cpu] [setup_type] [flags]
```

| Argument | Description |
|---|---|
| `os` | `ubuntu` or `centos` |
| `version` | `22.04`, `24.04`, `26.04` (Ubuntu) or `9` (CentOS) |
| `worker_type` | Optional image-name suffix, e.g. `-2xlarge` (pass `""` to skip) |
| `worker_cpu` | Optional image-name suffix, e.g. `-p10` (pass `""` to skip) |
| `setup_type` | `minimal` (default) or `complete` |

Example, a complete Ubuntu 26.04 Incus container from the Ubuntu cloud image:

```bash
sudo ./scripts/incus_container.sh ubuntu 26.04 "" "" complete --use-cloud-img
```

The optional flags (`--skip-snap-lxd`, `--use-incus-img`, `--delete-incus-img`, …) are listed in the [LXD](docs/LXD_IMAGE_Used_by_GitHub_Actions_Runner.md#build-flags) and [Incus](docs/Incus_Image_Used_by_GitHub_Actions_Runner.md#build-flags) guides.

---

## **Upgrading Runner Binary (VM/Host Machine)**

**This upgrade feature is specifically designed for VM (host machine) setups.** For container-based, LXD-based or Incus-based deployments, please rebuild the image instead.

If you need to upgrade the GitHub Actions runner binary to the latest version on your VM or host machine, simply rerun the setup script:

```bash
bash run.sh
```

The script will automatically:
- Detect the existing runner installation on the host
- Download and install the latest runner binary
- Fix any configuration issues
- Preserve your existing runner registration and settings

**Note**: For VM (host machine) setups, snap and LXD installation are disabled by default to avoid conflicts. The upgrade process will maintain this configuration.

---

## **Setup Options**

### **Main Menu**

The script provides the following main options:
```
1) VM (host machine)
2) LXD Container
3) LXD VM
4) Incus Container
5) Incus VM
6) Docker
7) Podman
8) Exit
```

Select an option to proceed with the setup.

### **OS and Version Selection**

- **VM (host machine)**: the OS and version are detected from `/etc/os-release` of the host.
- **LXD / Incus**: Ubuntu `26.04`, `24.04` or `22.04`.
- **Docker / Podman**: Ubuntu `26.04`, `24.04`, `22.04`, or CentOS/AlmaLinux `9`.

### **Minimal or Complete Setup**

- **Minimal Setup**: Installs only the essential components: the runner, .NET, git, git-lfs, GitHub CLI, Python, zstd and the actions cache. Docker, pipx packages and Homebrew are installed by every setup, and snap/LXD inside the image unless `--skip-snap-lxd` is passed.
- **Complete Setup**: Performs a full installation that mirrors the upstream runner-images template for the selected Ubuntu version (`images/ubuntu/templates/build.ubuntu-<version>.pkr.hcl`).

CentOS, Docker and Podman builds always use the minimal setup.

### **Incus Base Image Source**

Incus builds start from a base image that is imported into Incus once and reused:

| Source | Flag | x86_64 | ppc64le / s390x |
|---|---|---|---|
| **Cloud Images** (default) | `--use-cloud-img` | [Ubuntu cloud images](https://cloud-images.ubuntu.com/releases/) | Ubuntu cloud images |
| **Incus Images** | `--use-incus-img` | Containers: Incus image server (`images:ubuntu/<version>`); VMs: built with distrobuilder | Built locally with distrobuilder |

### **Worker Category**

LXD and Incus builds ask for a worker category (`default`, `2xlarge`, `4xlarge`). The choice, plus `-p10` on POWER10 hosts, is appended to the image name, for example `ubuntu-26.04-ppc64le-2xlarge-p10`.

### **Unsupported Architectures**

If the script encounters an unsupported architecture, it will provide these options:

```
1. Return to main menu
2. Exit
```

---

## **Software on ppc64le and s390x**

A **Complete** setup runs the same scripts on every architecture. Tools that have no ppc64le/s390x builds are skipped on those architectures, and a few are installed differently:

| Behaviour on ppc64le / s390x | Tools |
|---|---|
| Skipped (no ppc64le/s390x builds published) | Agentic Workflow Firewall (AWF), Alibaba Cloud CLI, Android SDK, AWS CLI/SAM, AzCopy, Azure CLI, Azure DevOps CLI, Bazel, Bicep, CodeQL bundle, GitHub Copilot CLI, Firefox, GitHub CLI, Google Chrome, Google Cloud CLI, Haskell, Heroku, Homebrew, Microsoft Edge, MS SQL tools, PowerShell, Pulumi, R, SqlPackage, Swift, vcpkg |
| Installed from the Ubuntu archive instead | CMake, Ninja, PyPy (ppc64le), Ruby (no toolcache versions), .NET SDK 8.0 (from `ppa:dotnet/backports` on 26.04) |
| ppc64le only (skipped on s390x) | Julia, Packer, Terraform |
| Built from source | GitHub Actions runner (patched with `patches/runner-sdk8-<arch>.patch`), kind |

---

## **Further Documentation**

- [LXD image used by the GitHub Actions runner](docs/LXD_IMAGE_Used_by_GitHub_Actions_Runner.md)
- [Incus image used by the GitHub Actions runner](docs/Incus_Image_Used_by_GitHub_Actions_Runner.md)
- [OCI (Docker/Podman) image used as a self-hosted runner](docs/OCI_Image_Used_as_a_Self-Hosted_GitHub_Actions_Runner.md)

---

## **Requirements**

- **Bash Shell**: Required to execute the scripts.
- **Sudo Privileges**: Necessary for certain setup tasks depending on the chosen environment.
- **LXD / Incus / Docker / Podman**: Installed automatically when missing (LXD via snap, Incus built from source, Docker via the host OS installer, Podman on CentOS hosts only).

---

# Archived repo

This repo was previously hosted here: https://github.com/ppc64le/gaplib
