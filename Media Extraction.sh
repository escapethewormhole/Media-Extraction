#!/usr/bin/env bash
# Media extractor + FileBot sorter (macOS-safe). Idempotent with signatures. Retries on failures.

set -euo pipefail
IFS=$'\n\t'

# ========== Paths & Settings ==========
LOG_FILE="/tmp/extract_and_filebot.log"
SPECIAL_CASES_FILE="${SPECIAL_CASES_FILE:-$HOME/.config/media-script/special-cases.conf}"

WATCH_DIR="${1:-/Volumes/Vault/Media New}"     # qBittorrent: pass "%D" (download dir)
DEST_ROOT="/Volumes/Vault/Extracted Media"     # Library root

SEVENZ="${SEVENZ:-$(command -v 7zz >/dev/null 2>&1 && echo 7zz || echo 7z)}"  # prefer 7zz if present
FILEBOT="${FILEBOT:-filebot}"

TMP_SUFFIX=".extract_tmp"   # temp extraction dir next to archives
FORCE="${FORCE:-0}"         # FORCE=1 to re-extract & re-process
PROGRESS="${PROGRESS:-0}"   # PROGRESS=1 to show extractor/FileBot progress if interactive TTY
DRY_RUN="${DRY_RUN:-0}"     # DRY_RUN=1 to log actions without executing FileBot
CLEANUP_EXTRACTS="${CLEANUP_EXTRACTS:-0}"  # CLEANUP_EXTRACTS=1 removes .extract_tmp after successful processing
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"

mkdir -p /tmp

# ========== Logging ==========
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
log_error(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }

require_bin(){ command -v "$1" >/dev/null 2>&1 || { log_error "Missing required command: $1"; exit 1; }; }

# ========== BSD/GNU-portable one-level find helpers ==========
# List files in DIR matching a patterns clause at depth=1 (no recursion).
# Usage: _find_files_lvl1 "$dir" -iname "*.rar" -o -iname "*.7z"
_find_files_lvl1(){
  local dir="$1"; shift
  # Prune subdirectories, then print files that match the patterns.
  # Works on both BSD find (macOS) and GNU find.
  find "$dir" \( -type d ! -path "$dir" -prune \) -o \( -type f \( "$@" \) -print \)
}

# List immediate subdirectories of DIR (depth=1).
_find_dirs_lvl1(){
  local dir="$1"
  find "$dir" -type d ! -path "$dir" -prune -print
}

# ========== Signature helpers (for idempotency) ==========
_stat_find_expr(){ # patterns for files that define an archive "set"
  printf '%s\n' \
      "-iname" "*.rar" "-o" "-iname" "*.part1.rar" "-o" "-iname" "*.part01.rar" "-o" \
      "-iname" "*.r[0-9][0-9]" "-o" "-iname" "*.001" "-o" "-iname" "*.002" "-o" \
      "-iname" "*.7z" "-o" "-iname" "*.7z.0[0-9][0-9]" "-o" \
      "-iname" "*.zip" "-o" "-iname" "*.z0[0-9]"
}

