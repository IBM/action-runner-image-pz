#!/bin/bash -e
################################################################################
##  File:  configure-image-data.sh
##  Desc:  Create a file with image data and documentation links
################################################################################
# shellcheck disable=SC2153
imagedata_file="$IMAGEDATA_FILE"
image_version="$IMAGE_VERSION"
image_version_major=${image_version/.*/} # Extract the major version
image_version_minor=$(echo "$image_version" | cut -d "." -f 2) # Extract the minor version

# Determine OS name and version for CentOS
# shellcheck disable=SC2002
os_name=$(cat /etc/redhat-release | sed "s/ /\\\n/g") # Get OS name
# shellcheck disable=SC1083
os_version=$(rpm -E %{rhel}) # Get CentOS version
image_label="centos-${os_version}" # Set image label

# Construct documentation and release URLs
github_url="https://github.com/IBM/action-runner-image-pz/blob/main/images"
software_url="${github_url}/centos/toolsets/toolset-${image_version_major}${image_version_minor}.json"
releaseUrl="https://github.com/actions/runner-images/releases/tag/centos${os_version}%2F${image_version_major}.${image_version_minor}"

runner_image_version="$(date  +%Y%m%d)"
image_build_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
image_builder_id=$(cat /etc/machine-id 2>/dev/null || hostname -s 2>/dev/null)

# Create the image data JSON file
cat <<EOF > "$imagedata_file"
[
  {
    "group": "Runner Image Provisioner",
    "detail": "Commit: ${BUILD_SHA}\nBuild Date: ${image_build_date}\nBuilder ID: ${image_builder_id}"
  },
  {
    "group": "Operating System",
    "detail": "${os_name}"
  },
  {
    "group": "Runner Image",
    "detail": "Image: ${image_label}\nVersion: ${runner_image_version}\nIncluded Software: ${software_url}\nImage Release: ${releaseUrl}"
  }
]
EOF
