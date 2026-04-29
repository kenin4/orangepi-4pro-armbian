#!/usr/bin/env bash
set -euo pipefail

# One-shot build script for Orange Pi 4 Pro mainline image with TUN support
# Usage:
#   ./build-opi4pro-tailscale.sh
# Optional env vars:
#   INSTALL_DEPS=0   # skip apt dependency installation
#   RELEASE=bookworm # override distro release

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

INSTALL_DEPS="${INSTALL_DEPS:-1}"
RELEASE="${RELEASE:-bookworm}"
KERNEL_GIT="${KERNEL_GIT:-shallow}"

IMAGE_OUTPUT_DIR="${ROOT_DIR}/output/images"
if [[ -d "${IMAGE_OUTPUT_DIR}" ]]; then
  shopt -s nullglob
  EXISTING_IMAGES=(
    "${IMAGE_OUTPUT_DIR}"/Armbian-unofficial_*_Orangepi-4pro_*.img
    "${IMAGE_OUTPUT_DIR}"/Armbian-unofficial_*_Orangepi-4pro_*.img.xz
    "${IMAGE_OUTPUT_DIR}"/Armbian-unofficial_*_Orangepi-4pro_*.img.sha
    "${IMAGE_OUTPUT_DIR}"/Armbian-unofficial_*_Orangepi-4pro_*.img.txt
  )
  shopt -u nullglob

  if (( ${#EXISTING_IMAGES[@]} > 0 )); then
    echo "[INFO] Removing existing Orange Pi 4 Pro image artifacts..."
    rm -f "${EXISTING_IMAGES[@]}"
  fi
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "[ERROR] This script must run inside Linux (Ubuntu/Debian VM)."
  exit 1
fi

if [[ ! -f "${ROOT_DIR}/compile.sh" ]]; then
  echo "[ERROR] compile.sh not found in ${ROOT_DIR}"
  exit 1
fi

if [[ "${INSTALL_DEPS}" == "1" ]]; then
  echo "[INFO] Installing host dependencies (Ubuntu/Debian)..."
  sudo apt update
  sudo apt install -y \
    git curl wget ca-certificates xz-utils \
    build-essential bc bison flex \
    libssl-dev libelf-dev libncurses-dev \
    python3 python3-pip rsync kmod cpio jq \
    device-tree-compiler qemu-user-static binfmt-support \
    pv zip unzip dosfstools parted
fi

CONFIG_FILE="${ROOT_DIR}/config/kernel/linux-sun60iw2-mainline.config"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "[ERROR] Kernel config file not found: ${CONFIG_FILE}"
  exit 1
fi

echo "[INFO] Ensuring CONFIG_TUN=m in ${CONFIG_FILE}"
if grep -q '^CONFIG_TUN=' "${CONFIG_FILE}"; then
  sed -i 's/^CONFIG_TUN=.*/CONFIG_TUN=m/' "${CONFIG_FILE}"
elif grep -q '^# CONFIG_TUN is not set' "${CONFIG_FILE}"; then
  sed -i 's/^# CONFIG_TUN is not set/CONFIG_TUN=m/' "${CONFIG_FILE}"
else
  echo 'CONFIG_TUN=m' >> "${CONFIG_FILE}"
fi

echo "[INFO] Current TUN/WireGuard settings:"
grep -nE '^CONFIG_TUN=|^CONFIG_WIREGUARD=' "${CONFIG_FILE}" || true

echo "[INFO] Starting build..."
echo "[DEBUG] Host OS release information:"
cat /etc/os-release 2>/dev/null | grep -E "VERSION_CODENAME|VERSION_ID|PRETTY_NAME" || echo "  (could not read os-release)"

chmod +x "${ROOT_DIR}/compile.sh"
"${ROOT_DIR}/compile.sh" build \
  BOARD=orangepi-4pro \
  BRANCH=current \
  BUILD_MINIMAL=yes \
  KERNEL_CONFIGURE=no \
  KERNEL_GIT="${KERNEL_GIT}" \
  RELEASE="${RELEASE}" \
  BOOTSOURCE=https://github.com/u-boot/u-boot.git \
  BOOTBRANCH=branch:master \
  SKIP_EXTERNAL_DRIVERS=yes \
  NO_HOST_RELEASE_CHECK=yes

echo "[INFO] Build finished. Listing images:"
ls -lh "${ROOT_DIR}/output/images" || true

# Prefer raw .img over compressed artifacts and checksum files.
LATEST_IMG="$(ls -1t "${ROOT_DIR}"/output/images/*.img 2>/dev/null | head -n 1 || true)"
if [[ -z "${LATEST_IMG}" ]]; then
  LATEST_IMG="$(ls -1t "${ROOT_DIR}"/output/images/*.img.xz 2>/dev/null | head -n 1 || true)"
fi
if [[ -n "${LATEST_IMG}" ]]; then
  echo "[OK] Latest image: ${LATEST_IMG}"
else
  echo "[ERROR] No .img/.img.xz file found under output/images"
  exit 1
fi

echo "[INFO] Verifying kernel config and tun module from produced linux-image deb (no boot required)..."
LATEST_DEB="$(ls -1t "${ROOT_DIR}"/output/debs/linux-image-*.deb 2>/dev/null | head -n 1 || true)"
if [[ -z "${LATEST_DEB}" ]]; then
  echo "[ERROR] No linux-image-*.deb found in output/debs"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

dpkg-deb -x "${LATEST_DEB}" "${TMP_DIR}"

echo "[INFO] CONFIG_TUN / CONFIG_WIREGUARD in packaged kernel config:"
zgrep -H -E '^CONFIG_TUN=|^# CONFIG_TUN is not set|^CONFIG_WIREGUARD=' "${TMP_DIR}"/boot/config-* || true

if ! zgrep -q '^CONFIG_TUN=m' "${TMP_DIR}"/boot/config-*; then
  echo "[ERROR] CONFIG_TUN is not set to module (m) in packaged kernel config"
  exit 1
fi

if ! zgrep -q '^CONFIG_WIREGUARD=m' "${TMP_DIR}"/boot/config-*; then
  echo "[ERROR] CONFIG_WIREGUARD is not set to module (m) in packaged kernel config"
  exit 1
fi

echo "[INFO] Looking for tun.ko module in packaged modules tree:"
TUN_MODULE_PATH="$(find "${TMP_DIR}/lib/modules" -type f -name 'tun.ko*' -print | head -n 1 || true)"
if [[ -z "${TUN_MODULE_PATH}" ]]; then
  echo "[ERROR] tun.ko module not found in packaged kernel modules"
  exit 1
fi
echo "[OK] Found tun module: ${TUN_MODULE_PATH}"

echo "[INFO] Verifying U-Boot signature in image (offset 8KB)..."
UPSTREAM_SIG_FOUND=0
VENDOR_EXACT_MATCH=0
VENDOR_BOOT0_SIG_FOUND=0
VENDOR_FEX_NONZERO=0

if [[ "${LATEST_IMG}" == *.xz ]]; then
  if xzcat "${LATEST_IMG}" 2>/dev/null | dd bs=1024 skip=8 count=1024 status=none | strings | grep -qi 'u-boot'; then
    UPSTREAM_SIG_FOUND=1
  fi
  if xzcat "${LATEST_IMG}" 2>/dev/null | dd bs=512 skip=256 count=128 status=none | strings | grep -Eqi 'egon|boot0|u-boot|sunxi'; then
    VENDOR_BOOT0_SIG_FOUND=1
  fi
  VENDOR_FEX_NONZERO="$(xzcat "${LATEST_IMG}" 2>/dev/null | dd bs=512 skip=24576 count=128 status=none | tr -d '\000' | wc -c || true)"
else
  if dd if="${LATEST_IMG}" bs=1024 skip=8 count=1024 status=none 2>/dev/null | strings | grep -qi 'u-boot'; then
    UPSTREAM_SIG_FOUND=1
  fi
  if dd if="${LATEST_IMG}" bs=512 skip=256 count=128 status=none 2>/dev/null | strings | grep -Eqi 'egon|boot0|u-boot|sunxi'; then
    VENDOR_BOOT0_SIG_FOUND=1
  fi
  VENDOR_FEX_NONZERO="$(dd if="${LATEST_IMG}" bs=512 skip=24576 count=128 status=none 2>/dev/null | tr -d '\000' | wc -c || true)"

  # Deterministic vendor check: compare packaged boot blobs against image offsets.
  LATEST_UBOOT_DEB="$(ls -1t "${ROOT_DIR}"/output/debs/linux-u-boot-orangepi-4pro-mainline_*.deb 2>/dev/null | head -n 1 || true)"
  if [[ -n "${LATEST_UBOOT_DEB}" ]]; then
    UBOOT_TMP_DIR="${TMP_DIR}/uboot"
    mkdir -p "${UBOOT_TMP_DIR}"
    dpkg-deb -x "${LATEST_UBOOT_DEB}" "${UBOOT_TMP_DIR}"

    UBOOT_BLOB_DIR="$(find "${UBOOT_TMP_DIR}/usr/lib" -mindepth 1 -maxdepth 4 -type d \
      -exec test -f '{}/boot0_sdcard.bin' \; \
      -exec test -f '{}/boot_package.fex' \; -print -quit 2>/dev/null || true)"

    if [[ -n "${UBOOT_BLOB_DIR}" ]]; then
      BOOT0_SIZE="$(stat -c%s "${UBOOT_BLOB_DIR}/boot0_sdcard.bin")"
      FEX_SIZE="$(stat -c%s "${UBOOT_BLOB_DIR}/boot_package.fex")"

      if cmp -s <(dd if="${LATEST_IMG}" bs=1 skip=$((256*512)) count="${BOOT0_SIZE}" status=none 2>/dev/null) "${UBOOT_BLOB_DIR}/boot0_sdcard.bin" \
        && cmp -s <(dd if="${LATEST_IMG}" bs=1 skip=$((24576*512)) count="${FEX_SIZE}" status=none 2>/dev/null) "${UBOOT_BLOB_DIR}/boot_package.fex"; then
        VENDOR_EXACT_MATCH=1
      fi
    fi
  fi
fi

if [[ ${UPSTREAM_SIG_FOUND} -eq 1 ]]; then
  echo "[OK] U-Boot upstream signature detected in image"
elif [[ ${VENDOR_EXACT_MATCH} -eq 1 ]]; then
  echo "[OK] Vendor bootloader blobs match image offsets (boot0/fex)"
elif [[ ${VENDOR_BOOT0_SIG_FOUND} -eq 1 && ${VENDOR_FEX_NONZERO:-0} -gt 0 ]]; then
  echo "[OK] Vendor bootloader blobs detected in image (boot0/fex offsets)"
else
  echo "[ERROR] Bootloader signature/blobs not detected in image (${LATEST_IMG})"
  exit 1
fi

echo "[DONE] Build + artifact verification completed."