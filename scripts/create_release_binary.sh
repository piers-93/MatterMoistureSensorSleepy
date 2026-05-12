#!/usr/bin/env bash
set -euo pipefail

# create_release_binary.sh
# Merges all firmware binaries into a single flashable image for GitHub releases.
# Usage: ./scripts/create_release_binary.sh [factory_partition.bin]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/../build"
TARGET="${TARGET:-esp32h2}"
OUTPUT_DIR="$SCRIPT_DIR/full_image"
OUTPUT="${OUTPUT:-$OUTPUT_DIR/icd_app_full.bin}"

# Factory partition: pass as argument or auto-detect latest from out/
if [ "${1:-}" != "" ]; then
    FACTORY_BIN="$1"
else
    FACTORY_BIN=$(find "$SCRIPT_DIR/out" -name "*-partition.bin" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | awk '{print $2}')
fi

if [ -z "${FACTORY_BIN:-}" ] || [ ! -f "$FACTORY_BIN" ]; then
    echo "ERROR: No factory partition .bin found. Pass it as argument or run generate_factory_partition.sh first."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Using factory partition: $FACTORY_BIN"
echo "Output: $OUTPUT"
echo

esptool.py --chip "$TARGET" merge_bin \
    -o "$OUTPUT" \
    --flash_mode dio --flash_freq 48m --flash_size 4MB \
    0x0     "$BUILD_DIR/bootloader/bootloader.bin" \
    0xc000  "$BUILD_DIR/partition_table/partition-table.bin" \
    0x1d000 "$BUILD_DIR/ota_data_initial.bin" \
    0x20000 "$BUILD_DIR/icd_app.bin" \
    0x10000 "$FACTORY_BIN"

FACTORY_DIR="$(dirname "$FACTORY_BIN")"
QRCODE=$(find "$FACTORY_DIR" -maxdepth 1 -name "*.png" | head -1)

echo
echo "Done: $OUTPUT"
echo "Flash with:"
echo "  esptool.py --chip $TARGET write_flash 0x0 $OUTPUT"
echo
echo "Factory partition folder: $FACTORY_DIR"
if [ -n "$QRCODE" ]; then
    QRCODE_DEST="$OUTPUT_DIR/$(basename "$QRCODE")"
    cp "$QRCODE" "$QRCODE_DEST"
    echo "QR code copied to:        $QRCODE_DEST"
else
    echo "QR code image:            (not found in $FACTORY_DIR)"
fi
