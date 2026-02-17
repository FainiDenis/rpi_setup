#!/usr/bin/env bash
set -euo pipefail

# ---- USER SETTINGS ----
LUKS_PART="${1:-/dev/sda1}"         # e.g. /dev/sdb2
MAPPER_NAME="${2:-4tb_hdd_crypt}"
MOUNTPOINT="${3:-/mnt/4TB_HDD}"
FSTYPE="${4:-ext4}"        # ext4/xfs/btrfs...
# ----------------------

if [[ -z "${LUKS_PART}" ]]; then
  echo "Usage: sudo $0 /dev/sdXn [mapper_name] [mountpoint] [fstype]"
  exit 1
fi

if [[ ! -b "${LUKS_PART}" ]]; then
  echo "Error: ${LUKS_PART} is not a block device."
  exit 1
fi

echo "[1/6] Getting LUKS UUID..."
LUKS_UUID="$(cryptsetup luksUUID "${LUKS_PART}")"
echo "  LUKS_UUID=${LUKS_UUID}"

echo "[2/6] Ensuring mountpoint exists: ${MOUNTPOINT}"
mkdir -p "${MOUNTPOINT}"

echo "[3/6] Unlocking once to discover filesystem UUID (you may be prompted)..."
# Unlock if not already unlocked
if [[ ! -e "/dev/mapper/${MAPPER_NAME}" ]]; then
  cryptsetup open "${LUKS_PART}" "${MAPPER_NAME}"
fi

echo "[4/6] Getting filesystem UUID..."
FS_UUID="$(blkid -s UUID -o value "/dev/mapper/${MAPPER_NAME}")"
if [[ -z "${FS_UUID}" ]]; then
  echo "Error: Could not determine filesystem UUID for /dev/mapper/${MAPPER_NAME}."
  exit 1
fi
echo "  FS_UUID=${FS_UUID}"

CRYPTTAB_LINE="${MAPPER_NAME} UUID=${LUKS_UUID} none nofail,x-systemd.device-timeout=10s"
FSTAB_LINE="UUID=${FS_UUID} ${MOUNTPOINT} ${FSTYPE} defaults,nofail,x-systemd.device-timeout=10s,x-systemd.automount 0 2"

echo "[5/6] Updating /etc/crypttab (idempotent)..."
grep -qE "^${MAPPER_NAME}[[:space:]]" /etc/crypttab 2>/dev/null || echo "${CRYPTTAB_LINE}" >> /etc/crypttab

echo "[6/6] Updating /etc/fstab (idempotent)..."
grep -qE "[[:space:]]${MOUNTPOINT}[[:space:]]" /etc/fstab || echo "${FSTAB_LINE}" >> /etc/fstab

echo "Done."
echo "crypttab: ${CRYPTTAB_LINE}"
echo "fstab:    ${FSTAB_LINE}"
echo
systemctl daemon-reload
sudo mount -a
ls ${MOUNTPOINT}
