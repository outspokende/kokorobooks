# KokoroBooks — endgültige Simplifizierung

## Was der Nutzer will (final)

Jedes Buch hat genau **zwei Aktionen**, immer sichtbar, nie versteckt:

| Aktion | Button | Server | Lokal |
|---|---|---|---|
| **Streaming starten** | ▶️ Play | HLS-Stream sofort (während Generierung) | Nichts, nur Stream |
| **Download starten** | ⬇️ Download | MP3 wird generiert (Piper) | Wird direkt während Generierung heruntergeladen (Streaming-Download) |

**Danach:** MP3 lokal auf dem iPhone verfügbar, Offline-Player spielt es ab.

## Was muss passieren (Architektur)

### Server-Seite (Backend)

1. **Engine:** Piper TTS (`KBS_ENGINE=piper`), Modell `en_US-joe-medium`
2. **API:** `POST /api/convert` → startet Piper-Job, returned `job_id`
   - Der Job generiert Chunks nacheinander
   - **Gleichzeitig** wird das MP3 in den Output-Stream geschrieben
3. **API:** `GET /api/jobs/{id}/mp3` → streamt die in-progress MP3-Datei
   - Client kann sofort mit Download beginnen, auch wenn Job noch läuft
   - `Content-Length` ist nicht bekannt → Chunked Transfer-Encoding
4. **Single-Slot:** Nur EIN Job läuft gleichzeitig (bereits implementiert)
5. **Cancel:** `POST /api/jobs/{id}/cancel` (bereits implementiert)

### iOS-Seite

1. **BookRow vereinfachen:** ZWEI Buttons:
   - ▶️ **Play** (links) → NavigationLink zum Player, startet HLS-Stream
   - ⬇️ **Download** (rechts) → startet Konvertierung + lädt MP3 herunter
2. **Download-Button-Verhalten:**
   - Tap → `POST /api/convert` → `job_id`
   - Dann sofort `GET /api/jobs/{id}/mp3` als `URLSession.downloadTask`
   - Fortschrittsbalken zeigt Download-Fortschritt (nicht Server-Generierung!)
   - Wenn Download fertig → Button wird "✅ Gespeichert"
3. **Kein PlayerView-Download mehr:** Der Download lebt nur im BookRow
4. **Offline-Player:** DownloadedView spielt lokale MP3s ab (existiert bereits)

### Was NICHT mehr passiert

- ❌ Kein "Prepare for offline" / "Server generating..." — nur Download mit Fortschritt
- ❌ Kein PlayerView-eigener Download-Button — das verwirrt nur
- ❌ Kein Cancel nötig — der Download wird vom Client gesteuert, nicht vom Server
- ❌ Kein Staging zwischen "nicht bereit" und "bereit" — MP3 wird direkt gestreamt

## Implementierungsreihenfolge

### Phase 1: Backend (Piper + MP3-Streaming)
1. Piper Engine in `engine/piper.py` (existiert)
2. `POST /api/convert` → Piper-Job starten, MP3 direkt schreiben
3. `GET /api/jobs/{id}/mp3` → chunked MP3-Stream während Generierung
4. Server deployed → Test mit curl

### Phase 2: iOS
1. BookRow: Play-Button links, Download-Button rechts
2. Download startet → `POST /api/convert` → `GET /api/jobs/{id}/mp3` parallel
3. Fortschrittsbalken während Download
4. Kein PlayerView-Download mehr
5. Offline-Player aus DownloadedView

## Geschätzte Dauer
- Backend: 45 min (Piper-Integration ist neu, MP3-Streaming braucht Worker-Änderung)
- iOS: 30 min (Buttons umbauen + Download-Task)
- Test: 15 min
- **Gesamt: ~90 min**
