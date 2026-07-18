#!/bin/bash

HELPERS_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/helpers"

# shellcheck disable=SC1091
source "${HELPERS_DIR}"/setup_vars.sh
# shellcheck disable=SC1091
source "${HELPERS_DIR}"/setup_img.sh
# shellcheck disable=SC1091
source "${HELPERS_DIR}"/run_script.sh

msg() {
    # shellcheck disable=SC2046
    echo $(date +"%Y-%m-%dT%H:%M:%S%:z") "$*"
}

ensure_incus() {
    echo "Ensuring Incus is installed and configured..."
    
    # Check if we should skip installation
    if [[ "${SKIP_SNAP_LXD}" == "true" ]]; then
        echo "Skipping Incus installation (--skip-snap-lxd flag set)"
    else
        # Run install-incus.sh - it handles:
        # 1. Installation (if not installed)
        # 2. Configuration (if not configured)
        # 3. Base image import (at the end)
        # The script has built-in idempotency checks
        run_script "${HOST_INSTALLER_SCRIPT_FOLDER}/install-incus.sh" "HELPER_SCRIPTS" "INSTALLER_SCRIPT_FOLDER" "ARCH"
    fi
    
    # Verify Incus is working
    if ! command -v incus &> /dev/null; then
        echo "Error: Incus is not installed."
        exit 1
    fi
    
    # Check if incus daemon is running and ready
    if ! incus admin waitready --timeout=5 >/dev/null 2>&1; then
        echo "Error: Incus daemon is not responding."
        echo "Please check if incusd is running: pgrep -x incusd"
        exit 1
    fi
    
    echo "Incus is ready."
}

# shellcheck disable=SC2329
# shellcheck disable=SC2317
cleanup_builder() {
  local vm_name="$1"
  
  # If Debug mode is on, keep the VM for inspection
  if [[ "${INCUS_DEBUG:-false}" == "true" ]]; then
     msg "Debug mode enabled. VM ${vm_name} preserved."
     return
  fi
  msg "Executing cleanup for VM ${vm_name}..."
  if incus info "${vm_name}" &>/dev/null; then
    msg "Stopping VM ${vm_name}..."
    # If the VM is ephemeral, stopping it deletes it.
    # If not, we force delete to be safe.
    incus delete -f "${vm_name}" 2>/dev/null || true
  else
    msg "VM ${vm_name} already gone."
  fi
}

cleanup_old_image() {
    local IMAGE_ALIAS="$1"
    msg "Checking for existing alias ${IMAGE_ALIAS}..."
    if incus image info "${IMAGE_ALIAS}" >/dev/null 2>&1; then
        # Extract fingerprint
        OLD_FINGERPRINT=$(incus image info "${IMAGE_ALIAS}" | awk '/^Fingerprint:/ {print $2; exit}')
        
        if [[ -n "${OLD_FINGERPRINT}" ]]; then
            msg "Deleting old image ${OLD_FINGERPRINT} to make room for alias ${IMAGE_ALIAS}..."
            incus image delete "${OLD_FINGERPRINT}" || true
        fi
    fi
}

wait_for_vm() {
  local vm_name="$1"
  msg "Waiting for ${vm_name} systemd to initialize..."

  for ((i = 0; i < 90; i++)); do
      # Check if filesystem is ready
      local CHECK_FS
      CHECK_FS=$(incus exec "${vm_name}" -- stat "${BUILD_HOME}" 2>/dev/null || true)
      
      # Check if Systemd/DBus is actually ready
      local CHECK_SYSTEMD
      CHECK_SYSTEMD=$(incus exec "${vm_name}" -- systemctl is-system-running 2>/dev/null || true)

      # Proceed if FS is ready AND systemd is 'running' or 'degraded'
      if [ -n "${CHECK_FS}" ] && [[ "${CHECK_SYSTEMD}" == "running" || "${CHECK_SYSTEMD}" == "degraded" ]]; then
          msg "VM ${vm_name} is fully operational (State: ${CHECK_SYSTEMD})."
          return 0
      fi
      
      if [ $i -eq 89 ]; then
          msg "Timeout waiting for systemd. Last state: ${CHECK_SYSTEMD}"
          return 1
      fi
      sleep 2s
  done
}

