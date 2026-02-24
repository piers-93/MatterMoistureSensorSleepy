#!/usr/bin/env bash
set -euo pipefail

# generate_factory_partition.sh
# Small helper to run esp-matter-mfg-tool with sensible defaults and easy overrides.

VID="${VID:-0xFFF2}"
PID="${PID:-0x8001}"
VENDOR_NAME="${VENDOR_NAME:-Piers Matters}"
PRODUCT_NAME="${PRODUCT_NAME:-Soil Moisture Sensor}"
HW_VER="${HW_VER:-1}"
HW_VER_STR="${HW_VER_STR:-ICM 755}"
MATTER_SDK_PATH="${MATTER_SDK_PATH:-${ESP_MATTER_PATH:-}/connectedhomeip/connectedhomeip}"
PAI_KEY="${PAI_KEY:-$MATTER_SDK_PATH/credentials/test/attestation/Chip-Test-PAI-FFF2-8001-Key.pem}"
PAI_CERT="${PAI_CERT:-$MATTER_SDK_PATH/credentials/test/attestation/Chip-Test-PAI-FFF2-8001-Cert.pem}"
CD="${CD:-$MATTER_SDK_PATH/credentials/test/certification-declaration/Chip-Test-CD-FFF2-8001.der}"
PORT="${PORT:-/dev/ttyACM0}"
TARGET="${TARGET:-esp32h2}"
EFUSE_KEY_ID="${EFUSE_KEY_ID:-1}"
FLASH_ADDR="${FLASH_ADDR:-0x10000}"
BAUD="${BAUD:-460800}"
# Use factory partition mode by default (no secure-cert flags)
# Set USE_SECURE_CERT=1 to use esp_secure_cert partition instead
USE_SECURE_CERT="${USE_SECURE_CERT:-0}"

DRY_RUN=0

usage() {
    cat <<EOF
Usage: $0 [--dry-run] [-- <extra esp-matter-mfg-tool args>]

Environment variables override defaults: VID, PID, VENDOR_NAME, PRODUCT_NAME,
HW_VER, HW_VER_STR, MATTER_SDK_PATH, PAI_KEY, PAI_CERT, CD, PORT, TARGET,
EFUSE_KEY_ID, FLASH_ADDR (default 0x10000), BAUD (default 460800)

Example:
  VID=0xFFF2 PRODUCT_NAME="My Lamp" $0 --dry-run
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi

# Build the command as an array to handle spaces safely
cmd=(esp-matter-mfg-tool -v "$VID" -p "$PID" --vendor-name "$VENDOR_NAME" \
     --product-name "$PRODUCT_NAME" --hw-ver "$HW_VER" --hw-ver-str "$HW_VER_STR" --pai \
     -k "$PAI_KEY" -c "$PAI_CERT" -cd "$CD")

# Add secure-cert flags only if USE_SECURE_CERT=1
if [ "$USE_SECURE_CERT" -eq 1 ]; then
    cmd+=(--dac-in-secure-cert --commissionable-data-in-secure-cert --rd-id-uid-in-secure-cert)
fi

cmd+=(--target "$TARGET" --port "$PORT")

# Append any remaining user-supplied args
if [ "$#" -gt 0 ]; then
    cmd+=("$@")
fi

echo "Running esp-matter-mfg-tool with the following command:"
printf '%q ' "${cmd[@]}"
echo

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry-run: command not executed. Export environment variables to override defaults and re-run without --dry-run."
    exit 0
fi

"${cmd[@]}"

# Find the most recently generated partition .bin file
PARTITION_BIN=$(find out/ -name "*-partition.bin" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | awk '{print $2}')

if [ -z "$PARTITION_BIN" ]; then
    echo "No partition .bin file found in out/ – skipping flash prompt."
    exit 0
fi

echo
echo "Generated partition file: $PARTITION_BIN"
echo
read -rp "Flash to device? (y/N) " FLASH_CONFIRM
case "$FLASH_CONFIRM" in
    [yY]|[yY][eE][sS])
        FLASH_CMD=(esptool.py --chip "$TARGET" --port "$PORT" --baud "$BAUD" write_flash "$FLASH_ADDR" "$PARTITION_BIN")
        echo "Running: $(printf '%q ' "${FLASH_CMD[@]}")"
        echo
        "${FLASH_CMD[@]}"
        ;;
    *)
        echo "Skipping flash."
        ;;
esac
