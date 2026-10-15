#!/bin/bash -e
################################################################################
##  File:  install-docker.sh
##  Desc:  Install docker onto the image
##  Supply chain security: amazon-ecr-credential-helper - dynamic checksum validation
################################################################################

# Source the helpers for use with the script
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/install.sh
source "$HELPER_SCRIPTS"/os.sh

if is_x64; then
  docker_arch="amd64"
elif is_arm64; then
  docker_arch="arm64"
elif is_ppc64le; then
  docker_arch="ppc64el"
elif is_s390x; then
  docker_arch="s390x"
else
  echo "Unsupported architecture"
  exit 1
fi

REPO_URL="https://download.docker.com/linux/ubuntu"
GPG_KEY="/usr/share/keyrings/docker.gpg"
REPO_PATH="/etc/apt/sources.list.d/docker.list"
os_codename=$(lsb_release -cs)

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o $GPG_KEY
echo "deb [arch=$docker_arch signed-by=$GPG_KEY] $REPO_URL ${os_codename} stable" > $REPO_PATH
update_dpkgs

# Install docker components which available via apt-get
# Using toolsets keep installation order to install dependencies before the package in order to control versions

components=$(get_toolset_value '.docker.components[] .package')
for package in $components; do
    version=$(get_toolset_value ".docker.components[] | select(.package == \"$package\") | .version")
    if [[ $version == "latest" ]]; then
        install_dpkgs --no-install-recommends "$package"
    else
        version_string=$(apt-cache madison "$package" | grep "$version" | grep "$os_codename" | awk '{ print $3 }' | head -1)
        
        if [[ -z "$version_string" ]]; then
            echo "Error: Could not find version $version for package $package on $os_codename"
            exit 1
        fi
        
        install_dpkgs --no-install-recommends "${package}=${version_string}"
    fi
done

# Install plugins that are best installed from the GitHub repository
# Be aware that `url` built from github repo name and plugin name because of current repo naming for those plugins

case "$docker_arch" in
    amd64) arch_pattern="amd64|x86_64" ;;
    arm64) arch_pattern="arm64|aarch64" ;;
    ppc64el) arch_pattern="ppc64le" ;;
    s390x) arch_pattern="s390x" ;;
esac

plugins=$(get_toolset_value '.docker.plugins[] .plugin')
for plugin in $plugins; do
    version=$(get_toolset_value ".docker.plugins[] | select(.plugin == \"$plugin\") | .version")
    filter=$(get_toolset_value ".docker.plugins[] | select(.plugin == \"$plugin\") | .asset_map[\"$ARCH\"]")

    # Toolset asset filters are architecture-specific strings (e.g. "linux-arm64"), unlike the
    # engine arch above, which is machine-detected. Fail fast instead of silently installing a
    # plugin binary that doesn't match the host, which fails at runtime with "exec format error".
    if ! [[ "$filter" =~ ($arch_pattern) ]]; then
        echo "Error: host architecture is '$docker_arch' but toolset plugin '$plugin' targets asset '$filter'." >&2
        echo "This build definition/toolset combination doesn't match the host it's running on." >&2
        exit 1
    fi

    url=$(resolve_github_release_asset_url "docker/$plugin" "endswith(\"$filter\")" "$version")
    binary_path=$(download_with_retry "$url" "/tmp/docker-$plugin")
    mkdir -pv "/usr/libexec/docker/cli-plugins"
    install "$binary_path" "/usr/libexec/docker/cli-plugins/docker-$plugin"
done

# docker from official repo introduced different GID generation: https://github.com/actions/runner-images/issues/8157
gid=$(cut -d ":" -f 3 /etc/group | grep "^1..$" | sort -n | tail -n 1 | awk '{ print $1+1 }')
groupmod -g "$gid" docker

[ -f /usr/share/bash-completion/completions/docker ] && \
    cp -f /usr/share/bash-completion/completions/docker /etc/bash_completion.d/

[ ! -d /etc/docker ] && mkdir /etc/docker
cat << EOF > /etc/docker/daemon.json
{
  "data-root": "/var/lib/docker",
  "log-driver": "local",
  "log-opts": {
    "max-size": "100m",
    "max-file": "6",
    "compress": "true",
    "mode": "non-blocking",
    "max-buffer-size": "4m"
  },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    },
    "nproc": {
      "Name": "nproc",
      "Hard": 65536,
      "Soft": 65536
    }
  },
  "live-restore": true,
  "max-concurrent-downloads": 20,
  "max-concurrent-uploads": 10,
  "storage-driver": "overlay2",
  "exec-opts": [
    "native.cgroupdriver=systemd"
  ]
}
EOF

# On ppc64le, set the Docker bridge MTU to 1460 to match the host NIC
# (pi_network_mtu = 1460). The default 1500 causes the PowerVS SDN to reset TCP
# connections mid-transfer on large downloads. Not needed on x86_64 or s390x.
if is_ppc64le; then
    tmp=$(mktemp)
    jq '. + {"mtu": 1460}' /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json
    chmod 644 /etc/docker/daemon.json
fi

# Create systemd-tmpfiles configuration for Docker
cat <<EOF | sudo tee /etc/tmpfiles.d/docker.conf
L /run/docker.sock - - - - root docker 0770
EOF

# Reload systemd-tmpfiles to apply the new configuration
systemd-tmpfiles --create /etc/tmpfiles.d/docker.conf

# Enable docker.service
systemctl is-active --quiet docker.service || systemctl start docker.service
systemctl is-enabled --quiet docker.service || systemctl enable docker.service

# Docker daemon takes time to come up after installing
sleep 10
docker info

if ! is_ppc64le && ! is_s390x; then
    if ! is_ubuntu22; then
        # Pull Dependabot docker image
        docker pull ghcr.io/dependabot/dependabot-updater-core:latest

        # Pull AW docker images
        docker pull ghcr.io/github/gh-aw-mcpg:latest
        docker pull ghcr.io/github/gh-aw-firewall/agent:latest
        docker pull ghcr.io/github/gh-aw-firewall/api-proxy:latest
        docker pull ghcr.io/github/gh-aw-firewall/squid:latest
        docker pull ghcr.io/github/github-mcp-server:latest
    fi

    # Download amazon-ecr-credential-helper
    aws_latest_release_url="https://api.github.com/repos/awslabs/amazon-ecr-credential-helper/releases/latest"
    aws_helper_url=$(curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} "${aws_latest_release_url}" | jq -r '.body' | awk -F'[()]' '/linux-'"${docker_arch}"'/ {print $2}')
    aws_helper_binary_path=$(download_with_retry "$aws_helper_url")

    # Supply chain security - amazon-ecr-credential-helper
    aws_helper_external_hash=$(get_checksum_from_url "${aws_helper_url}.sha256" "docker-credential-ecr-login" "SHA256")
    use_checksum_comparison "$aws_helper_binary_path" "$aws_helper_external_hash"

    # Install amazon-ecr-credential-helper
    install "$aws_helper_binary_path" "/usr/bin/docker-credential-ecr-login"
fi

# Cleanup custom repositories
rm $GPG_KEY
rm $REPO_PATH