# Configure CPU resources for an Incus VM
# Parameters:
#   $1 - vm_name: Name of the Incus VM
#   $2 - target_cpu_count: Desired number of CPUs to allocate (default: 4)
configure_cpu_resources() {
  local vm_name="$1"
  local target_cpu_count="${2:-4}"
  
  # Validate parameters
  if [[ -z "$vm_name" ]]; then
    echo "Error: VM name is required for CPU configuration."
    return 1
  fi
  
  if ! [[ "$target_cpu_count" =~ ^[0-9]+$ ]] || [[ "$target_cpu_count" -lt 1 ]]; then
    echo "Error: Invalid CPU count. Must be a positive integer."
    return 1
  fi
  
  msg "Configuring CPU resources for VM '${vm_name}'..."
  
  # Get all host CPUs (0 to N-1)
  local all_cpus
  all_cpus=$(seq 0 $(($(nproc) - 1)))
  
  # Extract explicitly pinned CPUs from RUNNING instances
  local used_cpus
  used_cpus=$(incus list -c n status=running --format csv | xargs -I {} incus config get {} limits.cpu 2>/dev/null | grep ',' | tr ',' '\n' | sort -u)
  
  # Determine available_cpus
  # If used_cpus is empty, grep -vFx might behave unexpectedly, so we handle it explicitly
  local available_cpus
  if [[ -z "$used_cpus" ]]; then
    available_cpus="$all_cpus"
  else
    available_cpus=$(echo "$all_cpus" | grep -vFx -f <(echo "$used_cpus"))
  fi
  
  # Count how many are actually available
  local available_count
  if [[ -z "$available_cpus" ]]; then
    available_count=0
  else
    available_count=$(echo "$available_cpus" | wc -l)
  fi
  
  # Strict check: Must have > 0 CPUs available
  if [[ "$available_count" -eq 0 ]]; then
    echo "Error: No CPUs available to allocate."
    return 1
  fi
  
  # Calculate how many to actually allocate (cannot exceed available_count)
  local allocate_count
  if [[ "$target_cpu_count" -gt "$available_count" ]]; then
    allocate_count="$available_count"
    echo "Warning: Requested $target_cpu_count CPUs, but only $available_count are available. Allocating $available_count."
  else
    allocate_count="$target_cpu_count"
  fi
  
  # Extract the top X CPUs and convert to a comma-separated string
  local cpus_to_allocate
  cpus_to_allocate=$(echo "$available_cpus" | head -n "$allocate_count" | paste -sd, -)
  
  # Validate that we have CPUs to allocate
  if [[ -z "$cpus_to_allocate" ]]; then
    echo "Error: Failed to determine CPUs to allocate."
    return 1
  fi
  
  # Print the result and apply to Incus
  echo "Successfully found available CPUs."
  echo "Allocating CPUs: $cpus_to_allocate to '${vm_name}'"
  
  if ! incus config set "${vm_name}" limits.cpu "$cpus_to_allocate"; then
    echo "Error: Failed to set CPU limits for VM '${vm_name}'."
    return 1
  fi
  
  msg "CPU configuration completed successfully."
  return 0
}

