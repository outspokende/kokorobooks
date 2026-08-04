# iOS app (SwiftUI + AVPlayer)

Starter sources for the client. They are framework-only (no `.xcodeproj` checked
in) so you create the project once in Xcode and drop these files in.

## Build the project
The Xcode project is generated from `project.yml` (no `.xcodeproj` in git):
```bash
cd ios
xcodegen generate           # creates KokoroBooks.xcodeproj
open KokoroBooks.xcodeproj   # or build from the CLI below
```
CLI build + install to a connected iPhone:
```bash
DEVID=$(xcrun xctrace list devices 2>&1 | grep -v Simulator | grep iPhone | head -1)
xcodebuild -project KokoroBooks.xcodeproj -scheme KokoroBooks \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  -derivedDataPath build build
xcrun devicectl device install app <device-udid> \
  build/Build/Products/Debug-iphoneos/KokoroBooks.app
```
Signing/Background-Audio/ATS are already configured in `project.yml`
(team `YOUR_DEVELOPMENT_TEAM`, bundle id `com.henningjaeger.kokorobooks`).

## First launch
Open **Settings** in the app and enter:
- **Server URL**: `http://<your-mac>.<tailnet>.ts.net:8724` (MagicDNS name).
- **API token**: printed by the server on startup
  (`tail -f ~/Library/Logs/audiobookserver.out.log`).

## What the starter covers
- `APIClient` — bearer-auth REST calls (library, convert, status, progress).
- `PlayerViewModel` — `AVPlayer` HLS playback, chapter seek, Now-Playing info,
  and last-position sync to the server (last-write-wins). **Offline-first**: if a
  book is downloaded it plays the local M4B with no server round-trip.
- `DownloadManager` — downloads the finished `.m4b` (`GET /api/jobs/{id}/audio`)
  to `Documents/Audiobooks/`, tracks a manifest, and evicts least-recently-played
  files past a soft local cap (default 4 GB).
- `LibraryView` / `PlayerView` — browse, start conversion, watch progress while
  it streams, scrub chapters, download/remove for offline, offline badges.

## Not yet wired (optional next steps)
- `AVAssetDownloadTask` for offline HLS (we download the finished M4B instead —
  simpler and Audible-like).
- A dedicated "Downloads" management screen (current UI manages per-book).
