# Setup

See the [README quick start](README.md#quick-start) for the supported install path.
This page records the complete first-run checklist for a personal Apple Silicon
server. If you would rather have an AI assistant run it, use the prompts in
[`INSTALL_WITH_AI.md`](INSTALL_WITH_AI.md).

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
python -m app.samples
python -m app.serve
```

`python -m app.samples` builds the public-domain starter library into
`~/Audiobooks/PDFs/Public Domain Samples` so there is something to listen to
immediately. It is optional and downloads nothing but plain text; see
[`samples/README.md`](samples/README.md) for the catalog, the rights record,
and the `--list`, `--only`, `--dest` and `--force` options.

Place PDFs you have permission to process in `~/Audiobooks/PDFs`. The server
prints its bearer token at startup. Keep the token private. The default data
directory is `~/Library/Application Support/KokoroBooks`; override it with
`KBS_DATA_DIR`. Override the PDF directory with `KBS_LIBRARY_DIR`.

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
limitations are in [`ios/README.md`](ios/README.md). For a physical-device
build, change the example bundle identifier in `ios/project.yml` to one owned
by your Apple Developer account and regenerate the project.

## Model and generated data

MLX Audio downloads model files as needed on first use. The application data,
prepared text, state database, logs, and audio cache are kept outside the Git
checkout by default. Never commit personal PDFs, generated audiobooks, tokens,
or server data.
