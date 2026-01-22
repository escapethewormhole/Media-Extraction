Extract + FileBot Sorter (macOS-safe Bash)

Automates the post-processing of downloaded media by extracting archives into a temporary staging folder and sorting Movies/TV into a clean, Plex/Emby/Jellyfin-ready library using FileBot.

Safe for seeding workflows: The original download folder and files are never modified. Only the generated .extract_tmp directory is moved into your library, ensuring your torrent client remains undisturbed.

Scripts

Media Extraction.sh

The main pipeline.

Extraction: Scans for .rar, .7z, or .zip and extracts them to <release>/.extract_tmp.

Intelligence: Detects TV vs. Movie using advanced filename heuristics and "miniseries" detection.

Sorting: Renames and moves files using FileBot (TheMovieDB / TheMovieDB::TV).

Clean-up: Automatically deletes the temp folder after successful sorting and marks completion with .extract_done.

qbittorrent_hook.sh

A wrapper for qBittorrent’s “Run external program on torrent completion” feature. It targets the specific torrent path to avoid unnecessary scans and runs the main script in the background (nohup) so qBittorrent can continue its queue immediately.

Key Features

Automation & Resilience

Settle Wait: Waits for archives to stop being modified (MIN_RAR_AGE) before extracting to prevent errors on slow disks or active downloads.

Exponential Backoff: Retries FileBot operations up to 3 times (configurable) with increasing delays to handle API rate limits or network hiccups.

Integrity Checks: Uses ffprobe to verify video file health before moving them into your library.

Disk Space Guard: Calculates required space (default 2.5x archive size) before beginning extraction to prevent "Disk Full" errors.

Intelligence & Fallbacks

Fuzzy Matching: Enhanced movie duplicate detection allows for minor punctuation or naming differences when checking if a movie already exists in your library.

Manual Fallback: If FileBot fails to identify a TV show, the script performs a manual "best-effort" placement based on folder names and common episode patterns.

Query Hinting: Strips common release tags (HEVC, 1080p, etc.) to provide FileBot with a clean title for better metadata matching.

Safety & Performance

Idempotency: Uses .extract_sig (MD5 signature of archive state) to skip processing unless the archives have changed.

Parallel Processing: Processes subdirectories in parallel using xargs -P to maximize CPU/Disk throughput.

Concurrency Lock: A lockfile prevents multiple instances from running simultaneously, with automatic stale-lock detection.

Stale Cleanup: Automatically identifies and removes .extract_tmp folders older than 24 hours.

Configuration
The script loads settings from ~/.extract_and_filebot.conf. You can override any of these variables:

Variable	Default	Description
DEST_ROOT	/Volumes/Vault/Extracted Media	The root of your organized library.
PARALLEL_JOBS	2	Number of concurrent extraction/sort tasks.
STREAM_MODE	1	Start processing immediately as folders are found.
DISK_SPACE_MARGIN	2.5	Multiplier for free space required vs archive size.
FILEBOT_RETRY	3	Number of retry attempts for FileBot API calls.
VERIFY_VIDEO	1	Set to 1 to use ffprobe for integrity checks.
FORCE	0	Set to 1 to ignore signatures and re-process everything.
QUIET	0	Set to 1 to suppress "already processed" logs.

Installation Requirements

7-Zip: brew install sevenzip (The script prefers 7zz).

FFmpeg: brew install ffmpeg (Required for video verification).

FileBot: Official CLI version installed and licensed.

Unar: brew install unar (Optional fallback extractor).

qBittorrent Setup

Open Preferences → Downloads.

Check Run external program on torrent completion.

Enter the command: bash "/path/to/qbittorrent_hook.sh" "%D" "%L" "%N"

Logs

Main Script Log: /tmp/extract_and_filebot.log

qBittorrent Hook Log: /tmp/qbittorrent_hook.log