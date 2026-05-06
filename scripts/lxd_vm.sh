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

ensure_lxd() {
    if ! command -v lxd &> /dev/null; then
        echo "LXD is not installed."
        if ! command -v snap &> /dev/null; then
            echo "Snap is not installed. Installing Snap..."
            run_script "${HOST_INSTALLER_SCRIPT_FOLDER}/install-snap.sh" "HELPER_SCRIPTS" "INSTALLER_SCRIPT_FOLDER" "ARCH"
            echo "Snap installed successfully."
        fi
        echo "Installing LXD using Snap..."
        run_script "${HOST_INSTALLER_SCRIPT_FOLDER}/install-lxd.sh" "HELPER_SCRIPTS" "INSTALLER_SCRIPT_FOLDER" "ARCH"
        if command -v lxd &> /dev/null; then
            echo "LXD installed successfully."
        else
            echo "Failed to install LXD. Please check your system configuration."
            exit 1
        fi
    else
        echo "LXD is already installed. Checking its version..."

        LATEST_LTS_CHANNEL=$(snap info lxd | grep -E '(^\s*[0-9]+\.0/stable)' | awk '{print $1}' | sed 's|/stable:||' | sort -rV | head -n 1)

        # Get the currently tracked channel from the snap list output.
        CURRENT_LTS_CHANNEL=$(snap list lxd | awk 'NR==2 {print $4}' | sed 's|/stable.*||')

        echo "Currently installed channel: ${CURRENT_LTS_CHANNEL}"
        echo "Latest available LTS channel: ${LATEST_LTS_CHANNEL}"

        # Compare the current channel with the latest available LTS channel.
        if [ "$CURRENT_LTS_CHANNEL" != "$LATEST_LTS_CHANNEL" ]; then
            echo
            echo "An upgrade is recommended."
            echo "To prevent disruption to your existing setup, please upgrade manually."
            echo "Run the following command to switch to the latest LTS channel:"
            echo
            echo "  sudo snap refresh lxd --channel=${LATEST_LTS_CHANNEL}/stable"
            echo
            echo "Note: Always back up your data before performing a channel switch."
        else
            echo "You are already on the latest available LXD LTS channel. No action needed."
        fi
        echo "Checking list of refreshable snaps..."
        sudo snap refresh --list
  
        # Hold the autorefresh for LXD
        sudo snap refresh --hold lxd
    fi
}

# shellcheck disable=SC2329
# shellcheck disable=SC2317
cleanup_builder() {
  local vm_name="$1"
  
  # If Debug mode is on, keep the VM for inspection
  if [[ "${LXD_DEBUG:-false}" == "true" ]]; then
     msg "Debug mode enabled. VM ${vm_name} preserved."
     return
  fi
  msg "Executing cleanup for VM ${vm_name}..."
  if lxc info "${vm_name}" &>/dev/null; then
    msg "Stopping VM ${vm_name}..."
    # If the VM is ephemeral, stopping it deletes it.
    # If not, we force delete to be safe.
    lxc delete -f "${vm_name}" 2>/dev/null || true
  else
    msg "VM ${vm_name} already gone."
  fi
}

cleanup_old_image() {
    local IMAGE_ALIAS="$1"
    msg "Checking for existing alias ${IMAGE_ALIAS}..."
    if lxc image info "${IMAGE_ALIAS}" >/dev/null 2>&1; then
        # Extract fingerprint
        OLD_FINGERPRINT=$(lxc image info "${IMAGE_ALIAS}" | awk '/^Fingerprint:/ {print $2; exit}')
        
        if [[ -n "${OLD_FINGERPRINT}" ]]; then
            msg "Deleting old image ${OLD_FINGERPRINT} to make room for alias ${IMAGE_ALIAS}..."
            lxc image delete "${OLD_FINGERPRINT}" || true
        fi
    fi
}

wait_for_vm() {
  local vm_name="$1"
  msg "Waiting for ${vm_name} systemd to initialize..."

  for ((i = 0; i < 90; i++)); do
      # Check if filesystem is ready
      local CHECK_FS
      CHECK_FS=$(lxc exec "${vm_name}" -- stat "${BUILD_HOME}" 2>/dev/null || true)
      
      # Check if Systemd/DBus is actually ready
      local CHECK_SYSTEMD
      CHECK_SYSTEMD=$(lxc exec "${vm_name}" -- systemctl is-system-running 2>/dev/null || true)

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
# Configure CPU resources for an LXD VM
# Parameters:
#   $1 - vm_name: Name of the LXD VM
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
  used_cpus=$(lxc list -c n status=running --format csv | xargs -I {} lxc config get {} limits.cpu 2>/dev/null | grep ',' | tr ',' '\n' | sort -u)
  
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
  
  # Print the result and apply to LXD
  echo "Successfully found available CPUs."
  echo "Allocating CPUs: $cpus_to_allocate to '${vm_name}'"
  
  if ! lxc config set "${vm_name}" limits.cpu "$cpus_to_allocate"; then
    echo "Error: Failed to set CPU limits for VM '${vm_name}'."
    return 1
  fi
  
  msg "CPU configuration completed successfully."
  return 0
}

# Configure memory resources for an LXD VM
# Parameters:
#   $1 - vm_name: Name of the LXD VM
#   $2 - target_memory_mb: Desired memory allocation in MB (default: 4096)
#   $3 - host_buffer_mb: Safety buffer to leave for host OS in MB (default: 512)
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
    echo "Error: Invalid target memory. Must be a positive integer (MB)."
    return 1
  fi
  
  if ! [[ "$host_buffer_mb" =~ ^[0-9]+$ ]] || [[ "$host_buffer_mb" -lt 0 ]]; then
    echo "Error: Invalid host buffer. Must be a non-negative integer (MB)."
    return 1
  fi
  
  msg "Configuring memory resources for VM '${vm_name}'..."
  
  # Get currently available memory directly from the kernel (in KB, convert to MB)
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
    echo "Available: ${avail_mb}MB, Buffer: ${host_buffer_mb}MB, Safe: ${safe_mb}MB"
    return 1
  fi
  
  # Determine how much to actually allocate
  local allocate_mb
  if [[ "$target_memory_mb" -gt "$safe_mb" ]]; then
    allocate_mb="$safe_mb"
    echo "Warning: Requested ${target_memory_mb}MB, but only ${safe_mb}MB is safely available."
    echo "Throttling down to ${safe_mb}MB..."
  else
    allocate_mb="$target_memory_mb"
  fi
  
  # Apply the limit to the VM
  echo "Allocating ${allocate_mb}MB to '${vm_name}'..."
  
  if ! lxc config set "${vm_name}" limits.memory "${allocate_mb}MB"; then
    echo "Error: Failed to set memory limits for VM '${vm_name}'."
    return 1
  fi
  
  msg "Memory configuration completed successfully."
  return 0
}


