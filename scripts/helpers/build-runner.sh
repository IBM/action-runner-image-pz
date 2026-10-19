#!/bin/bash
################################################################################
##  File:  build-runner.sh
##  Desc:  Clone actions/runner into /tmp/runner and build it (layout + package).
##         Builds the latest release tag with the release patch first; if the
##         patch does not apply or the build fails, rebuilds from upstream main
##         with the main patch. Tests are left to the caller, so a test failure
##         never triggers the fallback.
##  Usage: build-runner.sh <runner-repo> <release-patch> <main-patch>
################################################################################

set -euo pipefail

RUNNERREPO="$1"
RELEASE_PATCH="$(readlink -f "$2")"
MAIN_PATCH="$(readlink -f "$3")"

# $1 = git ref, $2 = patch file. Chained with && because 'set -e' is
# suspended inside a function called on the left of '||'.
build() {
    echo "Building runner at $1 with $(basename "$2")"
    git checkout -q -f "$1" &&
        git clean -qfdx &&
        git apply --whitespace=nowarn "$2" &&
        sed -i'' -e '/version/s/8......"$/8.0.100"/' src/global.json &&
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
