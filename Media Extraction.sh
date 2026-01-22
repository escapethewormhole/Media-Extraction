#!/usr/bin/env bash
# macOS-safe (Bash 3.2+). Keeps originals untouched. Idempotent; set FORCE=1 to re-run extraction & sorting.
#
# USAGE:
#   Basic:           ./extract_and_filebot.sh "/path/to/media"
#   Force re-extract: FORCE=1 ./extract_and_filebot.sh "/path"
#   Parallel:        PARALLEL_JOBS=4 ./extract_and_filebot.sh "/path"
#   Dry-run:         DRY_RUN=1 ./extract_and_filebot.sh "/path"
#   Show progress:   PROGRESS=1 ./extract_and_filebot.sh "/path"
#   With retry:      FILEBOT_RETRY=3 ./extract_and_filebot.sh "/path"
#   Quiet mode:      QUIET=1 ./extract_and_filebot.sh "/path"  # suppress "already processed" logs
#
set -euo pipefail
IFS=$'\n\t'

# ===== Logging =====
LOG_FILE="/tmp/extract_and_filebot.log"
mkdir -p /tmp
log(){
  local msg
  msg="[$(date '+%F %T')] $*"
  # Print to stderr to protect stdout for command capture
  printf '%s\n' "$msg" | tee -a "$LOG_FILE" >&2
}

# ===== Config =====
CONFIG_FILE="${CONFIG_FILE:-${HOME}/.extract_and_filebot.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
  log "Loading configuration from: $CONFIG_FILE"
  source "$CONFIG_FILE"
fi

# ===== CONFIG =====
WATCH_DIR="${1:-/Volumes/Vault/Media New}"   # qBittorrent: pass "%D"
DEST_ROOT="/Volumes/Vault/Extracted Media"   # Output library root
TV_DIR="${TV_DIR:-$DEST_ROOT/TV Shows}"      # Configurable TV destination
MOVIE_DIR="${MOVIE_DIR:-$DEST_ROOT/Movies}"  # Configurable movie destination
SEVENZ="${SEVENZ:-$(command -v 7zz >/dev/null 2>&1 && echo 7zz || echo 7z)}"  # prefer 7zz if available
FILEBOT="${FILEBOT:-filebot}"
TMP_SUFFIX=".extract_tmp"                    # temp dir created next to source
FORCE="${FORCE:-0}"                          # set FORCE=1 to re-extract and re-process
PROGRESS="${PROGRESS:-0}"                    # set PROGRESS=1 to show extractor progress when run in a TTY
MIN_RAR_AGE="${MIN_RAR_AGE:-60}"             # minimum seconds since last modification before extracting archives
DRY_RUN="${DRY_RUN:-0}"                      # set DRY_RUN=1 to simulate without making changes
PARALLEL_JOBS="${PARALLEL_JOBS:-2}"          # set to >1 for parallel processing
FILEBOT_RETRY="${FILEBOT_RETRY:-3}"          # number of retry attempts for FileBot
VERIFY_VIDEO="${VERIFY_VIDEO:-1}"            # set to 1 to verify video integrity with ffprobe
MIN_PARTS_FOR_MINISERIES="${MIN_PARTS_FOR_MINISERIES:-5}"  # Parts threshold for miniseries detection
MAX_VIDS_FOR_MOVIE="${MAX_VIDS_FOR_MOVIE:-2}"              # Max videos for movie vs TV detection
POST_PROCESS_SCRIPT="${POST_PROCESS_SCRIPT:-}"             # Optional script to run after successful processing
ENABLE_NOTIFICATIONS="${ENABLE_NOTIFICATIONS:-1}"          # macOS notifications (1=enabled)
DISK_SPACE_MARGIN="${DISK_SPACE_MARGIN:-2.5}"              # Multiplier for required free space (default 2.5x archive size)
QUIET="${QUIET:-0}"                                        # set QUIET=1 to suppress "already processed" messages
LOCKFILE="${LOCKFILE:-/tmp/extract_and_filebot.lock}"      # lockfile to prevent concurrent runs
LOCK_TIMEOUT="${LOCK_TIMEOUT:-3600}"                       # max age of lockfile before considering it stale (seconds)
TEMP_DIR_MAX_AGE="${TEMP_DIR_MAX_AGE:-86400}"              # max age of .extract_tmp dirs before cleanup (24 hours)
STREAM_MODE="${STREAM_MODE:-1}"                            # set to 1 to start processing immediately (no progress counter)

require_bin(){ command -v "$1" >/dev/null 2>&1 || { log "Missing required command: $1"; exit 1; }; }

# ===== macOS Notification Helper =====
notify_mac(){
  [[ "$ENABLE_NOTIFICATIONS" != "1" ]] && return 0
  local title="$1" message="$2"
  osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
}

# ===== Lockfile to Prevent Concurrent Runs =====
acquire_lock(){
  local wait_start
  wait_start=$(date +%s)
  
  while [[ -f "$LOCKFILE" ]]; do
    local lock_age
    lock_age=$(( $(date +%s) - $(stat -f %m "$LOCKFILE" 2>/dev/null || stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0) ))
    
    if (( lock_age > LOCK_TIMEOUT )); then
      log "Stale lockfile detected (age: ${lock_age}s). Removing and continuing."
      rm -f "$LOCKFILE"
      break
    fi
    
    # Check if we've been queued for too long (e.g., 2 hours)
    local queued_time=$(( $(date +%s) - wait_start ))
    if (( queued_time > 7200 )); then
      log "Error: Waited too long for lock (${queued_time}s). Exiting to prevent zombie accumulation."
      exit 1
    fi
    
    # Only log sparingly to avoid spamming
    if (( queued_time % 60 < 5 )); then
      log "Another instance is running. Waiting in queue... (${queued_time}s)"
    fi
    
    sleep 5
  done
  
  echo $$ > "$LOCKFILE"
  trap "rm -f '$LOCKFILE'" EXIT
}

