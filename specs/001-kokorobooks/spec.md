# KokoroBooks

## User story
As an audiobook listener I can browse the same PDF library in a separate iOS app, choose one of five Kokoro US male voices, and stream/download generated speech without affecting audiobookServer.

## Acceptance criteria
- Service runs as `com.kokorobooks` on port 8724 with state in `~/Library/Application Support/KokoroBooks`.
- Library resolves to `~/Audiobooks/PDFs`.
- Kokoro MLX synthesizes at 24 kHz with Michael, Adam, Eric, Liam, and Onyx presets.
- `/api/library` returns those voices and conversion accepts their IDs.
- iOS app is named KokoroBooks, bundle ID `com.henningjaeger.kokorobooks`, and defaults to port 8724.
- Existing browse, streaming, chapters, transcript, progress, recap, and download behavior is preserved where engine-independent.
- App installs and launches on `i15Henning`.
