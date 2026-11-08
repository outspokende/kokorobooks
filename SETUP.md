# Setup

See the [README quick start](README.md#get-started) for the supported install path.
This page records the complete first-run checklist for a personal Apple Silicon
server.

## Requirements

- Apple Silicon Mac running macOS, Python 3.11, and Xcode for the iOS client.
- Homebrew and FFmpeg (`brew install ffmpeg`).
- XcodeGen for generating the iOS project (`brew install xcodegen`).
- Network access on first run to install Python packages and retrieve Kokoro model
  files through MLX Audio. The install also fetches the English spaCy pipeline
  used by Kokoro's text front end.

## Backend

```bash
git clone https://github.com/outspokende/kokorobooks.git
cd kokorobooks/backend
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -r requirements.txt
mkdir -p ~/Audiobooks/PDFs
python -m app.serve
```

Place PDFs or prepared TXT files you have permission to process in the library
folder. By default, the server uses `~/Audiobooks/booksOUT` when it exists,
otherwise `~/Audiobooks/PDFs`. The server prints its bearer token at startup.
Keep the token private. The default data directory is
`~/Library/Application Support/KokoroBooks`; override it with `KBS_DATA_DIR`.
Set `KBS_LIBRARY_DIR` to select the scanned input folder. To use covers and
processed text from a separate build-library output folder, set
`KBS_BOOKS_OUT_DIR` too. The full setting inventory is in
[`inventory.md`](inventory.md).

The first synthesis downloads the configured Kokoro model from Hugging Face if
it is not already cached. The English spaCy pipeline is installed during the
`pip install` step so first use does not need to fetch it inside a running job.

To use a different listening port, set `KBS_PORT` before starting the server.
The server binds to `0.0.0.0` by default for access on a trusted home network.
Do not expose it directly to the public internet or configure router port
forwarding.

## iOS client

```bash
brew install xcodegen
cd ../ios
xcodegen generate
open KokoroBooks.xcodeproj
```

Select your own Apple Developer signing team in Xcode, build the app, then enter
the backend URL and bearer token in the app settings. Details and known client
limitations are in [`ios/README.md`](ios/README.md).

## Model and generated data

MLX Audio downloads model files as needed on first use. The application data,
prepared text, state database, logs, and audio cache are kept outside the Git
checkout by default. Never commit personal PDFs, generated audiobooks, tokens,
or server data.