# ===== Cleanup Stale Temp Directories =====
cleanup_stale_temps(){
  local now=$(date +%s)
  local cleaned=0
  local tmp mtime age
  
  # Process substitution avoids subshell variable loss
  while IFS= read -r tmp; do
    mtime=$(stat -f %m "$tmp" 2>/dev/null || stat -c %Y "$tmp" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    if (( age > TEMP_DIR_MAX_AGE )); then
      log "Cleaning stale temp directory (age: ${age}s / ${TEMP_DIR_MAX_AGE}s max): $(basename "$tmp")"
      if [[ "$DRY_RUN" != "1" ]]; then
        rm -rf "$tmp" && ((cleaned++))
      fi
    fi
  done < <(find "$WATCH_DIR" -type d -name "*$TMP_SUFFIX" 2>/dev/null)
  
  # Safe for set -e: use || true to prevent exit
  [[ $cleaned -gt 0 ]] && log "Cleaned $cleaned stale temp directories" || true
}

# ===== Global Array for Failed Directories =====
declare -a FAILED_DIRS

# ===== Disk Space Validation =====
check_disk_space(){
  local archive_dir="$1" dest_dir="$2"
  # Calculate total size of archives (in KB)
  local archive_size avail_space
  archive_size=$(find "$archive_dir" -maxdepth 1 -type f \( -iname "*.rar" -o -iname "*.7z" -o -iname "*.zip" \) -exec stat -f %z {} \; 2>/dev/null | awk '{sum+=$1} END {print int(sum/1024)}' || echo 0)
  [[ "$archive_size" -eq 0 ]] && return 0  # No archives found or stat failed
  
  # Get available space on destination (in KB)
  avail_space=$(df -k "$dest_dir" 2>/dev/null | tail -1 | awk '{print $4}' || echo 0)
  
  # Require DISK_SPACE_MARGIN times the archive size (default 2.5x for safety)
  local required
  required=$(awk -v size="$archive_size" -v margin="$DISK_SPACE_MARGIN" 'BEGIN {print int(size * margin)}')
  
  if (( avail_space < required )); then
    log "ERROR: Insufficient disk space. Required: ${required}KB (${archive_size}KB × $DISK_SPACE_MARGIN), Available: ${avail_space}KB"
    return 1
  fi
  log "Disk space check OK: ${avail_space}KB available, ${required}KB required"
  return 0
}

# ===== Retry with Exponential Backoff =====
retry_with_backoff(){
  local max_attempts="$FILEBOT_RETRY" attempt=1 delay=5
  local cmd=("$@")
  
  while (( attempt <= max_attempts )); do
    if "${cmd[@]}"; then
      return 0
    fi
    if (( attempt < max_attempts )); then
      log "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
      sleep "$delay"
      delay=$((delay * 2))
    fi
    ((attempt++))
  done
  log "All $max_attempts attempts failed"
  return 1
}

# ===== Video Integrity Verification =====
verify_video_integrity(){
  [[ "$VERIFY_VIDEO" != "1" ]] && return 0
  local video_file="$1"
  if ! command -v ffprobe >/dev/null 2>&1; then
    log "Warning: ffprobe not found, skipping video verification"
    return 0
  fi
  if ffprobe -v error -show_format -show_streams "$video_file" >/dev/null 2>&1; then
    log "Video integrity verified: $(basename "$video_file")"
    return 0
  else
    log "WARNING: Video integrity check failed: $(basename "$video_file")"
    return 1
  fi
}

# ===== Helpers =====
stat_list(){
  local dir="$1"
  if stat -f '%N %z %m' / >/dev/null 2>&1; then
    find "$dir" -maxdepth 1 -type f \( -iname "*.rar" -o -iname "*.RAR" \) -exec stat -f '%N %z %m' {} \; 2>/dev/null
  else
    find "$dir" -maxdepth 1 -type f \( -iname "*.rar" -o -iname "*.RAR" \) -exec stat -c '%n %s %Y' {} \; 2>/dev/null
  fi | LC_ALL=C sort
}

dir_signature(){
  local dir="$1" list
  list=$(stat_list "$dir")
  if command -v md5 >/dev/null 2>&1; then
    printf "%s" "$list" | md5 -q
  else
    printf "%s" "$list" | md5sum | awk '{print $1}'
  fi
}

# ===== Extraction (FORCE aware, idempotent) =====
_extract_one(){
  local rar="$1" out="$2"
  [[ "$DRY_RUN" == "1" ]] && { log "DRY-RUN: would extract $rar to $out"; return 0; }
  
  mkdir -p "$out"
  if [[ "${PROGRESS:-0}" == "1" ]] && [[ -t 2 ]] || [[ -n "${TERM:-}" ]]; then
    # Interactive mode: redirect stdout to stderr to protect path capture
    if "$SEVENZ" x -y -aou -mmt=on -bsp1 -bso2 "$rar" -o"$out" >&2; then
      return 0
    fi
    if command -v unar >/dev/null 2>&1; then
      unar -force-overwrite -o "$out" "$rar" >&2 && return 0
    fi
    return 1
  else
    # Non-interactive / quiet (e.g., qBittorrent hook)
    if "$SEVENZ" x -y -aou -mmt=on "$rar" -o"$out" >/dev/null 2>&1; then
      return 0
    fi
    if command -v unar >/dev/null 2>&1; then
      unar -quiet -force-overwrite -o "$out" "$rar" >/dev/null 2>&1 && return 0
    fi
    return 1
  fi
}

extract_rars_in_dir(){
  local dir="$1"
  
  # Safety: no symlinks
  if [[ -L "$dir" ]]; then
    log "Security: refusing to process symlink: $dir"
    return 0
  fi
  
  shopt -s nullglob
  # Supported Formats: rar, 7z, zip
  local rars=(
    "$dir"/*.rar "$dir"/*.RAR \
    "$dir"/*.part1.rar "$dir"/*.part01.rar \
    "$dir"/*.r[0-9][0-9] "$dir"/*.R[0-9][0-9] \
    "$dir"/*.001 "$dir"/*.002 \
    "$dir"/*.7z "$dir"/*.7Z \
    "$dir"/*.zip "$dir"/*.ZIP
  )
  shopt -u nullglob
  (( ${#rars[@]} == 0 )) && return 0

  local sig_file="$dir/.extract_sig"
  local done_file="$dir/.extract_done"

  # ===== FAST PATH =====
  # Skip already processed directories unless RARs are newer
  if [[ -f "$done_file" ]] && [[ "$FORCE" != "1" ]]; then
    local done_mtime rar_mtime has_newer=0
    
    # Get done file modification time
    if done_mtime=$(stat -f %m "$done_file" 2>/dev/null); then
      :
    else
      done_mtime=$(stat -c %Y "$done_file" 2>/dev/null || echo 0)
    fi
    
    # Check if any RAR is newer than the done file
    for rar in "${rars[@]}"; do
      [[ -e "$rar" ]] || continue
      if rar_mtime=$(stat -f %m "$rar" 2>/dev/null); then
        :
      else
        rar_mtime=$(stat -c %Y "$rar" 2>/dev/null || echo 0)
      fi
      if (( rar_mtime > done_mtime )); then
        has_newer=1
        break
      fi
    done
    
    # If no RARs are newer, skip this directory entirely (fast path!)
    if [[ $has_newer -eq 0 ]]; then
      [[ "$QUIET" != "1" ]] && log "Already processed (fast-skip): $(basename "$dir")"
      return 0
    else
      log "New/modified RARs detected (newer than .extract_done); reprocessing: $dir"
    fi
  fi
  # ===== END FAST PATH =====

  # Wait for files to settle if they are recently modified (still downloading)
  local max_settle_wait=600  # wait up to 10 minutes
  local start_wait
  start_wait=$(date +%s)

  while true; do
    local now
    now=$(date +%s)
    local settled=1
    local youngest_age=999999
    local target_rar=""

    for rar in "${rars[@]}"; do
      [[ -e "$rar" ]] || continue
      local mtime age
      if mtime=$(stat -f %m "$rar" 2>/dev/null); then
        :
      else
        mtime=$(stat -c %Y "$rar" 2>/dev/null || echo 0)
      fi
      [[ -n "$mtime" ]] || mtime=0
      
      age=$(( now - mtime ))
      # Safety for clock skew
      if (( age < 0 )); then age=0; fi

      if (( age < MIN_RAR_AGE )); then
        settled=0
        if (( age < youngest_age )); then
           youngest_age=$age
           target_rar="$rar"
        fi
      fi
    done

    if (( settled == 1 )); then
      break
    fi

    # Check timeout
    local elapsed=$(( now - start_wait ))
    if (( elapsed > max_settle_wait )); then
      log "Timeout waiting for files to settle (waited > ${max_settle_wait}s). Skipping extraction: $(basename "$target_rar")"
      return 0
    fi

    local wait_time=$(( MIN_RAR_AGE - youngest_age + 2 ))
    [[ $wait_time -lt 5 ]] && wait_time=5
    
    log "Files recently modified (age ${youngest_age}s < ${MIN_RAR_AGE}s). Waiting ${wait_time}s for settle..."
    sleep "$wait_time"
  done

  # Disk space check before extraction
  if ! check_disk_space "$dir" "$DEST_ROOT"; then
    log "Skipping extraction due to insufficient disk space: $dir"
    notify_mac "Extract & FileBot" "Insufficient disk space for extraction"
    return 0
  fi

  local out="$dir/$TMP_SUFFIX"

  if [[ "$FORCE" == "1" ]]; then
    log "FORCE=1: re-extracting all RARs in $dir"
    [[ "$DRY_RUN" != "1" ]] && rm -rf "$out"
    mkdir -p "$out"
    local had_any=0 total=${#rars[@]} idx=0
    for rar in "${rars[@]}"; do
      idx=$((idx+1))
      log "Extracting (force) ($idx/$total): $rar"
      if _extract_one "$rar" "$out"; then
        had_any=1
        log "Extraction successful, stopping search for this set."
        break
      else
        log "Extraction failed (this is normal for subsequent multi-part files): $rar"
      fi
    done
    [[ "$DRY_RUN" != "1" ]] && dir_signature "$dir" > "$sig_file"
    if [[ $had_any -eq 1 ]]; then
      printf '%s\n' "$out"
    fi
    return 0
  fi

  local current_sig
  current_sig="$(dir_signature "$dir")"

  if [[ -f "$sig_file" ]] && [[ "$(cat "$sig_file" 2>/dev/null)" == "$current_sig" ]]; then
    if [[ -d "$out" ]] && find "$out" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.ts" -o -iname "*.m2ts" \) -print -quit | grep -q .; then
      log "RAR set unchanged; using existing temp: $out"
      printf '%s\n' "$out"
      return 0
    fi
    if [[ ! -f "$done_file" ]]; then
      log "RAR set unchanged but not processed; re-extracting."
      [[ "$DRY_RUN" != "1" ]] && rm -rf "$out"
      mkdir -p "$out"
      local total=${#rars[@]} idx=0
      for rar in "${rars[@]}"; do
        idx=$((idx+1))
        log "Extracting ($idx/$total): $rar"
        if _extract_one "$rar" "$out"; then
          log "Extraction successful, stopping search for this set."
          break
        else
          log "Extraction failed (this is normal for subsequent multi-part files): $rar"
        fi
      done
      printf '%s\n' "$out"
      return 0
    fi
    log "RAR set unchanged; already processed; skipping extraction."
    return 0
  fi

  log "New/changed RARs detected; extracting to $out"
  log "Found ${#rars[@]} archive part(s) in $dir"
  [[ "$DRY_RUN" != "1" ]] && rm -rf "$out"
  mkdir -p "$out"
  local total=${#rars[@]} idx=0
  for rar in "${rars[@]}"; do
    idx=$((idx+1))
    log "Extracting ($idx/$total): $rar"
    if _extract_one "$rar" "$out"; then
      log "Extraction successful."
      break
    else
      log "Extraction failed (this is normal for subsequent multi-part files): $rar"
    fi
  done
  [[ "$DRY_RUN" != "1" ]] && printf '%s\n' "$current_sig" > "$sig_file"
  printf '%s\n' "$out"
}

# ===== Helper: Find Year =====
first_year_in_path(){
  local p="$1"
  # Grab first 19xx/20xx anywhere in the last 3 path components
  printf '%s' "$p" | awk -F'/' '{n=NF; for(i=n;i>0 && i>=n-2;i--) printf "%s ", $i}' \
    | grep -Eo '(19|20)[0-9]{2}' | head -n1
}

# ===== Manual TV fallback (does not touch originals) =====
manual_place_tv(){
  local src="$1" title="$2"
  local y; y="$(first_year_in_path "$src")"
  local show_name="$title"

  # If we found a year in the path, prefer `Title (Year)`
  if [[ -n "$y" ]]; then
    show_name="$title ($y)"
  else
    # No year in the path: if there's already a `Title (Year)` folder in the library,
    # reuse that so we don't create a duplicate root like `Dying for Sex` vs `Dying for Sex (2025)`.
    local cand
    shopt -s nullglob
    for cand in "$TV_DIR/$title ("*")"; do
      if [[ -d "$cand" ]]; then
        show_name="$(basename "$cand")"
        break
      fi
    done
    shopt -u nullglob
  fi

  local dest_show="$TV_DIR/$show_name"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN: would create TV show directory: $dest_show"
  else
    mkdir -p "$dest_show"
  fi
  
  shopt -s nullglob
  local f base ext s e season_dir newname
  for f in "$src"/*; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    if [[ "$base" =~ [Ss]([0-9]{1,2})[Ee]([0-9]{1,3}) ]]; then
      s="${BASH_REMATCH[1]}"; e="${BASH_REMATCH[2]}"
      printf -v s "%02d" $((10#$s)); printf -v e "%02d" $((10#$e))
      season_dir="$dest_show/Season $s"
      ext="${base##*.}"; newname="$season_dir/$title - S${s}E${e}.$ext"
      log "Manual TV place: $base -> $newname"
      if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: would copy to $newname"
      else
        mkdir -p "$season_dir"
        cp -f "$f" "$newname"
      fi
    elif [[ "$base" =~ [^A-Za-z0-9]E([0-9]{1,3})([^0-9]|$) ]]; then
      s="01"; e="${BASH_REMATCH[1]}"
      printf -v e "%02d" $((10#$e))
      season_dir="$dest_show/Season $s"
      ext="${base##*.}"; newname="$season_dir/$title - S${s}E${e}.$ext"
      log "Manual TV (E-only) place: $base -> $newname"
      if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: would copy to $newname"
      else
        mkdir -p "$season_dir"
        cp -f "$f" "$newname"
      fi
    fi
  done
  shopt -u nullglob
}

# ===== Title hint (for manual fallback only) =====
make_query_hint(){
  local src="$1" base up1 up2 raw up2_lc
  base="$(basename "$src")"
  up1="$(basename "$(dirname "$src")")"
  up2="$(basename "$(dirname "$(dirname "$src")")")"

  raw="$base"
  # For .extract_tmp, start from the parent folder (release/show folder)
  if [[ "$base" == ".extract_tmp" ]]; then
    raw="$up1"
  fi

  local re_generic='^(Season[._[:space:]]?[0-9]+|S[0-9]{2}|Disc[._[:space:]]?[0-9]+|Sample|Extras?)$'
  local re_episode='(^|[^A-Za-z0-9])(S[0-9]{1,2}E[0-9]{1,3}|E[0-9]{1,3}|EP[[:space:]._-]*[0-9]{1,3})([^0-9]|$)'

  # If we landed on a generic label (Season 01, Disc 1, etc.), prefer its parent
  if [[ "$raw" =~ $re_generic ]]; then
    raw="$up1"
  fi

  # Decide whether it's safe to fall back to up2 (grandparent)
  up2_lc="$(printf '%s' "$up2" | tr '[:upper:]' '[:lower:]')"
  # Treat common watch-root names as generic and avoid using them as a title hint
  local is_generic_root=0
  case "$up2_lc" in
    media|"media new"|"media_new"|"media-new"|downloads|download|torrents|completed)
      is_generic_root=1 ;;
  esac

  # If raw still looks like a pure episode/generic label and up2 is not a generic root,
  # then use up2 (typical case: ShowName/Season 01/.extract_tmp -> ShowName)
  if { [[ "$raw" =~ $re_generic ]] || [[ "$raw" =~ $re_episode ]] || [[ -z "$raw" ]]; } && [[ $is_generic_root -eq 0 ]]; then
    raw="$up2"
  fi

  # Build a clean, lowercase hint then normalize to canonical casing
  # Normalize and Clean
  local raw_prev="$raw"
  raw="$(printf '%s' "$raw" \
    | sed -E 's/[._]+/ /g' \
    | sed -E 's/\[[^\]]*\]//g; s/\([^)]*\)//g; s/\{[^}]*\}//g' \
    | sed -E 's/-[a-zA-Z0-9]+$//' \
    | sed -E 's/-/ /g' \
    | tr '[:upper:]' '[:lower:]')"
  
  # Targeted Codec Cleaning
  raw="$(printf '%s' "$raw" | sed -E 's/[[:space:]](h\.?26[45]|x26[45]|hevc|dv|hdr10\+?|avc|web|web[- ]?rip|web[- ]?dl)[[:space:]]/ /g')"
  # Run it again to catch adjacent tags that shared a space
  raw="$(printf '%s' "$raw" | sed -E 's/[[:space:]](h\.?26[45]|x26[45]|hevc|dv|hdr10\+?|avc|web|web[- ]?rip|web[- ]?dl)[[:space:]]/ /g')"
  # Catch trailing tags
  raw="$(printf '%s' "$raw" | sed -E 's/[[:space:]](h\.?26[45]|x26[45]|hevc|dv|hdr10\+?|avc|web|web[- ]?rip|web[- ]?dl)$//g')"

  raw="$(printf '%s' "$raw" \
    | sed -E 's/(^|[^a-z0-9])s[0-9]{1,2}e[0-9]{1,3}([^a-z0-9]|$)/ /g' \
    | sed -E 's/(^|[^a-z0-9])s[0-9]{1,2}([^a-z0-9]|$)/ /g' \
    | sed -E 's/(^|[^a-z0-9])e[0-9]{1,3}([^a-z0-9]|$)/ /g' \
    | sed -E 's/(^|[^a-z0-9])season[ ]?[0-9]{1,2}([^a-z0-9]|$)/ /g' \
    | sed -E 's/(^|[^a-z0-9])(2160p|1080p|720p|480p|uhd|hdr10\+?|hdr|dv|dolby[ ]?vision|web([- ]?rip|[- ]?dl)?|webrip|web[- ]?dl|web[- ]?rip|blu[- ]?ray|bluray|brrip|bdrip|hdtv|amzn|nf|netflix|hevc|h\.?265|h\.?264|x265|x264|avc|aac|dd5\.?1|dts[- ]?hd|truehd|atmos|multi|proper|repack|extended|remastered|uncut|limited|internal|readnfo|rerip)([^a-z0-9]|$)/ /g' \
    | sed -E 's/(^|[^a-z0-9])(19|20)[0-9]{2}([^a-z0-9]|$)/ /g' \
    | tr -s ' ' \
    | sed -E 's/^ +//; s/ +$//')"

  # Final guard: never use generic root names like "media" as the show title.
  case "$raw" in
    ""|media|"media new"|downloads|download|torrents|completed)
      # Fall back to cleaned parent folder name (release/show folder)
      raw="$(basename "$(dirname "$src")")"
      raw="$(printf '%s' "$raw" \
        | sed -E 's/[._]+/ /g' \
        | sed -E 's/\[[^\]]*\]//g; s/\([^)]*\)//g; s/\{[^}]*\}//g' \
        | sed -E 's/-[a-zA-Z0-9]+$//' \
        | sed -E 's/-/ /g' \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/(^|[^a-z0-9])s[0-9]{1,2}e[0-9]{1,3}([^a-z0-9]|$)/ /g' \
        | sed -E 's/(^|[^a-z0-9])s[0-9]{1,2}([^a-z0-9]|$)/ /g' \
        | sed -E 's/(^|[^a-z0-9])e[0-9]{1,3}([^a-z0-9]|$)/ /g' \
        | sed -E 's/(^|[^a-z0-9])season[ ]?[0-9]{1,2}([^a-z0-9]|$)/ /g' \
        | sed -E 's/(^|[^a-z0-9])(2160p|1080p|720p|480p|uhd|hdr10\+?|hdr|dv|dolby[ ]?vision|web([- ]?rip|[- ]?dl)?|webrip|web[- ]?dl|web[- ]?rip|blu[- ]?ray|bluray|brrip|bdrip|hdtv|amzn|nf|netflix|hevc|h\.?265|h\.?264|x265|x264|avc|aac|dd5\.?1|dts[- ]?hd|truehd|atmos|multi|proper|repack|extended|remastered|uncut|limited|internal|readnfo|rerip)([^a-z0-9]|$)/ /g' \
        | sed -E 's/(^|[^a-z0-9])web([^a-z0-9]|$)/ /g' \
        | sed -E 's/(^|[^a-z0-9])(19|20)[0-9]{2}([^a-z0-9]|$)/ /g' \
        | sed -E 's/(^|[^a-z0-9])(2160p|1080p|720p|480p|uhd|hdr10\+?|hdr|dv|dolby[ ]?vision|web([- ]?rip|[- ]?dl)?|webrip|web[- ]?dl|web[- ]?rip|blu[- ]?ray|bluray|brrip|bdrip|hdtv|amzn|nf|netflix|hevc|h\.?265|h\.?264|x265|x264|avc|aac|dd5\.?1|dts[- ]?hd|truehd|atmos|multi|proper|repack|extended|remastered|uncut|limited|internal|readnfo|rerip)([^a-z0-9]|$)/ /g' \
        | sed -E 's/(^|[^a-z0-9])web([^a-z0-9]|$)/ /g' \
        | tr -s ' ' \
        | sed -E 's/^ +//; s/ +$//')"
      ;;
  esac

  # Sanitize for command injection prevention (remove newlines/carriage returns)
  raw="${raw//[$'\n\r']/ }"

  # Known title normalizations (after basic cleanup)
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    *"the office uk"*|*"uk the office"*|*"the office (uk)"*) raw="The Office (2001)" ;;
    *"the office us"*|*"the office (us)"*|*"the office"*)     raw="The Office (2005)" ;;
    *"band of brothers"*) raw="Band of Brothers" ;;
    *"the pacific"*|*"pacific pack"*|*"the pacific pack"*|*"pacific pt"*) raw="The Pacific" ;;
    *"planet earth iii"*) raw="Planet Earth III" ;;
    *"breaking bad"*) raw="Breaking Bad" ;;
    *"dying for sex"*) raw="Dying for Sex" ;;
  esac
  [[ -z "$raw" ]] && raw="Unknown Show"
  printf '%s' "$raw"
}

# ===== Movie hint (for movie fallback / fuzzy match) =====
make_movie_hint(){
  local src="$1" base up1 raw
  base="$(basename "$src")"
  up1="$(basename "$(dirname "$src")")"

  raw="$base"
  # For .extract_tmp, start from the parent folder (release/movie folder)
  if [[ "$base" == ".extract_tmp" ]]; then
    raw="$up1"
  fi

  raw="$(printf '%s' "$raw" \
    | sed -E 's/[._]+/ /g' \
    | sed -E 's/\[[^\]]*\]//g; s/\([^)]*\)//g; s/\{[^}]*\}//g' \
    | sed -E 's/-[a-zA-Z0-9]+$//' \
    | sed -E 's/-/ /g' \
    | tr '[:upper:]' '[:lower:]')"
  # Targeted Codec Cleaning
  raw="$(printf '%s' "$raw" | sed -E 's/[[:space:]](h\.?26[45]|x26[45]|hevc|dv|hdr10\+?|avc|web|web[- ]?rip|web[- ]?dl)[[:space:]]/ /g')"
  # Run it again to catch adjacent tags that shared a space
  raw="$(printf '%s' "$raw" | sed -E 's/[[:space:]](h\.?26[45]|x26[45]|hevc|dv|hdr10\+?|avc|web|web[- ]?rip|web[- ]?dl)[[:space:]]/ /g')"
  # Catch trailing tags
  raw="$(printf '%s' "$raw" | sed -E 's/[[:space:]](h\.?26[45]|x26[45]|hevc|dv|hdr10\+?|avc|web|web[- ]?rip|web[- ]?dl)$//g')"

  raw="$(printf '%s' "$raw" \
    | sed -E 's/(^|[^a-z0-9])(2160p|1080p|720p|480p|uhd|hdr10\+?|hdr|dv|dolby[ ]?vision|web([- ]?rip|[- ]?dl)?|webrip|web[- ]?dl|web[- ]?rip|blu[- ]?ray|bluray|brrip|bdrip|hdtv|amzn|nf|netflix|hevc|h\.?265|h\.?264|x265|x264|avc|aac|dd5\.?1|dts[- ]?hd|truehd|atmos|multi|proper|repack|extended|remastered|uncut|limited|internal|readnfo|rerip)([^a-z0-9]|$)/ /g' \
    | sed -E 's/(^|[^a-z0-9])(2160p|1080p|720p|480p|uhd|hdr10\+?|hdr|dv|dolby[ ]?vision|web([- ]?rip|[- ]?dl)?|webrip|web[- ]?dl|web[- ]?rip|blu[- ]?ray|bluray|brrip|bdrip|hdtv|amzn|nf|netflix|hevc|h\.?265|h\.?264|x265|x264|avc|aac|dd5\.?1|dts[- ]?hd|truehd|atmos|multi|proper|repack|extended|remastered|uncut|limited|internal|readnfo|rerip)([^a-z0-9]|$)/ /g' \
    | sed -E 's/(^|[^a-z0-9])(19|20)[0-9]{2}([^a-z0-9]|$)/ /g' \
    | tr -s ' ' \
    | sed -E 's/^ +//; s/ +$//')"

  # If we stripped everything, fall back to parent folder name
  if [[ -z "$raw" ]]; then
    raw="$(printf '%s' "$up1" \
      | sed -E 's/[._]+/ /g' \
      | sed -E 's/\[[^\]]*\]//g; s/\([^)]*\)//g; s/\{[^}]*\}//g' \
      | sed -E 's/-[a-zA-Z0-9]+$//' \
      | sed -E 's/-/ /g' \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/(^|[^a-z0-9])(2160p|1080p|720p|480p|uhd|hdr10\+?|hdr|dv|dolby[ ]?vision|web([- ]?rip|[- ]?dl)?|webrip|web[- ]?dl|web[- ]?rip|blu[- ]?ray|bluray|brrip|bdrip|hdtv|amzn|nf|netflix|hevc|h\.?265|h\.?264|x265|x264|avc|aac|dd5\.?1|dts[- ]?hd|truehd|atmos|multi|proper|repack|extended|remastered|uncut|limited|internal|readnfo|rerip)([^a-z0-9]|$)/ /g' \
      | sed -E 's/(^|[^a-z0-9])(2160p|1080p|720p|480p|uhd|hdr10\+?|hdr|dv|dolby[ ]?vision|web([- ]?rip|[- ]?dl)?|webrip|web[- ]?dl|web[- ]?rip|blu[- ]?ray|bluray|brrip|bdrip|hdtv|amzn|nf|netflix|hevc|h\.?265|h\.?264|x265|x264|avc|aac|dd5\.?1|dts[- ]?hd|truehd|atmos|multi|proper|repack|extended|remastered|uncut|limited|internal|readnfo|rerip)([^a-z0-9]|$)/ /g' \
      | tr -s ' ' \
      | sed -E 's/^ +//; s/ +$//')"
  fi

  # Sanitize for command injection prevention
  raw="${raw//[$'\n\r']/ }"

  # Return a stable hint string (lowercase is fine)
  printf '%s' "$raw"
}

# ===== Normalize titles for fuzzy comparisons =====
norm(){
  # lowercase, remove all non-alnum
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+//g'
}

# ===== Enhanced movie duplicate detection with better fuzzy matching =====
movie_exists_in_library(){
  local hint="$1"
  local n_hint; n_hint="$(norm "$hint")"
  # Guard: empty hints must never match everything
  [[ -z "$n_hint" ]] && return 1
  
  local f base n_base
  shopt -s nullglob
  for f in "$MOVIE_DIR"/*; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    n_base="$(norm "${base%.*}")"
    
    # Exact normalized match
    if [[ "$n_base" == "$n_hint" ]]; then
      log "Exact fuzzy match found in library: $base"
      return 0
    fi
    
    # Prefix match (allows for year differences)
    if [[ "$n_base" == "$n_hint"* ]] || [[ "$n_hint" == "$n_base"* ]]; then
      # Additional check: ensure they share at least 80% of characters
      local len_base=${#n_base}
      local len_hint=${#n_hint}
      local min_len=$((len_base < len_hint ? len_base : len_hint))
      local max_len=$((len_base > len_hint ? len_base : len_hint))
      
      # Simple similarity: if shorter is at least 80% of longer
      if (( min_len * 100 / max_len >= 80 )); then
        log "Fuzzy prefix match found in library: $base (similarity threshold met)"
        return 0
      fi
    fi
  done
  shopt -u nullglob
  return 1
}

# ===== Media Type Detection =====
detect_media_type(){
  local src="$1"
  local video_files=()
  
  # Cache video file list for reuse
  while IFS= read -r -d '' f; do
    video_files+=("$f")
  done < <(find "$src" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.ts" -o -iname "*.m2ts" \) -print0)
  
  local count_vid=${#video_files[@]}
  [[ $count_vid -eq 0 ]] && { echo "none"; return; }
  
  local tv_detected="false"
  local basenames=""
  
  for f in "${video_files[@]}"; do
    basenames+="$(basename "$f")"$'\n'
  done
  
  # Check for TV episode patterns
  if printf '%s' "$basenames" | grep -Eiq '(S[0-9]{1,2}E[0-9]{1,3}|(^|[^A-Za-z0-9])E[0-9]{2,3}([^0-9]|$)|(^|[^A-Za-z0-9])EP[ ._-]?[0-9]{1,3}([^0-9]|$))'; then
    tv_detected="true"
    log "Detected TV episode naming (SxxEyy/Eyy/EPyy)."
  fi
  
  # Movie guard: avoid misclassifying movies like "… Part 3 (1987)" as TV
  if [[ "$tv_detected" == "true" ]]; then
    local lower_names has_episode=0 has_part=0 year_in_path
    lower_names=$(printf '%s' "$basenames" | awk '{print tolower($0)}')
    
    printf '%s' "$lower_names" | grep -Eq '(s[0-9]{1,2}e[0-9]{1,3}|(^|[^a-z0-9])e[0-9]{2,3}([^0-9]|$)|(^|[^a-z0-9])ep[ ._-]?[0-9]{1,3}([^0-9]|$))' && has_episode=1
    printf '%s' "$lower_names" | grep -Eq '(^|[^a-z])((pt|part)[ ._-]?(i{1,3}|iv|v|vi{0,3}|ix|x|xi{1,3}|[0-9]{1,3}))([^a-z]|$)' && has_part=1
    
    year_in_path="$(first_year_in_path "$src" || true)"
    if [[ $has_episode -eq 0 ]] && [[ $has_part -eq 1 ]] && [[ -n "$year_in_path" ]] && (( count_vid <= MAX_VIDS_FOR_MOVIE )); then
      tv_detected="false"
      log "Movie guard: found 'Part/Pt' + year but no Sxx/Eyy/EP; treating as Movie."
    fi
  fi
  
  # Miniseries heuristic: many parts in one folder
  if [[ "$tv_detected" == "false" ]]; then
    local count_parts
    count_parts=$(printf '%s' "$basenames" | sed -E 's/[._]+/ /g' | awk '{print tolower($0)}' | grep -Ec '(^|[^a-z])((pt|part)[ ._-]?(i{1,3}|iv|v|vi{0,3}|ix|x|xi{1,3}|[0-9]{1,3}))([^a-z]|$)' || true)
    if (( count_parts >= MIN_PARTS_FOR_MINISERIES )); then
      tv_detected="true"
      log "Miniseries heuristic: >=$MIN_PARTS_FOR_MINISERIES parts detected; treating as TV."
    fi
  fi
  
  # Last-resort safety: if path strongly suggests a known miniseries, force TV mode
  if [[ "$tv_detected" == "false" ]]; then
    if printf '%s' "$src" | awk '{print tolower($0)}' | grep -Eq 'the[._ ]pacific|band[._ ]of[._ ]brothers'; then
      tv_detected="true"
      log "Path heuristic: known miniseries detected; forcing TV mode."
    fi
  fi
  
  echo "$tv_detected"
}

# ===== Process TV Show =====
process_tv_show(){
  local src="$1"
  local qhint; qhint="$(make_query_hint "$src")"
  log "TV query hint -> '$qhint'"
  log "FileBot TV rename (TMDB::TV) with query: $qhint"
  
  local filebot_cmd=(
    "$FILEBOT" -rename "$src"
    -r
    --output "$DEST_ROOT"
    --action move
    --conflict skip
    -non-strict
    --db TheMovieDB::TV
    --q "$qhint"
    --log fine
    --format '{ "TV Shows/" + n + " (" + any{y}{airdate.year} + ")/Season " + s.pad(2) + "/" + n + " - S" + s.pad(2) + "E" + e.pad(2) + (t ? " - " + t : "") }'
  )
  
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN: would execute FileBot TV rename: ${filebot_cmd[*]}"
    return 0
  fi
  
  if retry_with_backoff "${filebot_cmd[@]}"; then
    log "FileBot TV rename succeeded."
    return 0
  fi
  
  log "TV rename failed after $FILEBOT_RETRY attempts; falling back to manual TV placement using: $qhint"
  manual_place_tv "$src" "$qhint"
  return 0
}

# ===== Process Movie =====
process_movie(){
  local src="$1"
  log "FileBot Movie rename (TMDB)"
  
  # Select the single largest video file for movie rename to avoid split/duplicate chunks
  local biggest="" biggest_size=0 sz f
  while IFS= read -r -d '' f; do
    if sz=$(stat -f %z "$f" 2>/dev/null); then :; else sz=$(stat -c %s "$f" 2>/dev/null || echo 0); fi
    [[ -n "$sz" ]] || sz=0
    if (( sz > biggest_size )); then biggest_size=$sz; biggest="$f"; fi
  done < <(find "$src" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.ts" -o -iname "*.m2ts" \) -print0)
  
  if [[ -z "$biggest" ]]; then
    log "No video candidate found for movie rename."
    return 1
  fi
  
  log "Movie candidate (largest): $(basename "$biggest") size=$biggest_size"
  
  # Verify video integrity if enabled
  if ! verify_video_integrity "$biggest"; then
    log "Skipping movie due to failed integrity check"
    return 1
  fi
  
  # Run FileBot; capture output for inspection
  local fb_log; fb_log="/tmp/filebot_movie_$$.log"
  local filebot_cmd=(
    "$FILEBOT" -rename "$biggest"
    --output "$DEST_ROOT"
    --action move
    --conflict skip
    -non-strict
    --db TheMovieDB
    --log fine
    --format '{ "Movies/" + n + " (" + y + ")" }'
  )
  
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN: would execute FileBot movie rename: ${filebot_cmd[*]}"
    rm -f "$fb_log"
    return 0
  fi
  
  if retry_with_backoff "${filebot_cmd[@]}" >"$fb_log" 2>&1; then
    log "FileBot Movie rename succeeded."
    rm -f "$fb_log"
    return 0
  fi
  
  # Inspect FileBot output for duplicate/exists signals
  if grep -Eiq '\b(already exists|\[SKIP\].*already exists|is an exact copy and already exists)\b' "$fb_log"; then
    local mhint; mhint="$(make_movie_hint "$src")"
    log "FileBot indicates destination already exists ($mhint); treating as success."
    rm -f "$fb_log"
    return 0
  fi
  
  # Fallback: fuzzy library presence check (handles punctuation like colons vs no-colons)
  local mhint; mhint="$(make_movie_hint "$src")"
  if movie_exists_in_library "$mhint"; then
    log "Library contains a matching movie for '$mhint' (fuzzy match); treating as success."
    rm -f "$fb_log"
    return 0
  fi
  
  log "Movie rename failed after $FILEBOT_RETRY attempts; no TV pattern detected; nothing to do."
  rm -f "$fb_log"
  return 1
}

# ===== Run FileBot (AMC) - Refactored =====
filebot_sort(){
  local src="$1"
  # SAFETY: only operate on extracted temp folders (e.g., .../.extract_tmp)
  case "$src" in
    *"$TMP_SUFFIX") : ;;  # allowed
    *) log "Safety: skipping non-extracted dir: $src"; return 0 ;;
  esac
  
  if cd "$src" >/dev/null 2>&1; then
    any_vid=$(find . -maxdepth 3 -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.ts" -o -iname "*.m2ts" \) -print -quit 2>/dev/null || echo "")
    count_vid=$(find . -maxdepth 3 -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.ts" -o -iname "*.m2ts" \) 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    cd - >/dev/null 2>&1
  else
    log "ERROR: Cannot access directory: $src"
    return 1
  fi
  
  if [[ -z "$any_vid" ]]; then
    log "No video files found in $src"
    return 1
  fi
  
  log "Found $count_vid video file(s) under $src"
  
  local media_type
  media_type="$(detect_media_type "$src")"
  
  if [[ "$media_type" == "none" ]]; then
    log "No media detected"
    return 1
  elif [[ "$media_type" == "true" ]]; then
    log "Heuristic: Treating as TV"
    process_tv_show "$src"
  else
    log "Heuristic: Treating as Movie"
    process_movie "$src"
  fi
}

# ===== Process Single Directory (for parallel execution) =====
process_single_dir(){
  local sub="$1"
  local sdir
  sdir="$(extract_rars_in_dir "$sub" || true)"
  if [[ -n "${sdir:-}" ]]; then
    if filebot_sort "$sdir"; then
      [[ "$DRY_RUN" != "1" ]] && rm -rf "$sdir" && log "Removed temp: $sdir"
      [[ "$FORCE" != "1" ]] && [[ "$DRY_RUN" != "1" ]] && touch "$sub/.extract_done" || true
      # Run post-process hook if configured
      if [[ -n "$POST_PROCESS_SCRIPT" ]] && [[ -x "$POST_PROCESS_SCRIPT" ]]; then
        log "Running post-process script: $POST_PROCESS_SCRIPT"
        "$POST_PROCESS_SCRIPT" "$sub" || log "Post-process script failed (non-fatal)"
      fi
    else
      FAILED_DIRS+=("$sub")
      # Use cd to avoid "File name too long" errors
      # Use pushd to avoid "File name too long" and ensure directory access
      local cleanup_needed=1
      if pushd "$sdir" >/dev/null 2>&1; then
        if find . -maxdepth 3 -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.ts" -o -iname "*.m2ts" \) -print -quit | grep -q .; then
          cleanup_needed=0
        fi
        popd >/dev/null 2>&1
      fi

      if [[ $cleanup_needed -eq 1 ]]; then
        log "Extraction contained no video files. Cleaning up: $sdir"
        [[ "$DRY_RUN" != "1" ]] && rm -rf "$sdir"
        # Mark as done so we don't re-extract next time (e.g., subtitle packs)
        [[ "$FORCE" != "1" ]] && [[ "$DRY_RUN" != "1" ]] && touch "$sub/.extract_done" || true
      else
        log "Sort failed but videos exist. Keeping temp for troubleshooting: $sdir"
      fi
    fi
  fi
}

# Export for parallel execution
export -f process_single_dir extract_rars_in_dir filebot_sort detect_media_type process_tv_show process_movie
export -f log dir_signature stat_list _extract_one manual_place_tv make_query_hint make_movie_hint
export -f first_year_in_path norm movie_exists_in_library check_disk_space retry_with_backoff verify_video_integrity notify_mac
export WATCH_DIR DEST_ROOT TV_DIR MOVIE_DIR SEVENZ FILEBOT TMP_SUFFIX FORCE PROGRESS MIN_RAR_AGE
export DRY_RUN FILEBOT_RETRY VERIFY_VIDEO MIN_PARTS_FOR_MINISERIES MAX_VIDS_FOR_MOVIE
export POST_PROCESS_SCRIPT LOG_FILE ENABLE_NOTIFICATIONS DISK_SPACE_MARGIN QUIET STREAM_MODE

main(){
  require_bin "$SEVENZ"; require_bin "$FILEBOT"
  if [[ ! -e "$WATCH_DIR" ]]; then log "Source path not found: $WATCH_DIR"; exit 1; fi
  if [[ -f "$WATCH_DIR" ]]; then WATCH_DIR="$(dirname "$WATCH_DIR")"; log "Adjusted source to parent dir: $WATCH_DIR"; fi
  
  # Acquire lockfile to prevent concurrent runs
  acquire_lock
  
  # Clean up any stale temp directories
  cleanup_stale_temps
  
  log "==== Extract & FileBot Start ===="
  log "Source: $WATCH_DIR"
  log "Dest root: $DEST_ROOT"
  log "TV dir: $TV_DIR"
  log "Movie dir: $MOVIE_DIR"
  log "7z: $SEVENZ | FileBot: $FILEBOT"
  log "FORCE=$FORCE | DRY_RUN=$DRY_RUN | PARALLEL_JOBS=$PARALLEL_JOBS"
  log "FILEBOT_RETRY=$FILEBOT_RETRY | VERIFY_VIDEO=$VERIFY_VIDEO"
  log "===================================="
  
  local start_time end_time elapsed processed=0 failed=0
  start_time=$(date +%s)
  
  # Top-level (extract, then process ONLY the produced .extract_tmp)
  local tdir
  tdir="$(extract_rars_in_dir "$WATCH_DIR" 2>/dev/null || true)"
  if [[ -n "${tdir:-}" ]]; then
    ((processed++))
    if filebot_sort "$tdir"; then
      [[ "$DRY_RUN" != "1" ]] && rm -rf "$tdir" && log "Removed temp: $tdir"
      [[ "$FORCE" != "1" ]] && [[ "$DRY_RUN" != "1" ]] && touch "$WATCH_DIR/.extract_done" || true
      if [[ -n "$POST_PROCESS_SCRIPT" ]] && [[ -x "$POST_PROCESS_SCRIPT" ]]; then
        log "Running post-process script: $POST_PROCESS_SCRIPT"
        "$POST_PROCESS_SCRIPT" "$WATCH_DIR" || log "Post-process script failed (non-fatal)"
      fi
    else
      ((failed++))
      if ! find "$tdir" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.ts" -o -iname "*.m2ts" \) -print -quit | grep -q .; then
        log "Extraction contained no video files. Cleaning up: $tdir"
        [[ "$DRY_RUN" != "1" ]] && rm -rf "$tdir"
      else
        log "Sort failed but videos exist. Keeping temp for troubleshooting: $tdir"
      fi
    fi
  fi
  
  # Nested directories (1 level deep)
  if [[ "$STREAM_MODE" == "1" ]]; then
    # STREAM MODE: Process directories as they're found (starts immediately, no progress counter)
    log "Stream mode: processing directories as found (no wait for enumeration)"
    if (( PARALLEL_JOBS > 1 )) && command -v xargs >/dev/null 2>&1; then
      log "Using parallel processing (jobs=$PARALLEL_JOBS)"
      find "$WATCH_DIR" -mindepth 1 -maxdepth 2 -type d -print0 | \
        xargs -0 -P "$PARALLEL_JOBS" -I {} bash -c 'process_single_dir "$@"' _ {}
    else
      log "Using sequential processing"
      while IFS= read -r -d '' sub; do
        log "Processing: $(basename "$sub")"
        process_single_dir "$sub"
      done < <(find "$WATCH_DIR" -mindepth 1 -maxdepth 2 -type d -print0)
    fi
  else
    # BATCH MODE: Collect all directories first, then process (shows progress counter)
    local subdirs=()
    while IFS= read -r -d '' sub; do
      subdirs+=("$sub")
    done < <(find "$WATCH_DIR" -mindepth 1 -maxdepth 2 -type d -print0)
    
    if (( ${#subdirs[@]} > 0 )); then
      log "Found ${#subdirs[@]} subdirectories to process"
      
      if (( PARALLEL_JOBS > 1 )) && command -v xargs >/dev/null 2>&1; then
        log "Processing subdirectories in parallel (jobs=$PARALLEL_JOBS)"
        printf '%s\0' "${subdirs[@]}" | xargs -0 -P "$PARALLEL_JOBS" -I {} bash -c 'process_single_dir "$@"' _ {}
      else
        log "Processing subdirectories sequentially"
        local current=0 total=${#subdirs[@]}
        for sub in "${subdirs[@]}"; do
          ((current++))
          log "Progress: [$current/$total] Processing: $(basename "$sub")"
          process_single_dir "$sub"
        done
      fi
    fi
  fi
  
  end_time=$(date +%s)
  elapsed=$((end_time - start_time))
  
  log "===================================="
  log "Processing complete"
  log "Processed: $processed items"
  log "Failed: $failed items"
  log "Elapsed time: ${elapsed}s"
  log "Log file: $LOG_FILE"
  
  # Report failed directories if any
  if (( ${#FAILED_DIRS[@]} > 0 )); then
    log "===================================="
    log "FAILED DIRECTORIES (${#FAILED_DIRS[@]}):"
    for dir in "${FAILED_DIRS[@]}"; do
      log "  - $(basename "$dir")"
    done
  fi
  log "===================================="
  
  # Send completion notification
  if (( processed > 0 )); then
    notify_mac "Extract & FileBot" "Completed: $processed items processed, $failed failed (${elapsed}s)"
  fi
}

main "$@"