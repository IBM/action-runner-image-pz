#!/bin/bash -e
################################################################################
##  File:  configure-apt.sh
##  Desc:  Configure apt, install jq and apt-fast packages.
################################################################################

# shellcheck disable=SC1091
source "$HELPER_SCRIPTS"/os.sh
source "$HELPER_SCRIPTS"/install.sh

# Stop and disable apt-daily upgrade services;
systemctl stop apt-daily.timer
systemctl disable apt-daily.timer
systemctl disable apt-daily.service
systemctl stop apt-daily-upgrade.timer
systemctl disable apt-daily-upgrade.timer
systemctl disable apt-daily-upgrade.service

# Bound apt's acquire behavior so a stalled mirror fails over in seconds instead of minutes.
# apt reads Acquire::Retries (default 3), not APT::Acquire::Retries, and spends every retry on the
# same URI before trying the next mirror in /etc/apt/apt-mirrors.txt, so a high count delays failover.
# 22.04 and 24.04 arm64 keep apt's defaults: they are served by ports.ubuntu.com, which the mirror
# list does not cover, so retries are their only failover and a timeout is a hard failure rather than
# a fallback. 26.04 merged arm64 into the main archive, so it uses the mirror list like x64 does.
# https://github.com/actions/runner-images/issues/14594
# Without /etc/apt/apt-mirrors.txt (configure-apt-sources.sh not run, e.g. ppc64le/s390x on
# ports.ubuntu.com) there is no mirror failover either, so keep apt's defaults there as well.
if is_ubuntu22_arm64 || is_ubuntu24_arm64 || [ ! -f /etc/apt/apt-mirrors.txt ]; then
    apt_retries=3
    apt_timeout=30
else
    apt_retries=1
    apt_timeout=15
fi

# Write these where apt applies them last. apt reads /etc/apt/apt.conf.d in C-locale filename order
# and the last setting for a key wins; another file on the image sorts after 80-* and was overriding
# these Timeout/Retries values (canary saw apt's defaults, not these). A leaf name sorts after every
# NN-* file, so ours wins.
cat <<EOF > /etc/apt/apt.conf.d/zz-retries
Acquire::Retries "$apt_retries";
Acquire::http::Timeout "$apt_timeout";
Acquire::https::Timeout "$apt_timeout";
EOF

# Log the effective, post-merge values so canary/CI shows exactly what apt will use.
echo 'Effective apt acquire configuration'
apt-config dump Acquire::Retries Acquire::http::Timeout Acquire::https::Timeout

# Configure apt to always assume Y
echo "APT::Get::Assume-Yes \"true\";" > /etc/apt/apt.conf.d/90assumeyes

# Configure apt to force IPv4
echo "Acquire::ForceIPv4 \"true\";" > /etc/apt/apt.conf.d/99force-ipv4

# APT understands a field called Phased-Update-Percentage which can be used to control the rollout of a new version. It is an integer between 0 and 100.
# In case you have multiple systems that you want to receive the same set of updates, 
# you can set APT::Machine-ID to a UUID such that they all phase the same, 
# or set APT::Get::Never-Include-Phased-Updates or APT::Get::Always-Include-Phased-Updates to true such that APT will never/always consider phased updates.
# apt-cache policy pkgname
echo 'APT::Get::Always-Include-Phased-Updates "true";' > /etc/apt/apt.conf.d/99-phased-updates

# DEP-11/AppStream is desktop software-catalog metadata with no CI use. Skipping it drops 15 of the 51
# index items and 7.6 MB from every apt-get update.
# Sorts after appstream's own /etc/apt/apt.conf.d/50appstream, so it wins.
echo 'Acquire::IndexTargets::deb::DEP-11::DefaultEnabled "false";' > /etc/apt/apt.conf.d/90-index-targets

# Fix bad proxy and http headers settings
cat <<EOF >> /etc/apt/apt.conf.d/99bad_proxy
Acquire::http::Pipeline-Depth 0;
Acquire::http::No-Cache true;
Acquire::https::Pipeline-Depth 0;
Acquire::https::No-Cache true;
Acquire::BrokenProxy    true;
EOF

# Uninstall unattended-upgrades
apt-get purge unattended-upgrades

echo 'APT sources'
# Support both deb822 format (ubuntu.sources) and classic format (sources.list)
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    cat /etc/apt/sources.list.d/ubuntu.sources
elif [ -f /etc/apt/sources.list ]; then
    cat /etc/apt/sources.list
else
    echo "Warning: No APT sources file found"
fi

if [ -f /etc/apt/apt-mirrors.txt ]; then
    echo 'APT mirrors'
    cat /etc/apt/apt-mirrors.txt
fi

update_dpkgs
# configure-dpkg.sh sets these Dpkg::Options globally but runs later; pass them here so changed conffiles never prompt
apt-get upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
# Install jq
install_dpkgs jq

if is_ubuntu22; then
    # apt-fast's quick-install.sh requires wget; install it first as it may not be present in the base image
    install_dpkgs wget
    # Install apt-fast using quick-install.sh
    # https://github.com/ilikenwf/apt-fast
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/ilikenwf/apt-fast/master/quick-install.sh)"
fi
