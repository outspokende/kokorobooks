<div align="center">

# KokoroBooks

### Your audiobook starts playing while Kokoro is still making it.

A self-hosted audiobook server for your own PDF library, with an iOS player that can stream generated audio while it is being created.

[![Platform](https://img.shields.io/badge/Apple_Silicon-MLX-13b8a6?style=for-the-badge)](#requirements)
[![Backend](https://img.shields.io/badge/Backend-Python-3776ab?style=for-the-badge)](#how-it-works)
[![iOS](https://img.shields.io/badge/Client-iOS-111827?style=for-the-badge)](#generate-and-build-the-ios-app)
[![Status](https://img.shields.io/badge/Status-Prototype-f59e0b?style=for-the-badge)](#project-status)

[Get started](#get-started) · [How it works](#how-it-works) · [API](#api-overview) · [Status](#project-status)

</div>

---

## What is KokoroBooks?

KokoroBooks turns PDFs in a folder on your Apple Silicon Mac into spoken audio with Kokoro 82M. The iPhone app can start playback from the growing audio stream before the full book has finished generating. When generation completes, the server assembles an M4B for offline listening.

The project is designed for a personal library on a trusted home network or Tailscale network. Your PDFs remain on your server. KokoroBooks does not clone voices.

> **Prototype:** the backend has working PDF preparation, Kokoro synthesis, HLS streaming, authentication, progress sync and cache components. The iOS app is an early implementation. See [Project status](#project-status) for the limits of validation.

## Why stream while generating?

Traditional conversion makes you wait for the whole book. KokoroBooks generates speech in chunks and feeds them into an HLS stream. The iPhone can begin listening as soon as playable segments exist, while the server continues working through the book.

## Features

- Scan a server-side PDF library and identify books by content hash.
- Extract and prepare text before synthesis, with chapter-aware chunks and a cover image.
- Generate audio with Kokoro 82M through MLX on Apple Silicon.
- Stream generated audio to iOS using HLS while synthesis continues.
- Resume listening position across devices.
- Cache completed audio with size-bounded least-recently-played eviction.
- Assemble a final M4B for offline download when a job completes.
- Protect API operations with a bearer token.

## Requirements

- macOS on Apple Silicon. MLX requires Apple Silicon.
- Python 3.11.
- FFmpeg available to the backend for HLS muxing and M4B assembly.
- An iPhone running a compatible iOS version and reachable server.
- Network access to install dependencies and retrieve the model on first setup.

## Get started

### 1. Install and run the backend

```bash
git clone https://github.com/outspokende/kokorobooks.git
cd kokorobooks/backend
python3.11 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
mkdir -p ~/Audiobooks/PDFs
python -m app.serve
```

Put PDFs you have permission to process in `~/Audiobooks/PDFs`. On startup, the server prints an API bearer token. Keep it private.

### 2. Generate and build the iOS app

Install XcodeGen, then generate the Xcode project:

```bash
brew install xcodegen
cd ../ios
xcodegen generate
open KokoroBooks.xcodeproj
```

Choose your Apple Developer signing team in Xcode, build, and run on your iPhone. In the app settings, enter the server URL and the bearer token printed by the backend. See [`ios/README.md`](ios/README.md) for client setup and current limitations.

### 3. Connect securely

Use the Mac and iPhone on the same trusted LAN or Tailscale tailnet. KokoroBooks is intended for private network access. Do not expose the API to the open internet or configure router port forwarding.

## How it works

```text
PDF library
    │
    ├── content hash and prepared-text cache
    ▼
Supervisor ──> one Kokoro / MLX worker ──> ordered audio chunks
    │                                      │
    ├── FFmpeg HLS muxer <─────────────────┘
    │       └── growing playlist and segments ──> iOS AVPlayer
    │
    └── on completion: final M4B + cache registration
```

The server API uses bearer authentication. The HLS stream is consumed by the iOS client. Listening progress is stored per book so playback can resume later.

## API overview

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/library` | List books and cached status |
| `GET` | `/api/library/{book_id}/cover` | Get a book cover |
| `POST` | `/api/library/{book_id}/prepare` | Prepare text without starting synthesis |
| `POST` | `/api/convert` | Start or attach to conversion |
| `GET` | `/api/jobs/{id}/status` | Read job and playback status |
| `GET` | `/api/jobs/{id}/chapters` | Get chapter timing |
| `GET` | `/api/jobs/{id}/audio` | Download completed M4B |
| `GET` | `/api/stream/{id}/index.m3u8` | Read the growing HLS playlist |
| `GET` | `/api/monitoring` | Read authenticated service status |
| `GET` / `PUT` | `/api/library/{book_id}/progress` | Read or update listening position |

All API calls require the configured bearer token. See [`backend/`](backend) for implementation details.

## Project status

KokoroBooks is an experimental personal project, not a polished consumer app. Backend pieces for PDF preparation, streaming, progress, authentication and cache behavior have been exercised individually. The iOS client is an early implementation and requires Xcode configuration for your environment.

Before relying on it for a full library, verify the complete flow with your own non-sensitive sample PDF and review the generated text and audio. The project has not been validated as a production-grade or internet-facing service.

## Privacy and rights

The server processes PDFs from its configured local library. Do not put private books, generated audio, personal library data, API tokens or server configuration in issues or pull requests. Process only material you have permission to use. This project does not bypass DRM.

KokoroBooks uses Kokoro 82M through MLX. Review the terms for Kokoro, MLX Audio, PyMuPDF and other dependencies before redistribution or commercial use. See the [Kokoro model card](https://huggingface.co/mlx-community/Kokoro-82M-bf16) and the [PyMuPDF license information](https://pymupdf.io/licensing).

## Repository map

- [`backend/`](backend) — Python API, PDF processing, audio generation, streaming and cache.
- [`ios/`](ios) — SwiftUI client and playback.
- [`deploy/`](deploy) — launchd service template. Adjust paths for your own Mac before use.
- [`SIMPLIFICATION.md`](SIMPLIFICATION.md) — design notes and scope decisions.

## Contributing

Bug reports and focused improvements are welcome. Please use a synthetic or public-domain test document when reporting PDF-processing issues. Remove private paths, tokens, book metadata and personal information from logs and screenshots.
