#!/bin/bash -e
################################################################################
##  File:  configure-image-data.sh
##  Desc:  Create a file with image data and documentation links
################################################################################

# shellcheck disable=SC2153
imagedata_file=$IMAGEDATA_FILE
image_version=$IMAGE_VERSION
image_version_major=${image_version/.*/}
image_version_minor=$(echo "$image_version" | cut -d "." -f 2)
os_name=$(lsb_release -ds | sed "s/ /\\\n/g")
os_version=$(lsb_release -rs)
image_label="ubuntu-${os_version}"
version_major=${os_version/.*/}
# shellcheck disable=SC2034
version_wo_dot=${os_version/./}

github_url="https://github.com/IBM/action-runner-image-pz/blob/main/images"
software_url="${github_url}/ubuntu/toolsets/toolset-${image_version_major}${image_version_minor}.json"
releaseUrl="https://github.com/IBM/action-runner-image-pz/releases/tag/ubuntu${version_major}%2F${image_version_major}.${image_version_minor}"

## Following are custom values for P/Z self-hosted runners
## todo: extend this with CI build number
runner_image_version="$(date  +%Y%m%d)"
image_build_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
image_builder_id=$(cat /etc/machine-id 2>/dev/null || hostname -s 2>/dev/null)

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