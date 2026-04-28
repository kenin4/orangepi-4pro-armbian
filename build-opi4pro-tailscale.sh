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
  BRANCH=mainline \
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
if [[ "${LATEST_IMG}" == *.xz ]]; then
  if ! xzcat "${LATEST_IMG}" 2>/dev/null | dd bs=1024 skip=8 count=1024 status=none | strings | grep -qi 'u-boot'; then
    echo "[ERROR] U-Boot signature not found in compressed image (${LATEST_IMG})"
    exit 1
  fi
else
  if ! dd if="${LATEST_IMG}" bs=1024 skip=8 count=1024 status=none 2>/dev/null | strings | grep -qi 'u-boot'; then
    echo "[ERROR] U-Boot signature not found in image (${LATEST_IMG})"
    exit 1
  fi
fi
echo "[OK] U-Boot signature detected in image"

echo "[DONE] Build + artifact verification completed."