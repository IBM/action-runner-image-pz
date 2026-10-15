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

The image is tagged `runner:<os>.<version>`, for example `runner:ubuntu.26.04` (Podman shows it as `localhost/runner:ubuntu.26.04`). It contains the GitHub Actions runner, built from source for the host architecture with `patches/runner-sdk8-<arch>.patch`, installed in `/opt/runner-cache` and owned by the `runner` user. OCI images always use the minimal setup: the runner plus the tools needed to build it (git, curl, sudo, the .NET 8 SDK and compilers).

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
