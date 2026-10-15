#!/bin/bash -e
################################################################################
##  File:  install-terraform.sh
##  Desc:  Install terraform
################################################################################

# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/install.sh
source "$HELPER_SCRIPTS"/os.sh

if is_x64; then
  terraform_arch="amd64"
elif is_arm64; then
  terraform_arch="arm64"
elif is_ppc64le; then
  wget -O /usr/local/bin/terraform https://ftp2.osuosl.org/pub/ppc64el/terraform/terraform-1.4.6
  chmod +x /usr/local/bin/terraform
  exit 0
elif is_s390x; then
  echo "No actions defined for $ARCH architecture."
  exit 0
else
  echo "Unsupported architecture"
  exit 1
fi

# Install Terraform
download_url=$(curl -fsSL https://api.releases.hashicorp.com/v1/releases/terraform/latest | jq -r ".builds[] | select((.arch==\"$terraform_arch\") and (.os==\"linux\")).url")
archive_path=$(download_with_retry "${download_url}")
unzip -qq "$archive_path" -d /usr/local/bin