stat_list(){
  local dir="$1"
  if stat -f '%N %z %m' / >/dev/null 2>&1; then
    _find_files_lvl1 "$dir" $(_stat_find_expr) -exec stat -f '%N %z %m' {} \; 2>/dev/null
  else
    _find_files_lvl1 "$dir" $(_stat_find_expr) -exec stat -c '%n %s %Y' {} \; 2>/dev/null
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

# ========== Extraction (with retries) ==========
_extract_one(){
  local rar="$1" out="$2" attempt=1
  mkdir -p "$out"
  : > "$out/.by_media_script"

  while [[ $attempt -le $MAX_RETRIES ]]; do
    [[ $attempt -gt 1 ]] && { log "Retry $attempt/$MAX_RETRIES in ${RETRY_DELAY}s"; sleep "$RETRY_DELAY"; }

    if [[ "${PROGRESS:-0}" == "1" ]] && [[ -t 2 ]]; then
      if "$SEVENZ" x -y -aou -mmt=on -bsp1 -bso2 "$rar" -o"$out" 2>&1 | tee -a "$LOG_FILE"; then
        return 0
      fi
      if command -v unar >/dev/null 2>&1; then
        if unar -force-overwrite -o "$out" "$rar" 2>&1 | tee -a "$LOG_FILE"; then
          return 0
        fi
      fi
    else
      if "$SEVENZ" x -y -aou -mmt=on "$rar" -o"$out" >>"$LOG_FILE" 2>&1; then
        return 0
      fi
      if command -v unar >/dev/null 2>&1; then
        if unar -quiet -force-overwrite -o "$out" "$rar" >>"$LOG_FILE" 2>&1; then
          return 0
        fi
      fi
    fi

    attempt=$((attempt + 1))
  done

  log_error "Extraction failed after $MAX_RETRIES attempts: $rar"
  return 1
}

extract_rars_in_dir(){
  local dir="$1"
  shopt -s nullglob
  local rars=(
    "$dir"/*.rar "$dir"/*.RAR
    "$dir"/*.part1.rar "$dir"/*.part01.rar
    "$dir"/*.r[0-9][0-9] "$dir"/*.R[0-9][0-9]   # allow lower/upper Rnn
    "$dir"/*.001 "$dir"/*.002
    "$dir"/*.7z "$dir"/*.7Z "$dir"/*.7z.0[0-9][0-9]
    "$dir"/*.zip "$dir"/*.ZIP "$dir"/*.z0[0-9]
  )
  shopt -u nullglob
  (( ${#rars[@]} == 0 )) && return 0

  local out="$dir/$TMP_SUFFIX"
  local sig_file="$dir/.extract_sig"
  local done_file="$dir/.extract_done"

  if [[ "$FORCE" == "1" ]]; then
    log "FORCE=1: re-extracting $dir"
    rm -rf "$out"; mkdir -p "$out"
    : > "$out/.by_media_script"
    local had_any=0 total=${#rars[@]} idx=0
    for rar in "${rars[@]}"; do
      idx=$((idx+1)); log "Extracting (force) ($idx/$total): $rar"
      if _extract_one "$rar" "$out"; then had_any=1; log "Extraction successful (force)"; break; else log "Extractor said no (maybe not first part): $rar"; fi
    done
    dir_signature "$dir" > "$sig_file"
    [[ $had_any -eq 1 ]] && printf '%s\n' "$out"
    return 0
  fi

  local current_sig; current_sig="$(dir_signature "$dir")"

  if [[ -f "$sig_file" ]] && [[ "$(cat "$sig_file" 2>/dev/null)" == "$current_sig" ]]; then
    if [[ -d "$out" ]] && find "$out" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.ts" -o -iname "*.m2ts" \) -print -quit | grep -q .; then
      log "RAR set unchanged; reusing temp: $out"
      : > "$out/.by_media_script"
      printf '%s\n' "$out"
      return 0
    fi
    if [[ ! -f "$done_file" ]]; then
      log "RAR set unchanged but not yet processed; extracting again"
      rm -rf "$out"; mkdir -p "$out"
      : > "$out/.by_media_script"
      local total=${#rars[@]} idx=0
      for rar in "${rars[@]}"; do
        idx=$((idx+1)); log "Extracting ($idx/$total): $rar"
        if _extract_one "$rar" "$out"; then log "Extraction successful"; break; else log "Extractor said no (maybe not first part): $rar"; fi
      done
      printf '%s\n' "$out"
      return 0
    fi
    log "RAR set unchanged and already processed; skip extraction"
    return 0
  fi

  log "New/changed archives detected; extracting to $out"
  log "Found ${#rars[@]} part(s) in $dir"
  rm -rf "$out"; mkdir -p "$out"
  : > "$out/.by_media_script"
  local total=${#rars[@]} idx=0
  for rar in "${rars[@]}"; do
    idx=$((idx+1)); log "Extracting ($idx/$total): $rar"
    if _extract_one "$rar" "$out"; then log "Extraction successful"; break; else log "Extractor said no (maybe not first part): $rar"; fi
  done
  printf '%s\n' "$current_sig" > "$sig_file"
  printf '%s\n' "$out"
}

# ========== Title helpers ==========
first_year_in_path(){
  local p="$1"
  printf '%s' "$p" | awk -F'/' '{n=NF; for(i=n;i>0 && i>=n-2;i--) printf "%s ", $i}' \
    | grep -Eo '(19|20)[0-9]{2}' | head -n1
}

manual_place_tv(){
  local src="$1" title="$2"
  local y; y="$(first_year_in_path "$src")"
  local show_name="$title"; [[ -n "$y" ]] && show_name="$title ($y)"
  local dest_show="$DEST_ROOT/TV Shows/$show_name"
  mkdir -p "$dest_show"
  shopt -s nullglob
  local f base ext s e season_dir newname
  for f in "$src"/*; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    if [[ "$base" =~ [Ss]([0-9]{1,2})[Ee]([0-9]{1,3}) ]]; then
      s="${BASH_REMATCH[1]}"; e="${BASH_REMATCH[2]}"
      printf -v s "%02d" $((10#$s)); printf -v e "%02d" $((10#$e))
      season_dir="$dest_show/Season $s"; mkdir -p "$season_dir"
      ext="${base##*.}"; newname="$season_dir/$title - S${s}E${e}.$ext"
      log "Manual TV: $base -> $newname"
      [[ "$DRY_RUN" == "1" ]] || cp -f "$f" "$newname"
    elif [[ "$base" =~ [^A-Za-z0-9]E([0-9]{1,3})([^0-9]|$) ]]; then
      s="01"; e="${BASH_REMATCH[1]}"; printf -v e "%02d" $((10#$e))
      season_dir="$dest_show/Season $s"; mkdir -p "$season_dir"
      ext="${base##*.}"; newname="$season_dir/$title - S${s}E${e}.$ext"
      log "Manual TV (E-only): $base -> $newname"
      [[ "$DRY_RUN" == "1" ]] || cp -f "$f" "$newname"
    fi
  done
  shopt -u nullglob
}

# Special cases config: pattern|replacement (case-insensitive substring)
load_special_cases(){
  [[ ! -f "$SPECIAL_CASES_FILE" ]] && return
  while IFS='|' read -r pattern replacement || [[ -n "${pattern:-}" ]]; do
    [[ "${pattern:-}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${pattern:-}" ]] && continue
    # Trim both sides
    pattern="$(printf '%s' "${pattern:-}" | sed -E 's/^ +//; s/ +$//')"
    replacement="$(printf '%s' "${replacement:-}" | sed -E 's/^ +//; s/ +$//')"
    printf '%s|%s\n' "$pattern" "$replacement"
  done < "$SPECIAL_CASES_FILE"
}

apply_special_cases(){
  local raw="$1"
  local normalized; normalized="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  while IFS='|' read -r pattern replacement; do
    [[ -z "${pattern:-}" ]] && continue
    if [[ "$normalized" == *"$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')"* ]]; then
      printf '%s' "$replacement"; return 0
    fi
  done < <(load_special_cases)
  case "$normalized" in
    *"the office uk"*|*"uk the office"*|*"the office (uk)"*) printf '%s' "The Office (2001)";;
    *"the office us"*|*"the office (us)"*|*"the office"*)   printf '%s' "The Office (2005)";;
    *"band of brothers"*)                                   printf '%s' "Band of Brothers";;
    *"the pacific"*|*"pacific pack"*|*"the pacific pack"*|*"pacific pt"*) printf '%s' "The Pacific";;
    *"planet earth iii"*)                                    printf '%s' "Planet Earth III";;
    *"breaking bad"*)                                        printf '%s' "Breaking Bad";;
    *)                                                       printf '%s' "$raw";;
  esac
}

make_query_hint(){
  local src="$1" base up1 up2 raw
  base="$(basename "$src")"
  up1="$(basename "$(dirname "$src")")"
  up2="$(basename "$(dirname "$(dirname "$src")")")"
  raw="$base"; [[ "$base" == ".extract_tmp" ]] && raw="$up1"

  local re_generic='^(Season[._[:space:]]?[0-9]+|S[0-9]{2}|Disc[._[:space:]]?[0-9]+|Sample|Extras?)$'
  local re_episode='(^|[^A-Za-z0-9])(S[0-9]{1,2}E[0-9]{1,3}|E[0-9]{1,3}|EP[[:space:]._-]*[0-9]{1,3})([^0-9]|$)'

  if [[ "$raw" =~ $re_generic ]] || [[ "$raw" =~ $re_episode ]]; then raw="$up1"; fi
  if [[ "$raw" =~ $re_episode ]] || [[ -z "$raw" ]]; then raw="$up2"; fi

  raw="$(printf '%s' "$raw" \
    | sed -E 's/[._]+/ /g' \
    | sed -E 's/\[[^\]]*\]//g; s/\([^)]*\)//g; s/\{[^}]*\}//g' \
    | sed -E 's/-[A-Za-z0-9]{3,12}$//' \
    | sed -E 's/-/ /g' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/(^|[^a-z0-9])s[0-9]{1,2}e[0-9]{1,3}([^a-z0-9]|$)/ /g' \
    | sed -E 's/(^|[^a-z0-9])s[0-9]{1,2}([^a-z0-9]|$)/ /g' \
    | sed -E 's/(^|[^a-z0-9])e[0-9]{1,3}([^a-z0-9]|$)/ /g' \
    | sed -E 's/(^|[^a-z0-9])season[ ]?[0-9]{1,2}([^a-z0-9]|$)/ /g' \
    | sed -E 's/(^|[^a-z0-9])(2160p|1080p|720p|480p|uhd|hdr10\+?|hdr|dv|dolby[ ]?vision|web([- ]?rip|[- ]?dl)?|webrip|web[- ]?dl|web[- ]?rip|blu[- ]?ray|bluray|brrip|bdrip|hdtv|amzn|nf|netflix|hevc|h\.?265|h\.?264|x265|x264|avc|aac|dd5\.?1|dts[- ]?hd|truehd|atmos|multi|proper|repack|extended|remastered|uncut|limited|internal|readnfo|rerip)([^a-z0-9]|$)/ /g' \
    | sed -E 's/(^|[^a-z0-9])(19|20)[0-9]{2}([^a-z0-9]|$)/ /g' \
    | sed -E 's/[[:space:]]+[a-z0-9]{3,12}$//' \
    | tr -s ' ' | sed -E 's/^ +//; s/ +$//')"

  raw="$(apply_special_cases "$raw")"
  [[ -z "$raw" ]] && raw="Unknown Show"
  printf '%s' "$raw"
}

make_movie_hint(){
  local src="$1" base up1 up2 raw yr
  base="$(basename "$src")"; up1="$(basename "$(dirname "$src")")"; up2="$(basename "$(dirname "$(dirname "$src")")")"
  raw="$base"; [[ "$base" == ".extract_tmp" ]] && raw="$up1"
  local pick; for pick in "$raw" "$up1" "$up2"; do [[ -n "$pick" ]] && { raw="$pick"; break; }; done

  raw="$(printf '%s' "$raw" \
    | sed -E 's/[._]+/ /g' \
    | sed -E 's/\[[^\]]*\]//g; s/\([^)]*\)//g; s/\{[^}]*\}//g' \
    | sed -E 's/\b(2160p|1080p|720p|480p|UHD|HDR10\+?|HDR|DV|Dolby[ ]?Vision|WEB(Rip|[- ]?DL)?|Blu?Ray|BRRip|BDRip|WEBrip|AMZN|NF|HEVC|H\.?265|H\.?264|x265|x264|AVC|AAC|DD5\.?1|DTS[- ]?HD|TrueHD|Atmos|MULTI|PROPER|REPACK|EXTENDED|REMASTERED|UNCUT|LIMITED|iNTERNAL|READNFO|RERiP|GERMAN|FRENCH|EN|ENG|ITA|FRA|VO|SUBS?)\b/ /gi' \
    | sed -E 's/-[A-Za-z0-9]+$//' \
    | tr -s ' ' | sed -E 's/^ +//; s/ +$//')"
  yr="$(first_year_in_path "$src")"
  [[ -z "$raw" ]] && raw="Unknown Movie"
  [[ -n "$yr" ]] && printf '%s (%s)' "$raw" "$yr" || printf '%s' "$raw"
}

# ========== Heuristics ==========
norm(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+//g'; }

movie_exists_in_library(){
  local hint="$1" n_hint; n_hint="$(norm "$hint")"
  local f base n_base
  shopt -s nullglob
  for f in "$DEST_ROOT/Movies"/*; do
    base="$(basename "$f")"
    n_base="$(norm "${base%.*}")"
    if [[ "$n_base" == "$n_hint"* ]]; then shopt -u nullglob; return 0; fi
  done
  shopt -u nullglob
  return 1
}

# ========== FileBot wrapper with retries ==========
filebot_with_retry(){
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: would execute -> $FILEBOT $(printf '%q ' "$@")"
    return 0
  fi

  local attempt=1 success=0
  while [[ $attempt -le $MAX_RETRIES ]] && [[ $success -eq 0 ]]; do
    [[ $attempt -gt 1 ]] && { log "FileBot retry $attempt/$MAX_RETRIES in ${RETRY_DELAY}s"; sleep "$RETRY_DELAY"; }
    log "Running: $FILEBOT $(printf '%q ' "$@")"
    if [[ "${PROGRESS:-0}" == "1" ]]; then
      if "$FILEBOT" "$@" 2>&1 | tee -a "$LOG_FILE"; then success=1; fi
    else
      if "$FILEBOT" "$@" >>"$LOG_FILE" 2>&1; then success=1; fi
    fi
    attempt=$((attempt + 1))
  done
  [[ $success -eq 1 ]] || { log_error "FileBot failed after $MAX_RETRIES attempts"; return 1; }
  return 0
}

# ========== Sorting (TV/Movie detection + rename) ==========
filebot_sort(){
  local src="$1"

  case "$src" in
    *"$TMP_SUFFIX") : ;;  # only process extracted temp dirs
    *) log "Safety: skipping non-extracted dir: $src"; return 0 ;;
  esac

  local any_vid
  any_vid="$(find "$src" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.ts" -o -iname "*.m2ts" \) -print -quit)"
  [[ -z "$any_vid" ]] && { log "No video files found in $src"; return 0; }

  local count_vid; count_vid=$(find "$src" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.ts" -o -iname "*.m2ts" \) | wc -l | tr -d ' ')
  log "Found $count_vid video file(s) under $src"

  local tv_detected="false"
  local lower_names
  lower_names=$(find "$src" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.ts" -o -iname "*.m2ts" \) -print0 \
    | xargs -0 -n1 basename | awk '{print tolower($0)}' || true)

  # Initial TV detection: S##E##, E##, EP ##
  if printf '%s\n' "$lower_names" | grep -Eq '(s[0-9]{1,2}e[0-9]{1,3}|(^|[^a-z0-9])e[0-9]{2,3}([^a-z0-9]|$)|(^|[^a-z0-9])ep[ ._-]?[0-9]{1,3}([^a-z0-9]|$))'; then
    tv_detected="true"; log "Detected TV episode-like naming"
  fi

  # Movie guard heuristic: Part/Pt N + year + no S##E## + small file count (≤2) → Movie
  if [[ "$tv_detected" == "true" ]]; then
    local has_episode=1
  else
    local has_episode=0
  fi
  local has_part=0
  if printf '%s\n' "$lower_names" | grep -Eq '(^|[^a-z])((pt|part)[ ._-]?(i{1,3}|iv|v|vi{0,3}|ix|x|xi|xii|xiii|xiv|xv|xvi|xvii|xviii|xix|xx|[0-9]{1,3}))([^a-z]|$)'; then
    has_part=1
  fi
  local year_in_path; year_in_path="$(first_year_in_path "$src" || true)"
  if [[ $has_episode -eq 0 ]] && [[ $has_part -eq 1 ]] && [[ -n "$year_in_path" ]] && (( count_vid <= 2 )); then
    tv_detected="false"
    log "Movie guard: Part/Pt + year + no S##E## + ≤2 files → treating as Movie"
  fi

  # Miniseries heuristic: many "parts" (≥5) → TV show
  if [[ "$tv_detected" == "false" ]]; then
    local parts_count
    parts_count=$(printf '%s\n' "$lower_names" \
      | grep -E '(^|[^a-z])((pt|part)[ ._-]?(i{1,3}|iv|v|vi{0,3}|ix|x|xi|xii|xiii|xiv|xv|xvi|xvii|xviii|xix|xx|[0-9]{1,3}))([^a-z]|$)' | grep -c . || true)
    if (( parts_count >= 5 )); then
      tv_detected="true"; log "Miniseries heuristic: ≥5 parts → treating as TV show"
    fi
  fi

  # Known miniseries path heuristic: force TV if path contains known series names
  if [[ "$tv_detected" == "false" ]]; then
    if printf '%s' "$src" | awk '{print tolower($0)}' | grep -Eq 'the[._ ]pacific|band[._ ]of[._ ]brothers'; then
      tv_detected="true"; log "Path heuristic: known miniseries name detected → treating as TV show"
    fi
  fi

  # Process as TV show
  if [[ "$tv_detected" == "true" ]]; then
    local qhint; qhint="$(make_query_hint "$src")"
    log "TV query hint: '$qhint'"
    log "FileBot TV format: TV Shows/{n} ({y})/Season {s.pad(2)}/{n} - S{s.pad(2)}E{e.pad(2)}{t ? \" - \" + t : \"\"}"
    if ! filebot_with_retry -rename "$src" -r \
      --db TheMovieDB::TV \
      --q "$qhint" \
      --output "$DEST_ROOT" \
      --format 'TV Shows/{n} ({any{y}{airdate.year}})/Season {s.pad(2)}/{n} - S{s.pad(2)}E{e.pad(2)}{t ? " - " + t : ""}' \
      --action copy \
      --conflict skip \
      -non-strict
    then
      log "FileBot TV failed; attempting manual placement"
      manual_place_tv "$src" "$qhint"
    fi
  # Process as Movie
  else
    local mhint; mhint="$(make_movie_hint "$src")"
    log "Movie hint: '$mhint'"
    log "FileBot Movie format: Movies/{n} ({y})/{n} ({y})"

    if movie_exists_in_library "$mhint"; then
      log "Movie '$mhint' appears to already exist in library; skipping"
    else
      if ! filebot_with_retry -rename "$src" -r \
        --db TheMovieDB \
        --q "$mhint" \
        --output "$DEST_ROOT" \
        --format 'Movies/{n} ({y})/{n} ({y})' \
        --action copy \
        --conflict skip \
        -non-strict
      then
        log_error "FileBot movie processing failed for: $mhint"
        log_error "Manual intervention may be required for: $src"
        return 1
      fi
    fi
  fi

  [[ "$DRY_RUN" == "1" ]] || touch "$(dirname "$src")/.extract_done"
  log "Successfully processed: $src"
}

# ========== Main ==========
main(){
  require_bin "$SEVENZ"; require_bin "$FILEBOT"

  log "========================================="
  log "Starting media extraction and processing"
  log "Watch directory: $WATCH_DIR"
  log "Destination root: $DEST_ROOT"
  log "7z tool: $SEVENZ ($(command -v "$SEVENZ" || echo "not found"))"
  log "FileBot: $FILEBOT ($(command -v "$FILEBOT" || echo "not found"))"
  [[ "$DRY_RUN" == "1" ]] && log "DRY_RUN mode: FileBot commands will be logged but not executed"
  [[ "$FORCE" == "1" ]] && log "FORCE mode: re-extracting and re-processing all content"
  log "========================================="

  # Ensure special-cases file exists with examples
  if [[ ! -f "$SPECIAL_CASES_FILE" ]]; then
    mkdir -p "$(dirname "$SPECIAL_CASES_FILE")"
    cat > "$SPECIAL_CASES_FILE" << 'EOF'
# Special case mappings for media titles
# Format: pattern|replacement  (case-insensitive substring match)
# Lines starting with # are comments
#
# Examples:
# the office uk|The Office (2001)
# the office us|The Office (2005)
# band of brothers|Band of Brothers
EOF
    log "Created special cases config: $SPECIAL_CASES_FILE"
  fi

  # Process root of WATCH_DIR first
  log "Processing root: $WATCH_DIR"
  local extracted_dir
  if extracted_dir="$(extract_rars_in_dir "$WATCH_DIR")"; then
    if [[ -n "${extracted_dir:-}" ]]; then
      filebot_sort "$extracted_dir"
      # Optionally clean up extracted temp folder if enabled and processed
      if [[ "$CLEANUP_EXTRACTS" == "1" ]] && [[ -f "$(dirname "$extracted_dir")/.extract_done" ]] && [[ -f "$extracted_dir/.by_media_script" ]]; then
        log "CLEANUP_EXTRACTS=1: removing extracted temp directory $extracted_dir"
        rm -rf "$extracted_dir"
      fi
    fi
  else
    log_error "Extraction failed for root: $WATCH_DIR"
  fi

  # Then immediate subdirectories (BSD/GNU portable)
  while IFS= read -r -d '' dir; do
    log "Processing directory: $dir"
    local sdir
    if sdir="$(extract_rars_in_dir "$dir")"; then
      if [[ -n "${sdir:-}" ]]; then
        filebot_sort "$sdir"
        # Optionally clean up extracted temp folder if enabled and processed
        if [[ "$CLEANUP_EXTRACTS" == "1" ]] && [[ -f "$(dirname "$sdir")/.extract_done" ]] && [[ -f "$sdir/.by_media_script" ]]; then
          log "CLEANUP_EXTRACTS=1: removing extracted temp directory $sdir"
          rm -rf "$sdir"
        fi
      fi
    else
      log_error "Extraction failed for: $dir"
    fi
  done < <(_find_dirs_lvl1 "$WATCH_DIR" -print0)

  log "========================================="
  log "Processing complete. Log file: $LOG_FILE"
  log "========================================="
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi