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
    if ! command -v incus &> /dev/null; then
        echo "Incus is not installed."
        echo "Installing Incus from source..."
        run_script "${HOST_INSTALLER_SCRIPT_FOLDER}/install-incus.sh" "HELPER_SCRIPTS" "INSTALLER_SCRIPT_FOLDER" "ARCH"
        if command -v incus &> /dev/null; then
            echo "Incus installed successfully."
        else
            echo "Failed to install Incus. Please check your system configuration."
            exit 1
        fi
    else
        echo "Incus is already installed. Checking its version..."
        
        INCUS_VERSION=$(incus --version 2>/dev/null || echo "unknown")
        echo "Currently installed Incus version: ${INCUS_VERSION}"
        
        # Check if incus daemon is running and ready
        if incus admin waitready --timeout=5 >/dev/null 2>&1; then
            echo "Incus daemon is running and ready."
        else
            echo "Error: Incus daemon is not responding."
            echo "Please check if incusd is running: pgrep -x incusd"
            exit 1
        fi
    fi
}

# shellcheck disable=SC2329
# shellcheck disable=SC2317
cleanup_builder() {
  local container_name="$1"
  
  # If Debug mode is on, keep the container for inspection
  if [[ "${INCUS_DEBUG:-false}" == "true" ]]; then
     msg "Debug mode enabled. Container ${container_name} preserved."
     return
  fi
  msg "Executing cleanup for container ${container_name}..."
  if incus info "${container_name}" &>/dev/null; then
    msg "Stopping container ${container_name}..."
    # If the container is ephemeral, stopping it deletes it.
    # If not, we force delete to be safe.
    incus delete -f "${container_name}" 2>/dev/null || true
  else
    msg "Container ${container_name} already gone."
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

wait_for_container() {
  local container_name="$1"
  msg "Waiting for ${container_name} systemd to initialize..."

  for ((i = 0; i < 90; i++)); do
      # Check if filesystem is ready
      local CHECK_FS
      CHECK_FS=$(incus exec "${container_name}" -- stat "${BUILD_HOME}" 2>/dev/null || true)
      
      # Check if Systemd/DBus is actually ready
      local CHECK_SYSTEMD
      CHECK_SYSTEMD=$(incus exec "${container_name}" -- systemctl is-system-running 2>/dev/null || true)

      # Proceed if FS is ready AND systemd is 'running' or 'degraded'
      if [ -n "${CHECK_FS}" ] && [[ "${CHECK_SYSTEMD}" == "running" || "${CHECK_SYSTEMD}" == "degraded" ]]; then
          msg "Container ${container_name} is fully operational (State: ${CHECK_SYSTEMD})."
          return 0
      fi
      
      if [ $i -eq 89 ]; then
          msg "Timeout waiting for systemd. Last state: ${CHECK_SYSTEMD}"
          return 1
      fi
      sleep 2s
  done
}

build_image() {
  set -e

  local IMAGE_ALIAS="${IMAGE_ALIAS:-${IMAGE_OS}-${IMAGE_VERSION}-${ARCH}${WORKER_TYPE}${WORKER_CPU}}"
  local BUILD_PREREQS_PATH
  BUILD_PREREQS_PATH="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

  # Search for an existing image that matches the strict criteria:
  # (commit, os, version, and setup)
  # We use 'jq' to filter the JSON output of incus image list.
  local EXISTING_IMAGE_JSON
  # shellcheck disable=SC2154
  EXISTING_IMAGE_JSON=$(incus image list --format=json | jq -r --arg commit "${BUILD_SHA}" --arg os "${clean_args[0]}" --arg ver "${clean_args[1]}" --arg setup "${clean_args[4]}" \
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

  local BUILD_CONTAINER
  BUILD_CONTAINER="gha-builder-$(date +%s)"

  # Trap INT (Ctrl+C), TERM (kill), and EXIT signals to guarantee cleanup.
  # shellcheck disable=SC2064
  trap "cleanup_builder '${BUILD_CONTAINER}'" INT TERM EXIT

  msg "Launching build container ${BUILD_CONTAINER} from image ${INCUS_CONTAINER}..."

  if [[ "${INCUS_DEBUG:-false}" == "true" ]]; then
    # Non-ephemeral for debugging
    incus launch "${INCUS_CONTAINER}" "${BUILD_CONTAINER}"
  else
    # Ephemeral for clean builds
    incus launch "${INCUS_CONTAINER}" "${BUILD_CONTAINER}" --ephemeral
  fi

  incus ls

  wait_for_container "${BUILD_CONTAINER}"
  
  msg "Mapping localhost..."
  incus exec "${BUILD_CONTAINER}" -- sh -c "echo '127.0.1.1 ${BUILD_CONTAINER}' >> /etc/hosts"

  # shellcheck disable=SC2154
  msg "Copy the ${image_folder} contents into the gha-builder"
  incus file push "${image_folder}" "${BUILD_CONTAINER}/var/tmp/" --recursive
  incus exec "${BUILD_CONTAINER}" ls "${image_folder}"

  msg "Copy the register-runner.sh script into gha-builder"
  incus file push --mode 0755 "${BUILD_PREREQS_PATH}/helpers/register-runner.sh" "${BUILD_CONTAINER}/opt/register-runner.sh"

  msg "Copy the /etc/rc.local - required in case podman is used"
  incus file push --mode 0755 "${BUILD_PREREQS_PATH}/assets/rc.local" "${BUILD_CONTAINER}/etc/rc.local"

  msg "Copy the gha-service unit file into gha-builder"
  incus file push "${BUILD_PREREQS_PATH}/assets/gha-runner.service" "${BUILD_CONTAINER}/etc/systemd/system/gha-runner.service"

  msg "Copy the apt and dpkg overrides into gha-builder - these prevent doc files from being installed"
  incus file push --mode 0644 "${BUILD_PREREQS_PATH}/assets/99synaptics" "${BUILD_CONTAINER}/etc/apt/apt.conf.d/99synaptics"
  incus file push --mode 0644 "${BUILD_PREREQS_PATH}/assets/01-nodoc" "${BUILD_CONTAINER}/etc/dpkg/dpkg.cfg.d/01-nodoc"

  msg "Running setup_install.sh (as root)"
  # shellcheck disable=SC1073
  # shellcheck disable=SC2154
  if ! incus exec "${BUILD_CONTAINER}" --user 0 --group 0 ${GITHUB_TOKEN:+--env GITHUB_TOKEN="${GITHUB_TOKEN}"} -- \
    bash -c 'exec "$@"' _ "${helper_script_folder}/setup_install.sh" "${clean_args[@]}" "${forward_args[@]}"; then

    msg "!!! The installation script inside the container failed. Triggering cleanup. !!!" >&2
    return 1 # Exit with an error code to trigger the trap and signal failure
  fi

  msg "Setting user runner with sudo privileges"
  incus exec "${BUILD_CONTAINER}" --user 0 --group 0 -- bash -c "useradd -c 'Action Runner' -m -s /bin/bash runner && usermod -L runner && echo 'runner ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/runner && chmod 440 /etc/sudoers.d/runner"

  msg "Adding runner user to required groups"
  incus exec "${BUILD_CONTAINER}" --user 0 --group 0 -- bash -c "
    # Add to base groups
    usermod -aG adm,users,systemd-journal runner
    # Add to docker group if it exists
    getent group docker >/dev/null && usermod -aG docker runner || true
    # Add to incus group if it exists
    getent group incus >/dev/null && usermod -aG incus runner || true
  "
  
  msg "Running post-generation scripts (as root)"
  incus exec "${BUILD_CONTAINER}" --user 0 --group 0 -- bash -c "find /opt/post-generation -mindepth 1 -maxdepth 1 -type f -name '*.sh' -exec bash {} \;"

  # Logic Validation ---
  if [[ "${SKIP_INCUS_PUBLISH}" == "true" ]]; then
      # If Publish is skipped, we must ensure dependent steps are also skipped.
      if [[ "${SKIP_INCUS_IMG_EXPORT}" != "true" ]] || [[ "${SKIP_INCUS_IMG_PRIMER}" != "true" ]]; then
          msg "Warning: Cannot prime/export image if publishing is skipped. Disabling prime/export."
          SKIP_INCUS_IMG_EXPORT="true"
          SKIP_INCUS_IMG_PRIMER="true"
      fi
  fi

  msg "Runner build complete."

  # Snapshotting (Container Level) ---
  # No lock needed here, this is isolated to the specific build container
  if [[ "${SKIP_INCUS_SNAPSHOT}" == "false" ]]; then
      msg "Snapshot requested. Creating snapshot..."
      incus snapshot create "${BUILD_CONTAINER}" "build-snapshot"
      msg "Snapshot 'build-snapshot' created successfully."
  else
      msg "Snapshot skipped."
  fi

  # Publishing & Locking (Global Level) ---
  # Only enter this block if we have a snapshot AND we want to publish
  if [[ "${SKIP_INCUS_SNAPSHOT}" == "false" ]] && [[ "${SKIP_INCUS_PUBLISH}" == "false" ]]; then
      
      LOCK_FILE="/var/lock/incus-publish.lock"
      
      # Open FD 200 for the lock file
      exec 200>"${LOCK_FILE}"
      
      msg "Image publish requested. Acquiring lock on ${LOCK_FILE}..."
      if flock 200; then
          msg "Lock acquired. Starting atomic publish sequence."

          # A. Cleanup Old Image
          cleanup_old_image "${IMAGE_ALIAS}"

          # B. Publish New Image
          msg "Publishing snapshot as new image: ${IMAGE_ALIAS}"
          incus publish "${BUILD_CONTAINER}/build-snapshot" -f --alias "${IMAGE_ALIAS}" \
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
              local PRIMER_CONTAINER="primer-$(date +%s)"
              msg "Priming filesystem with temp container ${PRIMER_CONTAINER}..."
              incus launch "${IMAGE_ALIAS}" "${PRIMER_CONTAINER}"
              incus rm -f "${PRIMER_CONTAINER}"
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
  incus delete -f "${BUILD_CONTAINER}"
  return 0
}

run() {
  ensure_incus "$@"
  build_image "$@"
  return $?
}

prolog() {
  PATH=/usr/local/bin:${PATH}
  EXPORT="/opt/distro"
  HOST_OS_NAME=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"' | tr '[:upper:]' '[:lower:]' | awk '{print $1}')
  # shellcheck disable=SC2034
  # shellcheck disable=SC2002
  HOST_OS_VERSION=$(cat /etc/os-release | grep -E 'VERSION_ID' | cut -d'=' -f2 | tr -d '"')
  HOST_INSTALLER_SCRIPT_FOLDER="${HELPERS_DIR}/../../images/${HOST_OS_NAME}/scripts/build"
  BUILD_HOME="/home"
  BUILD_SHA=$(git rev-parse HEAD)
  BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  INCUS_CONTAINER="local:${IMAGE_OS}-${IMAGE_VERSION}"

  mkdir -p ${EXPORT}
}

prolog
run "$@"
RC=$?
exit ${RC}

# Made with Bob
