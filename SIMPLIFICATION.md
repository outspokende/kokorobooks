# KokoroBooks Simplification — Plan

## Reality check: what the user is actually experiencing

User: "I tap the download button and nothing happens."

Three confirmed bugs make this happen:

### Bug #1 (root cause of "nothing happens"): voice_id=0 default
- `@AppStorage("voiceID") private var voiceID = 0` in DownloadControl
- `api.convert(bookID:, voiceID: 0, ...)` -> server returns 400 "unknown voice"
- `BookRowDownloadControl`'s Button action: `} catch { /* ignore */ }` — silent
- **The button-tap DOES fire, the request DOES go out, the server DOES reject, but the user sees nothing because errors are swallowed.**

### Bug #2: Server accepts unlimited concurrent jobs
- `supervisor._pick_job()` has no concurrency guard
- 9 books now queued in parallel
- CPU contention: N95 with kokoro-onnx can only really do 1-2 at a time
- Net effect: every job is slow because they fight for CPU/memory

### Bug #3: No cancel endpoint
- `supervisor.cancel_job()` exists internally but no HTTP route
- Stopping a stuck generation requires SSH + manual job deletion

## Plan (in this order)

### Phase 1: Backend (server.py + supervisor.py)
1. **Add concurrency limit = 1** to supervisor: introduce `_active_slot` field, refuse
   to start a new job if `len(active) >= 1`. Return `"queued"` but do not start the
   worker. The worker's exit on completion calls `start_queue()` to pick the next.
2. **Add POST /api/jobs/{job_id}/cancel** that calls `supervisor.cancel_job(id)`,
   deletes the audio_cache row for that cache key, and returns the new job list.
3. **Auto-promote** a queued job when the single slot frees up.

### Phase 2: iOS (Views.swift, APIClient.swift)
1. **Consolidate 3 BookRow variants → 1 `BookRow`** that owns its tap targets
   internally (no outer NavigationLink swallowing the button area).
2. **Add visible error feedback** for convert failures: show a toast/banner
   inside the row that says "Server error: <message>". Keep it minimal.
3. **Add "Abbrechen" (cancel) button** next to the progress indicator so the user
   can stop a stuck generation.
4. **Default voice_id** to the user's previously selected voice (not 0).
   If user has never selected a voice, prompt them to pick one from /api/voices
   and use the first available as fallback (already done in `load()`).

### Phase 3: Verification
1. Backend: hit POST /api/convert + GET /api/jobs/{id}/status to confirm
   single-slot queueing (one queued stays queued while another runs).
2. iOS: xcodebuild Debug build clean.
3. Real test on iPhone: tap download, see either (a) progress bar with %
   or (b) red error text within 2 seconds. Never silent.

## What NOT to do (rules for this session)

- No new feature additions
- No new structs unless required for consolidation
- Every code change must be followed by hermes-verify tempfile result
- If something doesn't work end-to-end, revert and re-plan, don't patch
