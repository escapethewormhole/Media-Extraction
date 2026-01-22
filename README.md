# Extract + FileBot Sorter (macOS-safe Bash)

Automates the post-processing of downloaded media by extracting archives into a temporary staging folder and sorting Movies/TV into a clean, Plex/Emby/Jellyfin-ready library using FileBot.

**Safe for seeding workflows:** The original download folder and files are never modified. Only the generated `.extract_tmp` directory is moved into your library, ensuring your torrent client remains undisturbed.

---

## Scripts

### `Media Extraction.sh`

The main pipeline.

- **Extraction:** Scans for multi-part archives (`.rar`, `.7z`, `.zip`, and common part conventions) and extracts them to `<release>/.extract_tmp`.
- **Intelligence:** Detects TV vs. Movie using filename heuristics and miniseries detection.
- **Sorting:** Renames and moves files using FileBot (`TheMovieDB` / `TheMovieDB::TV`) from `.extract_tmp` into your library.
- **Clean-up:** Automatically deletes the temp folder after successful sorting and marks completion with `.extract_done`.

### `qbittorrent_hook.sh`

A wrapper for qBittorrent’s **“Run external program on torrent completion”** feature. It targets the specific torrent path to avoid unnecessary scans and runs the main script in the background (`nohup`) so qBittorrent can continue its queue immediately.

---

## Key Features

### Automation & Resilience

- **Settle Wait:** Waits for archives to stop being modified (`MIN_RAR_AGE`) before extracting to prevent errors on slow disks or active downloads.
- **Exponential Backoff:** Retries FileBot operations up to `FILEBOT_RETRY` times (default 3) with increasing delays to handle API rate limits or network hiccups.
- **Integrity Checks:** Uses `ffprobe` to verify video file health before moving them into your library (`VERIFY_VIDEO=1` by default).
- **Disk Space Guard:** Calculates required space (default `DISK_SPACE_MARGIN=2.5x` archive size) before beginning extraction to prevent “Disk Full” failures.

### Intelligence & Fallbacks

- **Fuzzy Matching:** Enhanced movie duplicate detection allows for minor punctuation or naming differences when checking if a movie already exists in your library.
- **Manual Fallback:** If FileBot fails to identify a TV show, the script performs a manual best-effort placement based on folder names and common episode patterns.
- **Query Hinting:** Strips common release tags (HEVC, 1080p, etc.) to provide FileBot with a clean title for better metadata matching.

### Safety & Performance

- **Idempotency:** Uses `.extract_sig` (MD5 signature of archive state) to skip processing unless the archives have changed.
- **Parallel Processing:** Processes subdirectories in parallel using `xargs -P` (`PARALLEL_JOBS`, default 2) to maximize CPU/Disk throughput.
- **Concurrency Lock:** A lockfile prevents multiple instances from running simultaneously, with automatic stale-lock detection.
- **Stale Cleanup:** Automatically identifies and removes `.extract_tmp` folders older than 24 hours (`TEMP_DIR_MAX_AGE`).

---

## Configuration

The script loads settings from:

- `~/.extract_and_filebot.conf` (default)  
- or override via `CONFIG_FILE=/path/to/config`

You can override any of these variables:

| Variable | Default | Description |
|---|---:|---|
| `DEST_ROOT` | `/Volumes/Vault/Extracted Media` | The root of your organized library. |
| `PARALLEL_JOBS` | `2` | Number of concurrent extraction/sort tasks. |
| `STREAM_MODE` | `1` | Start processing immediately as folders are found. |
| `DISK_SPACE_MARGIN` | `2.5` | Multiplier for free space required vs archive size. |
| `FILEBOT_RETRY` | `3` | Number of retry attempts for FileBot operations. |
| `VERIFY_VIDEO` | `1` | Set to 1 to use `ffprobe` for integrity checks. |
| `FORCE` | `0` | Set to 1 to ignore signatures and re-process everything. |
| `QUIET` | `0` | Set to 1 to suppress “already processed” logs. |

---

## Installation Requirements (macOS)

- **7-Zip:** `brew install sevenzip` (the script prefers `7zz`)
- **FFmpeg:** `brew install ffmpeg` (required for video verification via `ffprobe`)
- **FileBot:** official CLI installed and licensed
- **unar:** `brew install unar` (optional fallback extractor)

---

## qBittorrent Setup

1. Open **Preferences → Downloads**
2. Enable **Run external program on torrent completion**
3. Enter:

```bash
bash "/path/to/qbittorrent_hook.sh" "%D" "%L" "%N"
```

Where qBittorrent provides:

- `%D` = save path (directory where the torrent was saved)
- `%L` = category (if categories are enabled)
- `%N` = torrent name

The hook builds a per-torrent target path:

- `TARGET_PATH = %D/%N`

and then runs the main script in the background using `nohup` so qBittorrent can continue immediately.

---

## Logs

- **Main Script Log (qBittorrent runs):** `/tmp/extract_and_filebot_qbt.log`
- **qBittorrent Hook Log:** `/tmp/qbittorrent_hook.log`