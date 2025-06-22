#!/bin/bash
set -euo pipefail

# Usage: ./getNewFP.sh [--logs DIR] [--download DIR] [--output DIR]
# Defaults:
LOG_DIR="./logs"
DOWNLOAD_DIR="./downloads"
METADATA_DIR="./metadata"
OEM="Nothing"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --logs)       LOG_DIR="$2";        shift 2 ;;
    --download)   DOWNLOAD_DIR="$2";   shift 2 ;;
    --output)     METADATA_DIR="$2";   shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--logs DIR] [--download DIR] [--output DIR]"; exit 0 ;;
    *)
      echo "Unknown option: $1"; exit 1 ;;
  esac
done

mkdir -p "$DOWNLOAD_DIR" "$METADATA_DIR"

shopt -s nullglob
diff_files=("$LOG_DIR"/*.diff)
(( ${#diff_files[@]} == 0 )) && { echo "No .diff files found."; exit 0; }

for diff_file in "${diff_files[@]}"; do
  device=$(basename "$diff_file" .diff)
  log_file="$LOG_DIR/${device}.log"

  # 1. Extract OTA URL and Download
  ota_url=$(grep -m1 'OTA URL obtained:' "$log_file" | awk '{print $NF}')
  [[ -z "$ota_url" ]] && { echo "Skip $device: no OTA URL."; continue; }
  zip_name=$(basename "$ota_url")
  curl -L -o "$DOWNLOAD_DIR/$zip_name" "$ota_url"

  # 2. Extract metadata
  meta_file="$METADATA_DIR/${device}_metadata.txt"
  unzip -p "$DOWNLOAD_DIR/$zip_name" "META-INF/com/android/metadata" > "$meta_file"

  # 3. Get the first post-build FingerPrint from metadata
  fp=$(grep '^post-build=' "$meta_file" | cut -d'=' -f2 | cut -d'|' -f1)
  echo "Device: $device → New FP: $fp"

  # 4. Split FP into six parts
  #    Format: <oem>/<product>/<device>:<android_version>/<build_tag>/<incremental>:user/release-keys
  IFS=':/'; read -r new_oem new_product new_device android_version build_tag incremental _ <<< "$fp"

  cfg="${OEM}/${device}.yml"
  [[ -f "$cfg" ]] || { echo "Config $cfg not found, skipping."; continue; }

  # 5. Update line 4 (comment out old FP)
  #    Assume line 4 is a # comment with the FingerPrint example
  sed -i "4s@^#.*@#   ${fp}@" "$cfg"

  # 6. If the following keys have different values from the new FP, replace them
  #    build_tag, incremental, android_version, oem, device, product
  sed -ri \
    -e "s@^(build_tag:[[:space:]]*)\"[^\"]*\"(.*)@\1\"${build_tag}\"\2@" \
    -e "s@^(incremental:[[:space:]]*)\"[^\"]*\"(.*)@\1\"${incremental}\"\2@" \
    -e "s@^(android_version:[[:space:]]*)\"[^\"]*\"(.*)@\1\"${android_version}\"\2@" \
    -e "s@^(oem:[[:space:]]*)\"[^\"]*\"(.*)@\1\"${new_oem}\"\2@" \
    -e "s@^(device:[[:space:]]*)\"[^\"]*\"(.*)@\1\"${new_device}\"\2@" \
    -e "s@^(product:[[:space:]]*)\"[^\"]*\"(.*)@\1\"${new_product}\"\2@" \
    "$cfg"

  echo "✅ Updated config: $cfg"
  echo "----------------------------------------"
done

# Clean up
rm -rf "$DOWNLOAD_DIR" "$METADATA_DIR" "$LOG_DIR"/*.diff
echo "All devices processed. New FingerPrints updated in respective config files."
