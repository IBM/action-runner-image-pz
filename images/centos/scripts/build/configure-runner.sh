#!/bin/bash

set -euo pipefail 

header() {
    TS=$(date +"%Y-%m-%dT%H:%M:%S%:z")
    echo "${TS} +--------------------------------------------+"
    echo "${TS} | $*"
    echo "${TS} +--------------------------------------------+"
    echo
}

msg() {
    # shellcheck disable=SC2046
    echo $(date +"%Y-%m-%dT%H:%M:%S%:z") "$*"
}

check_idempotency() {
    header "Checking Idempotency"
    
    msg "Fetching latest upstream version from ${RUNNERREPO}..."
    UPSTREAM_TAG=$(git ls-remote --tags --refs --sort='v:refname' "${RUNNERREPO}" | tail -n1 | awk -F/ '{print $NF}')
    
    UPSTREAM_VER="${UPSTREAM_TAG#v}"
    msg "Latest Upstream Version: ${UPSTREAM_VER}"

    CURRENT_VER="none"
    if [ -f "/opt/runner-cache/bin/Runner.Listener" ]; then
        CURRENT_VER=$(/opt/runner-cache/bin/Runner.Listener --version 2>/dev/null || echo "error")
    fi

    msg "Current Installed Version: ${CURRENT_VER}"

    if [ "${UPSTREAM_VER}" == "${CURRENT_VER}" ]; then
        header "Versions match (${UPSTREAM_VER}). Skipping build."
        exit 0
    else
        msg "Versions do not match or runner not installed. Proceeding with build..."
    fi
}

build_runner() {
    export DOTNET_NUGET_SIGNATURE_VERIFICATION=false
    header "Cloning, patching and building runner"
    # Latest release + release patch; falls back to main + main patch if that fails to patch or build
    bash "${HELPER_SCRIPTS}"/build-runner.sh "${RUNNERREPO}" \
        "${IMAGE_FOLDER}"/runner-sdk-8.patch "${IMAGE_FOLDER}"/runner-main-sdk-8.patch
    cd /tmp/runner/src

    msg "Running tests"
    ./dev.sh test
}

install_runner() {
    header "Installing runner"
    sudo mkdir -p /opt/runner-cache
    sudo tar -xf /tmp/runner/_package/*.tar.gz -C /opt/runner-cache
}

pre_cleanup() {
    sudo rm -rf /tmp/runner /opt/runner-cache
}

post_cleanup() {
    sudo rm -rf "${IMAGE_FOLDER}"/runner-sdk-8.patch "${IMAGE_FOLDER}"/runner-main-sdk-8.patch \
           /tmp/preseed-yaml /home/ubuntu/.nuget \
           /home/runner/.local/share
}

run() {
    check_idempotency
    pre_cleanup
    build_runner
    install_runner
    post_cleanup
}

RUNNERREPO="https://github.com/actions/runner"

# Parse arguments
while getopts "a:" opt; do
    case ${opt} in
        a) RUNNERREPO=${OPTARG} ;;
        *) exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

run 