#!/bin/bash
################################################################################
##  File:  build-runner.sh
##  Desc:  Clone actions/runner into /tmp/runner and build it (layout + package).
##         Builds the latest release tag with the release patch first; if the
##         patch does not apply or the build fails, rebuilds from upstream main
##         with the main patch. Tests are left to the caller, so a test failure
##         never triggers the fallback. The .NET SDK is pinned per ref from its
##         own src/global.json, so a .NET 8 release and a .NET 10 main both build
##         as long as both SDKs are installed.
##  Usage: build-runner.sh <runner-repo> <release-patch> <main-patch>
################################################################################

set -euo pipefail

RUNNERREPO="$1"
RELEASE_PATCH="$(readlink -f "$2")"
MAIN_PATCH="$(readlink -f "$3")"

# Upstream pins an exact SDK (e.g. 8.0.427) that distro source-built SDKs (x.0.1xx) never match.
# Re-pin to the feature band of the major the checked-out ref targets, so the matching installed
# SDK is picked when several are present: a .NET 10 SDK restoring a net8.0 project on ppc64le/s390x
# fails with NU1101 (no Microsoft.NETCore.App.Host.linux-<arch> 8.0 on nuget.org).
# ponytail: rewrites the whole file; upstream global.json only ever holds sdk.version.
pin_sdk() {
    local major
    major=$(sed -n 's/.*"version": *"\([0-9]*\)\..*/\1/p' src/global.json)
    [ -n "${major}" ] || { echo "Cannot read the SDK version from src/global.json"; return 1; }
    echo "Pinning .NET SDK ${major}.0.100 (rollForward latestFeature)"
    printf '{\n  "sdk": {\n    "version": "%s.0.100",\n    "rollForward": "latestFeature"\n  }\n}\n' "${major}" > src/global.json
}

# $1 = git ref, $2 = patch file. Chained with && because 'set -e' is
# suspended inside a function called on the left of '||'.
build() {
    echo "Building runner at $1 with $(basename "$2")"
    git checkout -q -f "$1" &&
        git clean -qfdx &&
        git apply --whitespace=nowarn "$2" &&
        pin_sdk &&
        (cd src && ./dev.sh layout Release && ./dev.sh package Release)
}

cd /tmp
git clone --tags -q "${RUNNERREPO}" runner
cd runner

release_tag=$(git tag --sort=-v:refname | grep '^v[0-9]' | head -n1)
# The main patch records the upstream commit it was generated against.
main_ref=$(sed -n 's/^# From upstream commit: //p' "${MAIN_PATCH}")

build "${release_tag}" "${RELEASE_PATCH}" || {
    echo "WARNING: Release ${release_tag} failed to patch or build; falling back to main (${main_ref:-origin/main})"
    build "${main_ref:-origin/main}" "${MAIN_PATCH}"
}
