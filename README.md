# audiobookServer

Headless server + iOS app for on-demand audiobook streaming. A Mac (Apple
Silicon) turns library PDFs into audiobooks with Pocket TTS voice cloning and
streams them to an iPhone **while they are still being generated** — so playback
starts within seconds instead of after a full conversion.

This is a separate project; the original desktop app
(`~/audiobookPocketTTS`) is untouched. Reusable pipeline modules
(`pdfproc`, `audio`, `worker`, `supervisor`, `db`, engine) were copied and
extended here.

## Why streaming works so well here
Pocket TTS generates ~10× realtime on an M2 Pro; playback is 1×. Once the first
HLS segment exists (~1–2 s of wall time), the generator stays far ahead of the
listener with a **single worker** — no parallel pool needed.

## Architecture

```
PDF (library folder) ──hash──> pre-clean cache (chunks/chapters/cover/meta)
        │  POST /api/convert
        ▼
   Supervisor ── 1 worker ──> chunk WAVs (in order)
        │                          │ feed PCM in order
        ▼                          ▼
   ffmpeg HLS muxer ──> growing index.m3u8 + fMP4/AAC segments ──> iPhone AVPlayer
        └─ on finish: #EXT-X-ENDLIST + final M4B (offline download)
   listening position  <── PUT/GET /api/library/{id}/progress ──> all devices
   audio cache (LRU, AUDIO_CACHE_MAX_GB) evicts least-recently-played books
```

- **`backend/app/library.py`** — scan the PDF folder, content-hash each book.
- **`backend/app/pdfproc` `prepare_or_load`** — pre-clean cache keyed by hash.
- **`backend/app/hls.py`** — one long-running ffmpeg HLS muxer fed PCM in order.
- **`backend/app/supervisor.py`** — single worker + HLS feed + nightly sleep
  window + M4B assembly + cache registration.
- **`backend/app/cache.py`** — size-bounded LRU eviction.
- **`backend/app/server.py`** — bearer-auth REST API.
- **`backend/app/serve.py`** — `python -m app.serve` headless entry.

## Run the server

```bash
cd backend
python3.11 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
mkdir -p ~/Audiobooks/PDFs        # drop your PDFs here
python -m app.serve               # prints the API token on startup
```

Key env vars: `ABS_HOST`, `ABS_PORT` (8723), `ABS_LIBRARY_DIR`,
`ABS_AUDIO_CACHE_GB` (20), `ABS_SLEEP_START`/`ABS_SLEEP_END` (23:55/04:00).

### Tests
```bash
cd backend
.venv/bin/pip install pytest          # once
.venv/bin/python -m pytest            # library / hls / progress / cache / preclean / server
```
The HLS tests need `ffmpeg` on PATH (they skip if absent).

### Run as a service (launchd)
Edit paths in `deploy/com.audiobookserver.plist`, then:
```bash
cp deploy/com.audiobookserver.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.audiobookserver.plist
```

The agent uses `RunAtLoad` + `KeepAlive`, so crashes are restarted
automatically. `ThrottleInterval=10` prevents a tight crash loop. The existing
Mac → Home Assistant monitor (`~/.local/bin/mac_ha_push.py`) checks `/health`
every 60 seconds, performs one `launchctl kickstart -k` self-heal attempt when
HTTP is unresponsive, and publishes:

- `binary_sensor.mac_audiobook_server` — connectivity
- `sensor.mac_audiobook_server` — idle/processing/queued/paused plus job
  progress, queue length, ready books, cache size, ETA, and restart-attempt flag

## Remote access & security
Run the Mac and iPhone on the same **Tailscale** tailnet and reach the server at
its MagicDNS name. Every API call needs the bearer token. **Do not** port-forward
this to the open internet.

## iOS app
See [`ios/README.md`](ios/README.md). SwiftUI + AVPlayer, browse → convert →
stream-while-generating, chapter seek, cross-device resume.

## API
| Method | Path | Purpose |
|---|---|---|
| GET | `/api/library` | list books + cached status |
| GET | `/api/library/{book_id}/cover` | cover image |
| POST | `/api/library/{book_id}/prepare` | pre-clean only |
| POST | `/api/convert` | start/attach conversion → stream URL |
| GET | `/api/jobs/{id}/status` | progress + playable flag |
| GET | `/api/monitoring` | authenticated compact service/job status |
| GET | `/api/stream/{id}/index.m3u8` | growing HLS playlist |
| GET | `/api/stream/{id}/{seg}` | init.mp4 / seg_*.m4s |
| GET | `/api/jobs/{id}/chapters` | chapter list + start times |
| GET | `/api/jobs/{id}/audio` | final M4B (offline download) |
| GET/PUT | `/api/library/{book_id}/progress` | cross-device position |
| GET/POST/PATCH/DELETE | `/api/voices…` | voice management |

## Status
Backend M0–M2 + cache + progress implemented and smoke-tested (HLS muxing,
auth, LRU eviction, progress LWW). End-to-end TTS reuses the proven
worker/supervisor path. iOS is a compilable starter, not yet a full Xcode
project (offline download is the main TODO).
