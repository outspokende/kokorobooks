# KokoroBooks Constitution

1. KokoroBooks is operationally independent from audiobookServer: bundle ID, port, token, database, cache, logs, and launchd label never overlap.
2. The only shared state is the read-only source library at `~/Audiobooks/PDFs`.
3. TTS uses local Kokoro 82M through MLX; no PocketTTS dependency or voice cloning is exposed.
4. Every non-health API route remains bearer-token protected and paths remain traversal-safe.
5. Five curated American male voices are stable presets and selectable in the iOS app.
6. Backend tests and a signed physical-device build are release gates.
