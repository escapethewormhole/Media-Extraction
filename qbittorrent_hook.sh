#!/usr/bin/env bash
# qBittorrent post-download hook wrapper
# This script is called by qBittorrent after a torrent completes downloading.
#
# qBittorrent passes these variables:
#   %D = save path (directory where torrent was saved)
#   %F = content path (first file in the torrent)
#   %N = torrent name
#   %L = category (if you've set categories in qBittorrent)
#   %T = tags (comma-separated)
#
# USAGE in qBittorrent:
#   Preferences → Downloads → "Run external program on torrent completion"
#   Command: /Volumes/Vault/qbittorrent_hook.sh "%D" "%L" "%N"

# ===== Configuration =====
MAIN_SCRIPT="/Volumes/Vault/extract_and_filebot.sh"
HOOK_LOG="/tmp/qbittorrent_hook.log"
MAIN_LOG="/tmp/extract_and_filebot_qbt.log"

# ===== Logging =====
log_hook() {
  echo "[$(date '+%F %T')] $*" >> "$HOOK_LOG"
}

# ===== Main Logic =====
DOWNLOAD_PATH="${1:-}"
CATEGORY="${2:-}"
TORRENT_NAME="${3:-}"

# Log the trigger
log_hook "========================================="
log_hook "qBittorrent Download Complete"
log_hook "Download Path: $DOWNLOAD_PATH"
log_hook "Category: ${CATEGORY:-none}"
log_hook "Torrent Name: ${TORRENT_NAME:-unknown}"
log_hook "========================================="

# Validate inputs
if [[ -z "$DOWNLOAD_PATH" ]]; then
  log_hook "ERROR: No download path provided. Exiting."
  exit 1
fi

if [[ ! -e "$DOWNLOAD_PATH" ]]; then
  log_hook "ERROR: Download path does not exist: $DOWNLOAD_PATH"
  exit 1
fi

# Check if main script exists
if [[ ! -f "$MAIN_SCRIPT" ]]; then
  log_hook "ERROR: Main script not found: $MAIN_SCRIPT"
  exit 1
fi

# Optional: Category-based filtering
# Uncomment to only process specific categories:
# case "$CATEGORY" in
#   tv|movies|media)
#     log_hook "Category '$CATEGORY' matched, processing..."
#     ;;
#   *)
#     log_hook "Category '$CATEGORY' not in allowed list, skipping."
#     exit 0
#     ;;
# esac

# Set proper environment (especially PATH for homebrew installations)
export PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/opt/local/bin:$PATH"

# Optional: Set custom configuration for qBittorrent-triggered runs
# export QUIET=1                    # Suppress already-processed messages
# export PARALLEL_JOBS=2            # Process multiple torrents in parallel
# export FILEBOT_RETRY=3            # Retry FileBot operations
# export ENABLE_NOTIFICATIONS=1     # Show macOS notifications

# Construct full path to the specific torrent content
# This prevents scanning the entire download directory if %D is a shared root
TARGET_PATH="$DOWNLOAD_PATH/$TORRENT_NAME"
log_hook "Targeting specific torrent path: $TARGET_PATH"

# Run the main script in background so qBittorrent doesn't wait
# Redirect all output to dedicated log file
nohup bash "$MAIN_SCRIPT" "$TARGET_PATH" >> "$MAIN_LOG" 2>&1 &

SCRIPT_PID=$!
log_hook "Main script started with PID: $SCRIPT_PID"

# Exit immediately so qBittorrent can continue
exit 0
