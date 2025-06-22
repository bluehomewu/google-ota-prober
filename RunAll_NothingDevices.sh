#!/bin/bash
set -euo pipefail

# Usage: ./RunAll_NothingDevices.sh [--log-dir DIR]
# Default log directory is "./logs"
LOG_DIR="./logs"

# Read Telegram Bot configuration file
CONFIG_FILE="./Telegram.config"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Cannot find $CONFIG_FILE. Please create it with TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID."
    exit 1
fi

# Parse TOKEN and CHAT_ID from config
TELEGRAM_BOT_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "$CONFIG_FILE" | cut -d '=' -f2-)
TELEGRAM_CHAT_ID=$(grep '^TELEGRAM_CHAT_ID=' "$CONFIG_FILE" | cut -d '=' -f2-)

if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    echo "Error: Please define both TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in $CONFIG_FILE."
    exit 1
fi

# Define function to send Telegram messages
send_telegram() {
    local msg="$1"
    # Need to use --data-urlencode "text=${msg}" to correctly send line breaks (%0A) to Telegram
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
         -d chat_id="${TELEGRAM_CHAT_ID}" \
         -d parse_mode="Markdown" \
         --data-urlencode "text=${msg}" \
         > /dev/null
}

# Args parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--log-dir)
      LOG_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--log-dir DIR]"; exit 0 ;;
    *)
      echo "Unknown option: $1"; echo "Usage: $0 [--log-dir DIR]"; exit 1 ;;
  esac
done

mkdir -p "$LOG_DIR"
declare -a changed_devices=()

oem="Nothing"

echo "----------------------------------------"
for config_file in "$oem"/*.yml; do
    device_name=$(basename "$config_file" .yml)
    echo "# Running OTA check for device: $device_name"

    tmp_out="$LOG_DIR/${device_name}.log.new"

    # Print Python output to both screen and file
    python probe.py --config "$config_file" 2>&1 | tee "$tmp_out"
    code=${PIPESTATUS[0]}

    if [[ $code -eq 0 ]]; then
        echo "# OTA check completed successfully for device: $device_name"
    else
        echo "# OTA check failed for device: $device_name"
    fi
    echo "----------------------------------------"

    old_log="$LOG_DIR/${device_name}.log"
    if [[ -f "$old_log" ]]; then
        if ! diff -q "$old_log" "$tmp_out" > /dev/null; then
            echo "########################################"
            echo "# Differences found for device: $device_name #"
            echo "########################################"
            echo "----------------------------------------"
            # Write diff file, but do not abort even if diff returns 1
            diff "$old_log" "$tmp_out" > "$LOG_DIR/${device_name}.diff" || true
            changed_devices+=("$device_name")
        fi
    else
        echo "# No previous log for device: $device_name, saving current output"
    fi

    # Finally, overwrite old log with new version
    mv "$tmp_out" "$old_log"
done

# Display all devices with differences at once
if (( ${#changed_devices[@]} > 0 )); then
    echo "=== Devices with differences ==="
    for dev in "${changed_devices[@]}"; do
        echo "- $dev"
    done

    # Combine Telegram message: start with title
    # 1) First use ANSI-C quoting to create a title with real line breaks + empty line
    msg=$'🚀 *Nothing OTA Updates Detected*\n\n'

    # 2) Accumulate the name of each device with updates + its log content (preceded by > as a blockquote) into msg
    for dev in "${changed_devices[@]}"; do
        msg+="${dev}:"$'\n'
        while IFS= read -r line; do
            msg+="> ${line}"$'\n'
        done < "$LOG_DIR/${dev}.log"
        msg+=$'\n'
    done

    # 3) Send it out
    send_telegram "$msg"

    # 4) Update New FingerPrints in respective config files
    ## Use `getNewFP.sh` script to extract and update FingerPrints
    echo "----------------------------------------"
    echo "Updating New FingerPrints in respective config files..."
    bash getNewFP.sh
else
    echo "=== No differences detected for any device. ==="
    # If you want to notify even when there are no updates, you can uncomment the line below:
    # send_telegram "No OTA updates detected for any Nothing device."
fi