# Configure memory resources for an Incus VM
# Parameters:
#   $1 - vm_name: Name of the Incus VM
#   $2 - target_memory_mb: Desired memory allocation in MiB (default: 4096)
#   $3 - host_buffer_mb: Safety buffer to leave for host OS in MiB (default: 512)
configure_memory_resources() {
  local vm_name="$1"
  local target_memory_mb="${2:-4096}"
  local host_buffer_mb="${3:-512}"
  
  # Validate parameters
  if [[ -z "$vm_name" ]]; then
    echo "Error: VM name is required for memory configuration."
    return 1
  fi
  
  if ! [[ "$target_memory_mb" =~ ^[0-9]+$ ]] || [[ "$target_memory_mb" -lt 1 ]]; then
    echo "Error: Invalid target memory. Must be a positive integer (MiB)."
    return 1
  fi
  
  if ! [[ "$host_buffer_mb" =~ ^[0-9]+$ ]] || [[ "$host_buffer_mb" -lt 0 ]]; then
    echo "Error: Invalid host buffer. Must be a non-negative integer (MiB)."
    return 1
  fi
  
  msg "Configuring memory resources for VM '${vm_name}'..."
  
  # Get currently available memory directly from the kernel (in KB, convert to MiB)
  local avail_kb
  avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
  
  if [[ -z "$avail_kb" ]] || ! [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
    echo "Error: Failed to read available memory from /proc/meminfo."
    return 1
  fi
  
  local avail_mb=$((avail_kb / 1024))
  
  # Calculate safe available memory (Total Available - Host Buffer)
  local safe_mb=$((avail_mb - host_buffer_mb))
  
  # Strict check: Ensure we actually have memory to give
  if [[ "$safe_mb" -le 0 ]]; then
    echo "Error: Host is critically low on memory. Cannot allocate."
    echo "Available: ${avail_mb}MiB, Buffer: ${host_buffer_mb}MiB, Safe: ${safe_mb}MiB"
    return 1
  fi
  
  # Determine how much to actually allocate
  local allocate_mb
  if [[ "$target_memory_mb" -gt "$safe_mb" ]]; then
    allocate_mb="$safe_mb"
    echo "Warning: Requested ${target_memory_mb}MiB, but only ${safe_mb}MiB is safely available."
    echo "Throttling down to ${safe_mb}MiB..."
  else
    allocate_mb="$target_memory_mb"
  fi
  
  # Align memory to 256 MiB boundary for QEMU compatibility (required for ppc64le)
  # This prevents errors like: "qemu-system-ppc64: Memory size 0xf4200000 is not aligned to 256 MiB"
  local alignment_mb=256
  local aligned_mb=$((allocate_mb / alignment_mb * alignment_mb))
  
  if [[ "$aligned_mb" -ne "$allocate_mb" ]]; then
    echo "Note: Aligning memory from ${allocate_mb}MiB to ${aligned_mb}MiB (256 MiB boundary for QEMU compatibility)"
    allocate_mb="$aligned_mb"
  fi
  
  # Ensure we have at least 256 MiB after alignment
  if [[ "$allocate_mb" -lt "$alignment_mb" ]]; then
    echo "Error: After alignment, memory would be less than ${alignment_mb}MiB. Cannot allocate."
    return 1
  fi
  
  # Apply the limit to the VM
  echo "Allocating ${allocate_mb}MiB to '${vm_name}'..."
  
  if ! incus config set "${vm_name}" limits.memory "${allocate_mb}MiB"; then
    echo "Error: Failed to set memory limits for VM '${vm_name}'."
    return 1
  fi
  
  msg "Memory configuration completed successfully."
  return 0
}


build_image() {
  set -e

  local IMAGE_ALIAS="${IMAGE_ALIAS:-${IMAGE_OS}-${IMAGE_VERSION}-${ARCH}${WORKER_TYPE}${WORKER_CPU}}-vm"
  local BUILD_PREREQS_PATH
  BUILD_PREREQS_PATH="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

  # Search for an existing image that matches the strict criteria:
  # (commit, os, version, and setup)
  # We use 'jq' to filter the JSON output of incus image list.
  local EXISTING_IMAGE_JSON
  # shellcheck disable=SC2154
  EXISTING_IMAGE_JSON=$(incus image list --format=json | jq -r --arg commit "${BUILD_SHA}" --arg os "${clean_args[0]}" --arg ver "${clean_args[1]}" --arg setup "${clean_args[4]}" \
    '.[] | select(
        .type == "virtual-machine" and
        .properties["properties.build.commit"] == $commit and 
        .properties["properties.build.os"] == $os and 
        .properties["properties.build.version"] == $ver and 
        .properties["properties.build.setup"] == $setup
    )')

  # Check if we found a match
  if [[ -n "$EXISTING_IMAGE_JSON" ]]; then
    echo "Idempotency Check: Found existing image matching Commit, OS, Version, and Setup."

    local FINGERPRINT
    FINGERPRINT=$(echo "$EXISTING_IMAGE_JSON" | jq -r '.fingerprint')

    # Check if the specific alias we want is already assigned to this image
    local ALIAS_MATCH
    ALIAS_MATCH=$(echo "$EXISTING_IMAGE_JSON" | jq -r --arg alias "${IMAGE_ALIAS}" \
        '.aliases[]? | select(.name == $alias) | .name')

    if [[ -z "$ALIAS_MATCH" ]]; then
        echo "Alias '${IMAGE_ALIAS}' does not exist for this image. Creating it now..."
        # Create the alias for the old image
        incus image alias create "${IMAGE_ALIAS}" "${FINGERPRINT}"
    else
        echo "Alias '${IMAGE_ALIAS}' already exists on the image. Nothing to do."
    fi

    echo "Skipping build."
    return 0
  fi

  if [[ "${DELETE_INCUS_IMG}" == "true" ]]; then
      msg "Delete flag detected. Attempting to delete existing image with alias ${IMAGE_ALIAS} before building."
      cleanup_old_image "${IMAGE_ALIAS}"
  fi

  if [ ! -d "${BUILD_PREREQS_PATH}" ]; then
    msg "Check the BUILD_PREREQS_PATH specification" >&2
    return 3
  fi

  local BUILD_VM
  BUILD_VM="gha-builder-$(date +%s)"

  # Trap INT (Ctrl+C), TERM (kill), and EXIT signals to guarantee cleanup.
  # shellcheck disable=SC2064
  trap "cleanup_builder '${BUILD_VM}'" INT TERM EXIT

  msg "Initializing build VM ${BUILD_VM} from image ${INCUS_VM}..."

  if [[ "${INCUS_DEBUG:-false}" == "true" ]]; then
    # Non-ephemeral for debugging
    incus init "${INCUS_VM}" "${BUILD_VM}" --vm
  else
    # Ephemeral for clean builds
    incus init "${INCUS_VM}" "${BUILD_VM}" --vm --ephemeral
  fi

  # Verify the instance was actually created as a VM, not a container.
  # This can happen silently if the source image is the wrong type.
  local INSTANCE_TYPE
  INSTANCE_TYPE=$(incus info "${BUILD_VM}" | awk '/^Type:/{print $2}')
  if [[ "${INSTANCE_TYPE}" != "virtual-machine" ]]; then
    msg "Error: '${BUILD_VM}' was created as type '${INSTANCE_TYPE}', expected 'virtual-machine'." >&2
    msg "The source image '${INCUS_VM}' may not be a VM image." >&2
    return 1
  fi

  incus ls

  # Configure CPU and memory resources
  configure_cpu_resources "${BUILD_VM}" 4
  configure_memory_resources "${BUILD_VM}" 4096 512

  incus start "${BUILD_VM}"

  wait_for_vm "${BUILD_VM}"
  
  msg "Mapping localhost..."
  incus exec "${BUILD_VM}" -- sh -c "echo '127.0.1.1 ${BUILD_VM}' >> /etc/hosts"

  msg "Checking current partitions..."
  incus exec "${BUILD_VM}" -- cat /proc/partitions
  
  msg "Expanding root partition (partition 2) on /dev/sda..."
  incus exec "${BUILD_VM}" -- growpart /dev/sda 2 || true
  
  msg "Rebooting VM to apply partition changes..."
  incus restart "${BUILD_VM}"
  
  wait_for_vm "${BUILD_VM}"
  
  msg "Resizing root filesystem..."
  incus exec "${BUILD_VM}" -- resize2fs /dev/sda2
  
  msg "Final Disk Usage:"
  incus exec "${BUILD_VM}" -- df -h

  # shellcheck disable=SC2154
  msg "Copy the ${image_folder} contents into the gha-builder"
  incus file push "${image_folder}" "${BUILD_VM}/var/tmp/" --recursive
  incus exec "${BUILD_VM}" ls "${image_folder}"

  msg "Copy the register-runner.sh script into gha-builder"
  incus file push --mode 0755 "${BUILD_PREREQS_PATH}/helpers/register-runner.sh" "${BUILD_VM}/opt/register-runner.sh"

  msg "Copy the /etc/rc.local - required in case podman is used"
  incus file push --mode 0755 "${BUILD_PREREQS_PATH}/assets/rc.local" "${BUILD_VM}/etc/rc.local"

  msg "Copy the gha-service unit file into gha-builder"
  incus file push "${BUILD_PREREQS_PATH}/assets/gha-runner.service" "${BUILD_VM}/etc/systemd/system/gha-runner.service"

  msg "Copy the apt and dpkg overrides into gha-builder - these prevent doc files from being installed"
  incus file push --mode 0644 "${BUILD_PREREQS_PATH}/assets/99synaptics" "${BUILD_VM}/etc/apt/apt.conf.d/99synaptics"
  incus file push --mode 0644 "${BUILD_PREREQS_PATH}/assets/01-nodoc" "${BUILD_VM}/etc/dpkg/dpkg.cfg.d/01-nodoc"

  msg "Running setup_install.sh (as root)"
  # shellcheck disable=SC1073
  # shellcheck disable=SC2154
  if ! incus exec "${BUILD_VM}" --user 0 --group 0 ${GITHUB_TOKEN:+--env GITHUB_TOKEN="${GITHUB_TOKEN}"} -- \
    bash -c 'exec "$@"' _ "${helper_script_folder}/setup_install.sh" "${clean_args[@]}" "${forward_args[@]}"; then

    msg "!!! The installation script inside the VM failed. Triggering cleanup. !!!" >&2
    return 1 # Exit with an error code to trigger the trap and signal failure
  fi

  msg "Setting user runner with sudo privileges"
  incus exec "${BUILD_VM}" --user 0 --group 0 -- bash -c "useradd -c 'Action Runner' -m -s /bin/bash runner && usermod -L runner && echo 'runner ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/runner && chmod 440 /etc/sudoers.d/runner"

  msg "Adding runner user to required groups"
  incus exec "${BUILD_VM}" --user 0 --group 0 -- bash -c "
    # Add to base groups
    usermod -aG adm,users,systemd-journal runner
    # Add to docker group if it exists
    getent group docker >/dev/null && usermod -aG docker runner || true
    # Add to incus group if it exists
    getent group incus >/dev/null && usermod -aG incus runner || true
  "
  
  msg "Running post-generation scripts (as root)"
  incus exec "${BUILD_VM}" --user 0 --group 0 -- bash -c "find /opt/post-generation -mindepth 1 -maxdepth 1 -type f -name '*.sh' -exec bash {} \;"

  # Logic Validation ---
  if [[ "${SKIP_INCUS_PUBLISH}" == "true" ]]; then
      # If Publish is skipped, we must ensure dependent steps are also skipped.
      if [[ "${SKIP_INCUS_IMG_EXPORT}" != "true" ]] || [[ "${SKIP_INCUS_IMG_PRIMER}" != "true" ]]; then
          msg "Warning: Cannot prime/export image if publishing is skipped. Disabling prime/export."
          SKIP_INCUS_IMG_EXPORT="true"
          SKIP_INCUS_IMG_PRIMER="true"
      fi
  fi

  # Flush VM filesystem cache to ensure all writes are persisted before snapshot
  msg "Syncing VM filesystem to disk."
  incus exec "${BUILD_VM}" -- sync

  msg "Runner build complete."

  # Snapshotting (VM Level) ---
  # No lock needed here, this is isolated to the specific build VM
  if [[ "${SKIP_INCUS_SNAPSHOT}" == "false" ]]; then
      msg "Snapshot requested. Creating snapshot..."
      incus snapshot create "${BUILD_VM}" "build-snapshot"
      msg "Snapshot 'build-snapshot' created successfully."
  else
      msg "Snapshot skipped."
  fi

  # Publishing & Locking (Global Level) ---
  # Only enter this block if we have a snapshot AND we want to publish
  if [[ "${SKIP_INCUS_SNAPSHOT}" == "false" ]] && [[ "${SKIP_INCUS_PUBLISH}" == "false" ]]; then
      
      LOCK_FILE="/var/lock/incus-vm-publish.lock"
      
      # Open FD 200 for the lock file
      exec 200>"${LOCK_FILE}"
      
      msg "Image publish requested. Acquiring lock on ${LOCK_FILE}..."
      if flock 200; then
          msg "Lock acquired. Starting atomic publish sequence."

          # A. Cleanup Old Image
          cleanup_old_image "${IMAGE_ALIAS}"

          # B. Publish New Image
          msg "Publishing snapshot as new image: ${IMAGE_ALIAS}"
          incus publish "${BUILD_VM}/build-snapshot" -f --alias "${IMAGE_ALIAS}" \
              --compression gzip \
              description="GitHub Actions ${IMAGE_OS} ${IMAGE_VERSION} Runner for ${ARCH}" \
              properties.build.os="${clean_args[0]}" \
              properties.build.version="${clean_args[1]}" \
              properties.build.type="${clean_args[2]}" \
              properties.build.cpu="${clean_args[3]}" \
              properties.build.setup="${clean_args[4]}" \
              properties.build.commit="${BUILD_SHA}" \
              properties.build.date="${BUILD_DATE}"

          msg "Image published successfully."

          # C. Primer logic
          if [[ "${SKIP_INCUS_IMG_PRIMER}" == "false" ]]; then
              # shellcheck disable=SC2155
              local PRIMER_VM="primer-$(date +%s)"
              msg "Priming filesystem with temp vm ${PRIMER_VM}..."
              incus launch "${IMAGE_ALIAS}" "${PRIMER_VM}" --vm
              incus rm -f "${PRIMER_VM}"
              msg "Filesystem primed successfully."
          fi

          # D. Export Image
          if [[ "${SKIP_INCUS_IMG_EXPORT}" == "false" ]]; then
              EXPORT_PATH="${EXPORT}/${IMAGE_OS}-${IMAGE_VERSION}-${ARCH}${WORKER_TYPE}${WORKER_CPU}"
              msg "Exporting image to ${EXPORT_PATH}..."
              
              # Clean up any existing export to avoid tar "Cannot unlink" errors
              if [ -f "${EXPORT_PATH}.tar.gz" ]; then
                  msg "Removing existing export file: ${EXPORT_PATH}.tar.gz"
                  rm -f "${EXPORT_PATH}.tar.gz"
              fi
              if [ -d "${EXPORT_PATH}" ]; then
                  msg "Removing existing export directory: ${EXPORT_PATH}"
                  rm -rf "${EXPORT_PATH}"
              fi
              
              incus image export "${IMAGE_ALIAS}" "${EXPORT_PATH}"
              msg "Image exported successfully to ${EXPORT_PATH}."
          fi
      else
          msg "Failed to acquire lock!" >&2
          exit 1
      fi

      # Release Lock
      msg "Releasing lock."
      flock -u 200
      exec 200>&- # Close the file descriptor
  else
      msg "Publishing skipped (or snapshot was skipped)."
  fi

  # Before exiting successfully, clear the trap so it doesn't run again on the main script's exit.
  trap - INT TERM EXIT
  incus delete -f "${BUILD_VM}"
  return 0
}

run() {
  # First ensure Incus is installed and configured
  ensure_incus
  
  # After Incus is ready, check and import the base VM image if needed
  echo ""
  echo "Checking for Ubuntu ${IMAGE_VERSION} base VM image..."

  # shellcheck disable=SC2154
  local BASE_ALIAS="ubuntu-${IMAGE_VERSION}-vm"

  if [[ "${SKIP_INCUS_BASE_IMG}" == "true" ]]; then
    echo "Skipping base image import (--skip-incus-base-img)"
  elif incus image list --format=csv | grep -q "${BASE_ALIAS}"; then
    # Verify the existing image is actually a virtual-machine, not a container
    local BASE_TYPE
    BASE_TYPE=$(incus image info "${BASE_ALIAS}" | awk '/^Type:/{print $2}')
    if [[ "${BASE_TYPE}" != "virtual-machine" ]]; then
      echo "Error: Base image '${BASE_ALIAS}' exists but is type '${BASE_TYPE}', expected 'virtual-machine'." >&2
      echo "Delete it with: sudo incus image delete ${BASE_ALIAS}" >&2
      return 1
    fi
    echo "Base image '${BASE_ALIAS}' found (type: virtual-machine). Skipping import."
  else
    echo "Base image '${BASE_ALIAS}' not found. Building now..."
    # shellcheck disable=SC1091
    source "${HELPERS_DIR}/import_ubuntu_base_images.sh"
    if ! import_ubuntu_base_images "vm" "${IMAGE_VERSION}"; then
      echo "Error: Failed to build/import base image '${BASE_ALIAS}'. Aborting." >&2
      return 1
    fi
    # Verify the image actually landed in Incus before proceeding
    if ! incus image info "${BASE_ALIAS}" &>/dev/null; then
      echo "Error: Base image '${BASE_ALIAS}' not found in Incus after import. Aborting." >&2
      return 1
    fi
    echo "Base image '${BASE_ALIAS}' confirmed in Incus."
  fi

  # Now build the VM image
  build_image "$@"
  return $?
}

prolog() {
  PATH=/usr/local/bin:${PATH}
  EXPORT="/opt/distro"
  HOST_OS_NAME=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"' | tr '[:upper:]' '[:lower:]' | awk '{print $1}')
  # Map OS families - Fedora/RHEL/AlmaLinux/Rocky use CentOS scripts
  [[ "$HOST_OS_NAME" =~ ^(fedora|rhel|almalinux|rocky|red)$ ]] && HOST_OS_NAME="centos"
  [[ "$HOST_OS_NAME" =~ ^(debian)$ ]] && HOST_OS_NAME="ubuntu"
  # shellcheck disable=SC2034
  # shellcheck disable=SC2002
  HOST_OS_VERSION=$(cat /etc/os-release | grep -E 'VERSION_ID' | cut -d'=' -f2 | tr -d '"')
  HOST_INSTALLER_SCRIPT_FOLDER="${HELPERS_DIR}/../../images/${HOST_OS_NAME}/scripts/build"
  BUILD_HOME="/home"
  BUILD_SHA=$(git rev-parse HEAD)
  BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  INCUS_VM="local:${IMAGE_OS}-${IMAGE_VERSION}-vm"

  mkdir -p ${EXPORT}
}

prolog
run "$@"
RC=$?
exit ${RC}

