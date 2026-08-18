#!/bin/bash
################################################################################
##  File:  setup-lvm.sh
##  Desc:  Create the LVM loop device, PV, and VG for Incus storage
##  Note:  Sourced by install-incus.sh. Expects USE_LVM, LVM_VG_NAME,
##         LVM_LOOP_SIZE, and LVM_LOOP_FILE to be set by the caller.
################################################################################

if [ "$USE_LVM" != "true" ]; then
    echo "[INFO] LVM storage disabled, using DIR storage"
    return 0
fi

echo "[INFO] Setting up LVM storage for Incus..."

# If the VG already exists we have nothing to do.
if vgs "$LVM_VG_NAME" &>/dev/null; then
    echo "[INFO] Volume group $LVM_VG_NAME already exists, skipping creation"
    return 0
fi

# VG is absent — clean up any stale loop devices or PVs from a
# previous partial run before creating fresh ones.
echo "[INFO] Cleaning up any stale loop devices backed by $LVM_LOOP_FILE..."
for dev in $(losetup -j "$LVM_LOOP_FILE" 2>/dev/null | cut -d: -f1); do
    echo "[INFO] Detaching stale loop device: $dev"
    pvremove -ff -y "$dev" 2>/dev/null || true
    losetup -d "$dev" 2>/dev/null || true
done

# Create directory and loop device file
mkdir -p "$(dirname "$LVM_LOOP_FILE")"
if [ ! -f "$LVM_LOOP_FILE" ]; then
    echo "[INFO] Creating loop device file: $LVM_LOOP_FILE ($LVM_LOOP_SIZE)"
    truncate -s "$LVM_LOOP_SIZE" "$LVM_LOOP_FILE"
else
    echo "[INFO] Loop device file already exists: $LVM_LOOP_FILE"
fi

# Setup loop device
echo "[INFO] Setting up loop device..."
LOOP_DEV=$(losetup -f --show "$LVM_LOOP_FILE")
echo "[INFO] Loop device created: $LOOP_DEV"

# Create physical volume
echo "[INFO] Creating physical volume on $LOOP_DEV..."
wipefs -af "$LOOP_DEV" 2>/dev/null || true
pvremove -ff -y "$LOOP_DEV" 2>/dev/null || true
pvcreate "$LOOP_DEV"

# Create volume group
echo "[INFO] Creating volume group: $LVM_VG_NAME..."
vgcreate "$LVM_VG_NAME" "$LOOP_DEV"

# Verify creation
echo "[INFO] Verifying LVM setup..."
pvs | grep "$LOOP_DEV"
vgs | grep "$LVM_VG_NAME"

# Make loop device persistent across reboots
echo "[INFO] Making loop device persistent..."
cat > /etc/systemd/system/incus-lvm-loop.service << EOF
[Unit]
Description=Setup Incus LVM loop device
DefaultDependencies=no
Before=lvm2-activation-early.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/sbin/losetup -f $LVM_LOOP_FILE
RemainAfterExit=yes

[Install]
WantedBy=local-fs.target
EOF

systemctl daemon-reload
systemctl enable incus-lvm-loop.service

echo "[INFO] LVM storage setup complete"
echo "[INFO] Volume Group: $LVM_VG_NAME"
echo "[INFO] Loop Device: $LOOP_DEV"
echo "[INFO] Loop File: $LVM_LOOP_FILE"
