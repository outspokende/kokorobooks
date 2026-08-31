# KokoroBooks — Setup

## Quick Start

```bash
# 1. Repo klonen
git clone https://github.com/outspokende/kokorobooks.git
cd kokorobooks

# 2. venv erstellen
python3 -m venv backend/.venv
source backend/.venv/bin/activate
pip install -r backend/requirements.txt

# 3. Models herunterladen (Kokoro TTS)
# → https://github.com/remsky/Kokoro-ONNX/releases
# Modell nach data/models/ legen (siehe docs in specs/)

# 4. Piper Voices herunterladen
# → https://github.com/rhasspy/piper/releases
# Stimme nach data/piper-voices/ legen

# 5. Library vorbereiten
# PDFs nach library/ legen (beliebige Unterordner)
# →library/STAR_WARS_ERA/PDFs/

# 6. Konfiguration
cp specs/memory/example.json data/memory/config.json
# api_token.txt in data/ ablegen (Token von kokoro-endpoint oder own endpoint)

# 7. Start
cd backend
KBS_LIBRARY_DIR=/opt/kokorobooks/library \
KBS_DATA_DIR=/opt/kokorobooks/data \
KBS_ENGINE=piper \
KBS_HOST=0.0.0.0 \
KBS_PORT=8724 \
./.venv/bin/python -m app.serve
```

## Audio Cache

`data/audio_cache/` wird automatisch befüllt beim ersten Durchlauf. Nicht in Git — kann jederzeit gelöscht werden.

## Datenstruktur

```
kokorobooks/
├── backend/          # Python-Quellcode
│   ├── app/          # FastAPI app
│   ├── scripts/      # CLI scripts
│   ├── requirements.txt
│   └── tests/
├── data/
│   ├── api_token.txt         # Secret (NICHT in Git)
│   ├── models/               # Kokoro ONNX-Modell (nicht in Git)
│   ├── piper-voices/         # Piper Stimme (nicht in Git)
│   ├── audio_cache/          # Generierte M4B-Dateien (nicht in Git)
│   ├── state.sqlite3          # Verarbeitungsfortschritt
│   └── logs/
├── library/                   # PDFs hier ablegen (nicht in Git)
├── deploy/                    # macOS launchd plist
└── specs/                     # Konfiguration/Defaults
```

## Systemd Service (Linux)

```ini
# /home/USER/.config/systemd/user/kokorobooks.service
[Unit]
Description=KokoroBooks TTS Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/kokorobooks/backend
ExecStart=/opt/kokorobooks/backend/.venv/bin/python -m app.serve
Restart=on-failure
RestartSec=10

Environment=KBS_ENGINE=piper
Environment=KBS_HOST=0.0.0.0
Environment=KBS_PORT=8724
Environment=KBS_LIBRARY_DIR=/opt/kokorobooks/library
Environment=KBS_AUDIO_CACHE_GB=50
Environment=KBS_DATA_DIR=/opt/kokorobooks/data
Environment=KBS_FFMPEG=/usr/bin/ffmpeg
Environment=PATH=/opt/kokorobooks/backend/.venv/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
```

```bash
systemctl --user enable kokorobooks.service
systemctl --user start kokorobooks.service
```
