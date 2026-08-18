#!/bin/bash
################################################################################
##  File:  setup-incus-network.sh
##  Desc:  Initialize Incus storage, network, and default profile
##  Note:  Sourced by install-incus.sh. Expects ARCH, CONFIG_FILE, and
##         INCUSD_LOG to be set by the caller.
################################################################################

echo "[INFO] Initializing Incus..."

# Check if storage pool exists
STORAGE_EXISTS=$(/usr/local/bin/incus storage list --format csv 2>/dev/null | grep -q "^default," && echo "true" || echo "false")

# Check if network exists AND is properly configured (managed=YES)
NETWORK_EXISTS=$(/usr/local/bin/incus network list --format csv 2>/dev/null | grep "^incusbr0," | grep -q ",YES," && echo "true" || echo "false")

if [ "$STORAGE_EXISTS" = "true" ] && [ "$NETWORK_EXISTS" = "true" ]; then
    echo "[INFO] Incus already initialized (storage and network exist)"
    echo "[INFO] Existing storage pools:"
    /usr/local/bin/incus storage list
    echo "[INFO] Existing networks:"
    /usr/local/bin/incus network list
else
    # Hybrid approach: Try preseed first if nothing exists,
    # fallback to manual if partial state detected.
    if [ "$STORAGE_EXISTS" = "false" ] && [ "$NETWORK_EXISTS" = "false" ]; then
        echo "[INFO] Fresh installation detected. Attempting preseed initialization..."
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "[ERROR] Config file not found: $CONFIG_FILE"
            exit 1
        fi

        echo "[INFO] Verifying daemon..."
        if ! /usr/local/bin/incus admin waitready --timeout=5; then
            echo "[ERROR] incusd not ready"
            cat "${INCUSD_LOG:-/dev/null}" 2>/dev/null || true
            exit 1
        fi

        if timeout 60 /usr/local/bin/incus admin init --preseed < "$CONFIG_FILE"; then
            echo "[INFO] Preseed initialization successful"
        else
            RC=$?
            if [ "$RC" = "124" ]; then
                echo "[ERROR] Preseed initialization timed out"
            fi
            echo "[ERROR] Preseed initialization failed"
            cat "${INCUSD_LOG:-/dev/null}" 2>/dev/null || true
            echo "[WARN] Falling back to manual configuration..."
            PRESEED_FAILED=true

            # Re-query state — preseed may have partially succeeded
            STORAGE_EXISTS=$(/usr/local/bin/incus storage list --format csv 2>/dev/null | grep -q "^default," && echo "true" || echo "false")
            NETWORK_EXISTS=$(/usr/local/bin/incus network list --format csv 2>/dev/null | grep "^incusbr0," | grep -q ",YES," && echo "true" || echo "false")
            echo "[INFO] Post-preseed state — storage: $STORAGE_EXISTS, network: $NETWORK_EXISTS"
        fi
    else
        echo "[INFO] Partial configuration detected (storage: $STORAGE_EXISTS, network: $NETWORK_EXISTS)"
        echo "[INFO] Using manual configuration for idempotent setup..."
        PRESEED_FAILED=true
    fi

    # Manual configuration (runs if preseed failed or partial state exists)
    if [ "${PRESEED_FAILED:-false}" = "true" ]; then
        if [ "$NETWORK_EXISTS" = "false" ]; then
            echo "[INFO] Creating network incusbr0..."
            if ip link show incusbr0 >/dev/null 2>&1; then
                echo "[INFO] Removing stale bridge incusbr0..."
                ip link set incusbr0 down || true
                ip link delete incusbr0 || true
            fi
            /usr/local/bin/incus network create incusbr0 \
                ipv4.address=auto \
                ipv4.nat=true \
                ipv6.address=auto \
                ipv6.nat=true \
                --description="Default Incus bridge for $ARCH"
        fi

        if [ "$STORAGE_EXISTS" = "false" ]; then
            echo "[INFO] Creating storage pool default..."
            /usr/local/bin/incus storage create default lvm \
                source=vg_incus \
                lvm.thinpool_name=IncusThinPool \
                size=100GiB \
                volume.size=60GiB \
                --description="Incus LVM storage pool for $ARCH"
        fi
    fi

    # Always configure profile (works for both preseed and manual paths)
    echo "[INFO] Configuring default profile..."
    /usr/local/bin/incus profile device set default root pool=default 2>/dev/null || \
        /usr/local/bin/incus profile device add default root disk path=/ pool=default

    /usr/local/bin/incus profile device set default eth0 network=incusbr0 2>/dev/null || \
        /usr/local/bin/incus profile device add default eth0 nic name=eth0 network=incusbr0

    /usr/local/bin/incus profile set default security.nesting=true
    /usr/local/bin/incus profile set default security.syscalls.deny_default=false
    if [ "$ARCH" = "ppc64le" ]; then
        /usr/local/bin/incus profile set default limits.memory=16GiB
        /usr/local/bin/incus profile set default raw.qemu="-m 16384M,slots=0,maxmem=16384M"
    fi
fi
