# Project inventory

This file summarizes the public interfaces and supported inputs. For setup and
the current validation status, start with [README.md](README.md) and
[SETUP.md](SETUP.md).

## Inputs and runtime

| Item | Details |
|---|---|
| Runtime | macOS on Apple Silicon; Python 3.11; Kokoro 82M through MLX Audio |
| Inputs | Searchable PDFs and UTF-8/plain-text TXT files |
| PDF text extraction | PyMuPDF; the app can skip detected front matter when preparing a PDF |
| Prepared text | Optional recursive TXT library; each file is cleaned and chunked before synthesis |
| Audio | Progressive HLS playback; completed M4B or MP3 output |
| iOS client | SwiftUI and AVPlayer; generated with XcodeGen from `ios/project.yml` |
| Network boundary | Authenticated API intended for a trusted LAN or Tailscale; do not expose it publicly |

## Library configuration

| Setting | Default / behavior |
|---|---|
| `KBS_LIBRARY_DIR` | Explicit folder recursively scanned for PDFs and TXT files. If unset, the server uses `~/Audiobooks/booksOUT` when it exists, otherwise `~/Audiobooks/PDFs`. |
| `KBS_BOOKS_OUT_DIR` | Optional root for preprocessed-book covers and TXT lookup; defaults to `~/Audiobooks/booksOUT`. |
| `KBS_DATA_DIR` | Application state, database, prepared-text cache, logs and generated audio. Defaults to macOS Application Support. |
| `KBS_HOST` / `KBS_PORT` | Bind address and port; defaults to `0.0.0.0:8724`. Keep access limited to a trusted network. |
| `KBS_FFMPEG` | FFmpeg executable; defaults to `ffmpeg` from `PATH`. |

Set `KBS_LIBRARY_DIR` to the same path as `KBS_BOOKS_OUT_DIR` when the
preprocessed TXT files are in that folder and should appear in the iOS library.

## API inventory

Every `/api` route requires the bearer token printed at startup.

| Route | Purpose |
|---|---|
| `GET /api/library` | Browse/search books, folders, voice options and cache status |
| `GET /api/library/{book_id}/cover` | Read an extracted or supplied cover image |
| `PUT /api/library/{book_id}/voice` | Save a per-book voice choice; send `{"voice_id": null}` to clear it |
| `POST /api/library/{book_id}/prepare` | Build the prepared text and chapter plan without synthesis |
| `POST /api/convert` | Start or resume M4B/MP3 generation |
| `GET /api/jobs/{id}/status` | Poll synthesis and playback progress |
| `GET /api/jobs/{id}/audio` | Download completed M4B |
| `GET /api/jobs/{id}/mp3` | Stream or download MP3 |
| `GET /api/stream/{id}/index.m3u8` | Read the progressive HLS playlist |
| `GET /api/queue/status` | Read queue counts |
| `POST /api/queue/wake` | Wake the queue supervisor |
| `POST /api/admin/reset-queue` | Cancel queued and active jobs |
| `GET /api/monitoring` | Read service health and worker status |

The complete route list is defined in `backend/app/server.py`; request and
response behavior should be kept aligned with `ios/AudiobookApp/APIClient.swift`.

## Built-in voices

| ID | Name | Voice key | Accent |
|---:|---|---|---|
| 1 | Michael | `am_michael` | American male |
| 2 | Adam | `am_adam` | American male |
| 3 | Eric | `am_eric` | American male |
| 4 | Liam | `am_liam` | American male |
| 5 | Onyx | `am_onyx` | American male |
| 6 | Emma (UK) | `bf_emma` | British female |
| 7 | Isabella (UK) | `bf_isabella` | British female |

KokoroBooks uses the model's built-in voices; it does not clone voices.
