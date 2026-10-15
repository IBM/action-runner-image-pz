#!/bin/bash -e
################################################################################
##  File:  install-kubernetes-tools.sh
##  Desc:  Installs kubectl, helm, kustomize
##  Supply chain security: KIND, minikube, kustomize - checksum validation
################################################################################

# Source the helpers for use with the script
# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/install.sh
source "$HELPER_SCRIPTS"/os.sh

if is_x64; then
  tools_arch="amd64"
elif is_arm64; then
  tools_arch="arm64"
elif is_ppc64le || is_s390x; then
  tools_arch="$ARCH"
else
  echo "Unsupported architecture"
  exit 1
fi

if is_ppc64le || is_s390x; then
    export version="latest"
    install_dpkgs golang
    sudo go install sigs.k8s.io/kind@$version # v0.22.0
    # shellcheck disable=SC2046
    sudo cp $(sudo go env GOPATH)/bin/kind /usr/local/bin/
    kind version
else
    # Download KIND
    kind_url=$(resolve_github_release_asset_url "kubernetes-sigs/kind" "endswith(\"kind-linux-${tools_arch}\")" "latest")
    kind_binary_path=$(download_with_retry "${kind_url}")

    # Supply chain security - KIND
    kind_external_hash=$(get_checksum_from_url "${kind_url}.sha256sum" "kind-linux-${tools_arch}" "SHA256")
    use_checksum_comparison "${kind_binary_path}" "${kind_external_hash}"

    # Install KIND
    install "${kind_binary_path}" /usr/local/bin/kind
fi

## Install kubectl

# Ensure keyrings directory exists only if it doesn't already
[ -d /etc/apt/keyrings ] || sudo mkdir -p -m 755 /etc/apt/keyrings
    
kubectl_minor_version=$(curl -fsSL --retry 5 --retry-delay 10 "https://dl.k8s.io/release/stable.txt" | cut -d'.' -f1,2 )
    
# Download and validate GPG key
key_url="https://pkgs.k8s.io/core:/stable:/$kubectl_minor_version/deb/Release.key"
if curl -fsSL --retry 5 --retry-delay 10 -A "Mozilla/5.0" "$key_url" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg; then
    echo "Key downloaded and stored successfully."
else
    echo "Failed to download valid GPG key from: $key_url"
    exit 1
fi
    
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/'"$kubectl_minor_version"'/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
update_dpkgs
install_dpkgs kubectl
rm -f /etc/apt/sources.list.d/kubernetes.list
    
# Install Helm
if is_ubuntu26; then
    helm_installer_script="get-helm-4"
else
    helm_installer_script="get-helm-3"
fi
curl -fsSL "https://raw.githubusercontent.com/helm/helm/master/scripts/${helm_installer_script}" | bash

# Download and install minikube
minikube_version="latest"
minikube_binary_path=$(download_with_retry "https://storage.googleapis.com/minikube/releases/${minikube_version}/minikube-linux-${tools_arch}")

# Supply chain security - Minikube
minikube_hash=$(get_checksum_from_github_release "kubernetes/minikube" "linux-${tools_arch}" "${minikube_version}" "SHA256")
use_checksum_comparison "${minikube_binary_path}" "${minikube_hash}"
    
install "${minikube_binary_path}" /usr/local/bin/minikube
    
# Install kustomize
exact_latest_url=$(curl -fsSL --retry 5 --retry-delay 10 -o /dev/null -w "%{url_effective}" "https://github.com/kubernetes-sigs/kustomize/releases/latest")
kustomize_release_tag=${exact_latest_url#*"/releases/tag/"}
kustomize_version=${kustomize_release_tag##*/}
kustomize_archive_name="kustomize_${kustomize_version}_linux_${tools_arch}.tar.gz"
kustomize_archive_path=$(download_with_retry "https://github.com/kubernetes-sigs/kustomize/releases/download/${kustomize_release_tag}/${kustomize_archive_name}")

# Supply chain security - Kustomize
kustomize_hash=$(get_checksum_from_url "https://github.com/kubernetes-sigs/kustomize/releases/download/${kustomize_release_tag}/checksums.txt" "$kustomize_archive_name" "SHA256")
use_checksum_comparison "$kustomize_archive_path" "$kustomize_hash"

tmp_dir=$(mktemp -d)
tar -xzf "$kustomize_archive_path" -C "$tmp_dir"
mv "$tmp_dir/kustomize" /usr/local/bin
rm -rf "$tmp_dir" "$kustomize_archive_path"
