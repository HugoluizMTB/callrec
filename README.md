# CallRec

CallRec is a small native macOS menu-bar app that records calls and meetings,
transcribes them **on your Mac**, and turns each one into a Markdown note with a
summary, key points, decisions and next steps — Fathom-style, without a bot
joining your meeting.

It records two tracks: your microphone and the system audio (the other side of
a Meet, Zoom, Teams, FaceTime or WhatsApp call), so the transcript knows who said
what.

The app is written in SwiftUI and distributed as a Swift Package executable.

## How it works

| Step | What happens | Where |
| --- | --- | --- |
| **Record** | System audio through a Core Audio process tap, microphone through AVCaptureSession. Two AAC tracks, kept in sync. | On your Mac |
| **Transcribe** | Apple's on-device `SpeechAnalyzer` / `SpeechTranscriber`. Offline, no audio leaves the Mac. | On your Mac |
| **Summarize** | Title, summary, key points, decisions and next steps with `mm:ss` timestamps, via OpenAI `gpt-4o-mini`. Only the transcript text is sent. | OpenAI API |
| **Store** | One folder per call (audio + `.md`), plus a SQLite index with full-text search. | `~/Documents/callrec` |

A 30-minute call costs roughly 8–15k input tokens and ~600 output tokens to
summarize — about a fifth of a US cent with `gpt-4o-mini`.

## Features

- **One click** — menu-bar icon → *Gravar* / *Parar e transcrever*.
- **Notes window** — calls grouped by day, date filters (today, 7 days, this
  month, any day), and full-text search across titles, summaries and transcripts.
- **Readable Markdown** — notes render in the app; click any timestamp to play
  the audio from that point. Edit (`⌘E`, save with `⌘S`) or delete (to the Trash).
- **Bluetooth-safe** — system audio stays at 48 kHz even when a Bluetooth headset
  drops into hands-free mode.
- **Import** — drop in recordings made elsewhere (for example the iPhone's
  built-in call recorder) with *Importar áudio…*.

The interface is in Brazilian Portuguese. Transcription follows the system
language or the one picked in *Idioma da transcrição*; notes are written in the
language of the call.

## Requirements

- macOS 26 or later (for `SpeechAnalyzer`), Apple silicon recommended
- Xcode 26 or later, including the Command Line Tools
- Swift 6.2
- An OpenAI API key for titles and summaries (optional — without it, calls are
  still recorded and transcribed)

## Permissions

CallRec asks for two standard macOS permissions the first time you record:

- **Microphone** — your side of the call.
- **System audio recording** — the other side. No screen recording permission is
  needed.

The OpenAI key is stored in the macOS Keychain (menu-bar icon → *Definir chave da
OpenAI…*), or read from `OPENAI_API_KEY` if set. It is never written to disk in
plain text or to the repository.

## Run locally

```bash
git clone https://github.com/HugoluizMTB/callrec.git
cd callrec

./scripts/bundle.sh release --install
```

This builds the app, signs it with your local Apple Development identity if you
have one (ad-hoc otherwise), copies it to `/Applications` and launches it. Signing
with a stable identity keeps macOS permissions across rebuilds; set
`CALLREC_SIGN_IDENTITY` to pick a specific certificate.

Without installing:

```bash
./scripts/bundle.sh debug
open build/CallRec.app
```

Command-line helpers for scripting:

```bash
/Applications/CallRec.app/Contents/MacOS/CallRec --import ~/Downloads/call.m4a
/Applications/CallRec.app/Contents/MacOS/CallRec --reprocess 12
```

## Recording phone calls

iOS does not let any app capture call audio. To record a call from your iPhone,
answer it **on the Mac** (iPhone → Settings → Phone → *Calls on Other Devices*)
and press record, or use the iPhone's built-in call recording and import the
audio file.

Recording laws vary. In many places you may record a conversation you take part
in, but sharing it can require consent. Check the rules where you live.

## Project layout

```text
Sources/CallRec/
├── main.swift       Menu-bar item and command-line entry points
├── Recorder.swift   Core Audio tap (system audio) + microphone capture
├── Pipeline.swift   On-device transcription, summary, Markdown output
├── Store.swift      SQLite storage and full-text search
├── UI.swift         Notes window (SwiftUI)
└── Settings.swift   Keychain API key and transcription language
```

No third-party dependencies.

## License

MIT
