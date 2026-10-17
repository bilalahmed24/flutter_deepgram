# flutter_deepgram example

A single-file Flutter demo (`lib/main.dart`) that exercises every major API
surface of the [`flutter_deepgram`](https://pub.dev/packages/flutter_deepgram) SDK
using **only Flutter SDK widgets** — no microphone, speaker, or file plugins.
A shared `DeepgramClient` is created from an API key field at the top of the
app (with a `--dart-define` fallback) and reused by all four tabs.

## Platform setup

The SDK itself needs **no permissions and no native configuration** — no
manifest entries, no Info.plist keys. The example therefore runs everywhere
Flutter runs:

- **Android**: nothing to configure. Run on any device/emulator with internet.
- **iOS**: nothing to configure. `flutter run` handles the rest.
- **macOS / Windows / Linux desktop**: nothing to configure.
- **Web**: the SDK authenticates via WebSocket subprotocols automatically; use
  a temporary-token provider (`DeepgramClient.withTokenProvider`) in real
  deployments instead of shipping an API key to the browser.

If you swap the synthetic-audio loops for a real microphone (e.g. `record` or
`flutter_sound`), **that plugin's** permission setup applies (Android
`RECORD_AUDIO`, iOS `NSMicrophoneUsageDescription`) — the SDK itself never
requests permissions.

## Running

```bash
cd example
flutter pub get
flutter run --dart-define=DEEPGRAM_API_KEY=your_key
```

The key can also be typed (or pasted) into the field at the top of the app and
activated with **Initialize client**.

## Building release artifacts

```bash
flutter build apk --release      # Android
flutter build ipa                # iOS (macOS host with Xcode required)
flutter build web                # Web
```

## What each tab demonstrates

| Tab | SDK surface | What it shows |
| --- | --- | --- |
| **Prerecorded** | `deepgram.prerecorded.transcribeFromUrl` + `deepgram.intelligence.analyze` | Transcribes a public audio URL (`POST /v1/listen`) with `smart_format`, `diarize`, `detect_entities`, `sentiment`, and v2 paragraph `summarize`, rendering the transcript, detected entities (`label: value`), per-segment sentiment, and summary; a second section analyzes pasted text through `POST /v1/read` (`TextIntelligenceOptions(sentiment, topics, summarize, intents)`). |
| **Live STT** | `deepgram.createLiveClient` (`WSS /v1/listen`) | Full session lifecycle: `start()`, `sendAudio()`, `finish()` (Finalize), `close()`. The connection state is shown as a colored chip from `connectionStates`, the transcript updates from `results` (finals appended, interims shown in italics), and every `UtteranceEnd` / `SpeechStarted` / `Metadata` / `Error` event lands in the in-app log. |
| **Text to Speech** | `deepgram.tts.speak` + `deepgram.tts.speakFlux` | Aura / Aura-2 synthesis (`POST /v1/speak`) with a voice dropdown (`DeepgramVoices.allV1`, first 20 of 102), linear16/mulaw encoding in a WAV container at 24 kHz, plus a Flux batch variant (`POST /v2/speak`, `FluxTtsOptions(model: flux-alexis-en, expressivity: 1)`). Reports byte count and elapsed time; the bytes are ready for an audio player (e.g. `just_audio`). |
| **Voice Agent** | `deepgram.createVoiceAgent` (`WSS /v1/agent/converse`) | A typed `VoiceAgentSettings` (greeting, nova-3 listen, OpenAI `gpt-4o-mini` think with a system prompt, `aura-2-thalia-en` speak, and a client-side `get_weather` function) is shown as JSON and sent via `start()`. Conversation text renders as chat bubbles, `agentThinking` / `agentStartedSpeaking` / `agentAudioDone` drive a status line, `functionCallRequests` are auto-answered with `sendFunctionCallResponse` (`{"temperature": 72, "unit": "F"}`), and errors/warnings go to the log. |

## Synthetic audio note

Tabs 2 and 4 deliberately avoid microphone plugins and permissions: the
**Send synthetic audio** button streams 50 chunks of 100 ms of zeroed
`linear16` samples (3200 bytes at 16 kHz for live STT, 4800 bytes at 24 kHz
for the agent) through `sendAudio()` to demonstrate pacing and session
mechanics. Because silence contains no speech, no transcript is expected —
watch the connection chip, byte counters, and event log instead. Replace the
loop with real PCM from your audio stack for production use.

Likewise, TTS and agent audio bytes are only counted, not played back: hand
them to your audio player of choice.
