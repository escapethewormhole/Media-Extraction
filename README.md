# Media Extraction + FileBot Sorter (macOS/Linux)

Automates extraction of multi-part archives (RAR/7z/ZIP) and sorts them into a clean Plex/Emby/Jellyfin‑ready library using **FileBot**.  
Designed to be **idempotent**, **macOS‑safe**, and **resilient** — with retries, fallbacks, and optional cleanup.

---

## Features

- Extracts single & multi‑part archives (`.rar`, `.part1.rar`, `.r00`, `.7z`, `.7z.001`, `.zip`, `.z01`, etc.)
- Smart TV vs Movie detection (episode markers, parts, mini‑series heuristics)
- Uses **FileBot** for renaming/sorting:
  - **TV:** `TV Shows/{n} ({y})/Season {s}/{n} - S{s}E{e} - {t}`
  - **Movies:** `Movies/{n} ({y})/{n} ({y})`
- **Copy‑only** import (`--action copy`) — keeps seeding archives untouched
- Idempotent (no re‑processing unless archives change)
- Retries on extraction or lookup failures
- Optional cleanup of `.extract_tmp` folders after success
- Supports custom title mappings for tricky series

---

## Requirements

| Dependency | Description |
|-----------|-------------|
| **7‑Zip** (`7zz` preferred) | Archive extractor |
| **FileBot CLI** | Renaming and metadata |
| **unar** *(optional)* | Fallback extractor on macOS |

### macOS
```bash
brew install sevenzip unar
```

### Linux
```bash
sudo apt install p7zip-full unar
```

Install **FileBot** from the official website or your package manager.

---

## Quick Start

1. Make the script executable:
   ```bash
   chmod +x media-extraction.sh
   ```

2. Run it:
   ```bash
   bash media-extraction.sh "/path/to/downloads"
   ```

By default, it will sort into:
```
/path/to/library
  ├── Movies/
  └── TV Shows/
```

---

## Configuration

| Variable | Default | Description |
|-----------|----------|-------------|
| `WATCH_DIR` | `"$1"` or `/path/to/downloads` | Folder to scan for archives (qBittorrent can pass `%D`) |
| `DEST_ROOT` | `/path/to/library` | Root of the organized library |
| `SEVENZ` | auto-detect | `7zz` or `7z` binary |
| `FILEBOT` | `filebot` | FileBot CLI binary |
| `FORCE` | `0` | `1` = re-extract & re-process all content |
| `DRY_RUN` | `0` | `1` = log FileBot actions without writing |
| `PROGRESS` | `0` | `1` = show extractor/FileBot progress |
| `MAX_RETRIES` | `3` | Retry attempts for extraction/FileBot |
| `RETRY_DELAY` | `5` | Delay (seconds) between retries |
| `CLEANUP_EXTRACTS` | `0` | `1` = remove `.extract_tmp` folders after success |
| `SPECIAL_CASES_FILE` | `~/.config/media-script/special-cases.conf` | Custom title name mapping file |

---

## Special Case Mapping (optional)

**File:**
```
~/.config/media-script/special-cases.conf
```

**Format:**
```
pattern|replacement
```

**Example:**
```
sample keyword|Desired Title (2010)
uk version|Show Name (2001)
us version|Show Name (2005)
```

---

## How It Detects TV vs Movies

| Rule | Interpreted As |
|------|----------------|
| Contains `SxxEyy`, `E##`, `Ep ##` | TV |
| Contains `Part/Pt` + Year + ≤2 files, no S/E markers | Movie |
| ≥5 “Part” files | TV (miniseries) |

> Note: Path-based forced matches using specific show names were removed to avoid hardcoded titles.

---

## Safety & Idempotency

- The script **never** alters or deletes the original seeding archives.
- Extraction is done into a sibling temp directory (`.extract_tmp`).
- Each folder gets:
  - `.extract_sig` → archive signature  
  - `.extract_done` → mark of completion  
  - `.by_media_script` → ownership flag for safe cleanup
- Re-running the script on the same content does **nothing** unless forced.

---

## Optional Cleanup

To automatically remove extracted temp folders after successful processing:
```bash
CLEANUP_EXTRACTS=1 bash media-extraction.sh "/path/to/downloads"
```
This removes only `.extract_tmp` directories **created by the script** after success.

---

## Integration (qBittorrent Example)

In **Preferences → Downloads → Run external program on torrent completion**:
```bash
bash /path/to/media-extraction.sh "%D"
```

`%D` is the torrent’s download directory.

Optionally combine with cleanup:
```bash
CLEANUP_EXTRACTS=1 bash /path/to/media-extraction.sh "%D"
```

---

## Logging

Logs are written to:
```
/tmp/extract_and_filebot.log
```
Each entry includes timestamps and extraction/FileBot messages for troubleshooting.

---

## Example Commands

Dry run (no file changes):
```bash
DRY_RUN=1 PROGRESS=1 bash media-extraction.sh "/downloads"
```

Force full re-processing:
```bash
FORCE=1 bash media-extraction.sh "/downloads"
```

Extract, sort, and clean up temp folders:
```bash
CLEANUP_EXTRACTS=1 bash media-extraction.sh "/downloads"
```

---

## Troubleshooting

- **Missing commands** → Ensure `filebot` and `7zz` are in your PATH.  
- **FileBot mismatch** → Add an override in `special-cases.conf`.  
- **Passworded archives** → Not supported; extract manually first.  
- **Multiple archive sets** → Script processes one per folder; rerun for others.

---