build_image() {
  set -e

  local IMAGE_ALIAS="${IMAGE_ALIAS:-${IMAGE_OS}-${IMAGE_VERSION}-${ARCH}${WORKER_TYPE}${WORKER_CPU}}"
  local BUILD_PREREQS_PATH
  BUILD_PREREQS_PATH="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

  # Search for an existing image that matches the strict criteria:
  # (commit, os, version, and setup)
  # We use 'jq' to filter the JSON output of lxc image list.
  local EXISTING_IMAGE_JSON
  # shellcheck disable=SC2154
  EXISTING_IMAGE_JSON=$(lxc image list --format=json | jq -r --arg commit "${BUILD_SHA}" --arg os "${clean_args[0]}" --arg ver "${clean_args[1]}" --arg setup "${clean_args[4]}" \
    '.[] | select(
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
        lxc image alias create "${IMAGE_ALIAS}" "${FINGERPRINT}"
    else
        echo "Alias '${IMAGE_ALIAS}' already exists on the image. Nothing to do."
    fi

    echo "Skipping build."
    return 0
  fi

  if [[ "${DELETE_LXD_IMG}" == "true" ]]; then
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

  msg "Initializing build VM ${BUILD_VM} from image ${LXD_VM}..."

  if [[ "${LXD_DEBUG:-false}" == "true" ]]; then
    # Non-ephemeral for debugging
    lxc init "${LXD_VM}" "${BUILD_VM}" --vm
  else
    # Ephemeral for clean builds
    lxc init "${LXD_VM}" "${BUILD_VM}" --vm --ephemeral
  fi

  lxc ls

  # Configure CPU and memory resources
  configure_cpu_resources "${BUILD_VM}" 4
  configure_memory_resources "${BUILD_VM}" 4096 512

  lxc start "${BUILD_VM}"

  wait_for_vm "${BUILD_VM}"
  
  msg "Mapping localhost..."
  lxc exec "${BUILD_VM}" -- sh -c "echo '127.0.1.1 ${BUILD_VM}' >> /etc/hosts"

  msg "Checking current partitions..."
  lxc exec "${BUILD_VM}" -- cat /proc/partitions
  
  msg "Expanding partition 1 on /dev/sda..."
  lxc exec "${BUILD_VM}" -- growpart /dev/sda 1 || true
  
  msg "Enabling cloud-init-local..."
  lxc exec "${BUILD_VM}" -- systemctl enable --now cloud-init-local
  
  msg "Rebooting VM to apply partition changes..."
  lxc restart "${BUILD_VM}"
  
  wait_for_vm "${BUILD_VM}"
  
  msg "Resizing filesystem..."
  lxc exec "${BUILD_VM}" -- resize2fs /dev/sda1
  
  msg "Final Disk Usage:"
  lxc exec "${BUILD_VM}" -- df -h

  # shellcheck disable=SC2154
  msg "Copy the ${image_folder} contents into the gha-builder"
  lxc file push "${image_folder}" "${BUILD_VM}/var/tmp/" --recursive
  lxc exec "${BUILD_VM}" ls "${image_folder}"

  msg "Copy the register-runner.sh script into gha-builder"
  lxc file push --mode 0755 "${BUILD_PREREQS_PATH}/helpers/register-runner.sh" "${BUILD_VM}/opt/register-runner.sh"

  msg "Copy the /etc/rc.local - required in case podman is used"
  lxc file push --mode 0755 "${BUILD_PREREQS_PATH}/assets/rc.local" "${BUILD_VM}/etc/rc.local"

  msg "Copy the gha-service unit file into gha-builder"
  lxc file push "${BUILD_PREREQS_PATH}/assets/gha-runner.service" "${BUILD_VM}/etc/systemd/system/gha-runner.service"

  msg "Copy the apt and dpkg overrides into gha-builder - these prevent doc files from being installed"
  lxc file push --mode 0644 "${BUILD_PREREQS_PATH}/assets/99synaptics" "${BUILD_VM}/etc/apt/apt.conf.d/99synaptics"
  lxc file push --mode 0644 "${BUILD_PREREQS_PATH}/assets/01-nodoc" "${BUILD_VM}/etc/dpkg/dpkg.cfg.d/01-nodoc"

  msg "Running setup_install.sh (as root)"
  # shellcheck disable=SC1073
  # shellcheck disable=SC2154
  if ! lxc exec "${BUILD_VM}" --user 0 --group 0 ${GITHUB_TOKEN:+--env GITHUB_TOKEN="${GITHUB_TOKEN}"} -- \
    bash -c 'exec "$@"' _ "${helper_script_folder}/setup_install.sh" "${clean_args[@]}" "${forward_args[@]}"; then

    msg "!!! The installation script inside the VM failed. Triggering cleanup. !!!" >&2
    return 1 # Exit with an error code to trigger the trap and signal failure
  fi

  msg "Setting user runner with sudo privileges"
  lxc exec "${BUILD_VM}" --user 0 --group 0 -- bash -c "useradd -c 'Action Runner' -m -s /bin/bash runner && usermod -L runner && echo 'runner ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/runner && chmod 440 /etc/sudoers.d/runner"

  msg "Adding runner user to required groups"
  lxc exec "${BUILD_VM}" --user 0 --group 0 -- bash -c "usermod -aG adm,users,systemd-journal,docker,lxd runner"
  
  msg "Running post-generation scripts (as root)"
  lxc exec "${BUILD_VM}" --user 0 --group 0 -- bash -c "find /opt/post-generation -mindepth 1 -maxdepth 1 -type f -name '*.sh' -exec bash {} \;"

  # Logic Validation ---
  if [[ "${SKIP_LXD_PUBLISH}" == "true" ]]; then
      # If Publish is skipped, we must ensure dependent steps are also skipped.
      if [[ "${SKIP_LXD_IMG_EXPORT}" != "true" ]] || [[ "${SKIP_LXD_IMG_PRIMER}" != "true" ]]; then
          msg "Warning: Cannot prime/export image if publishing is skipped. Disabling prime/export."
          SKIP_LXD_IMG_EXPORT="true"
          SKIP_LXD_IMG_PRIMER="true"
      fi
  fi

  msg "Runner build complete."

  # Snapshotting (VM Level) ---
  # No lock needed here, this is isolated to the specific build VM
  if [[ "${SKIP_LXD_SNAPSHOT}" == "false" ]]; then
      msg "Snapshot requested. Creating snapshot..."
      lxc snapshot "${BUILD_VM}" "build-snapshot"
      msg "Snapshot 'build-snapshot' created successfully."
  else
      msg "Snapshot skipped."
  fi

  # Publishing & Locking (Global Level) ---
  # Only enter this block if we have a snapshot AND we want to publish
  if [[ "${SKIP_LXD_SNAPSHOT}" == "false" ]] && [[ "${SKIP_LXD_PUBLISH}" == "false" ]]; then
      
      LOCK_FILE="/var/lock/lxd-publish.lock"
      
      # Open FD 200 for the lock file
      exec 200>"${LOCK_FILE}"
      
      msg "Image publish requested. Acquiring lock on ${LOCK_FILE}..."
      if flock 200; then
          msg "Lock acquired. Starting atomic publish sequence."

          # A. Cleanup Old Image
          cleanup_old_image "${IMAGE_ALIAS}"

          # B. Publish New Image
          msg "Publishing snapshot as new image: ${IMAGE_ALIAS}"
          lxc publish "${BUILD_VM}/build-snapshot" -f --alias "${IMAGE_ALIAS}" \
              --compression none \
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
          if [[ "${SKIP_LXD_IMG_PRIMER}" == "false" ]]; then
              # shellcheck disable=SC2155
              local PRIMER_VM="primer-$(date +%s)"
              msg "Priming filesystem with temp vm ${PRIMER_VM}..."
              lxc launch "${IMAGE_ALIAS}" "${PRIMER_VM}" --vm
              lxc rm -f "${PRIMER_VM}"
              msg "Filesystem primed successfully."
          fi

          # D. Export Image
          if [[ "${SKIP_LXD_IMG_EXPORT}" == "false" ]]; then
              EXPORT_PATH="${EXPORT}/${IMAGE_OS}-${IMAGE_VERSION}-${ARCH}${WORKER_TYPE}${WORKER_CPU}"
              msg "Exporting image to ${EXPORT_PATH}..."
              lxc image export "${IMAGE_ALIAS}" "${EXPORT_PATH}"
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
  lxc delete -f "${BUILD_VM}"
  return 0
}

run() {
  ensure_lxd "$@"
  build_image "$@"
  return $?
}

prolog() {
  PATH=/snap/bin:${PATH}
  EXPORT="/opt/distro"
  HOST_OS_NAME=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"' | tr '[:upper:]' '[:lower:]' | awk '{print $1}')
  # shellcheck disable=SC2034
  # shellcheck disable=SC2002
  HOST_OS_VERSION=$(cat /etc/os-release | grep -E 'VERSION_ID' | cut -d'=' -f2 | tr -d '"')
  HOST_INSTALLER_SCRIPT_FOLDER="${HELPERS_DIR}/../../images/${HOST_OS_NAME}/scripts/build"
  BUILD_HOME="/home"
  BUILD_SHA=$(git rev-parse HEAD)
  BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  LXD_VM="${IMAGE_OS}:${IMAGE_VERSION}"

  mkdir -p ${EXPORT}
}

prolog
run "$@"
RC=$?
exit ${RC}