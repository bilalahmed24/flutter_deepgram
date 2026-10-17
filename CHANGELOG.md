# Changelog

All notable changes to this project will be documented in this file.

## 1.0.0 - 2026-10-17

### Initial stable release

A complete, production-grade Deepgram SDK for Dart and Flutter — pure Dart, no
platform channels, running unchanged on Android, iOS, Web, macOS, Windows, and
Linux.

#### Core

- Resilient WebSocket engine with generation tokens, so superseded reconnect
  chains can never resurrect dead connections or clobber newer ones.
- Connect-failure classification (`deepgramDefinitive` / `ambiguous` /
  `internetSuspect`) with connectivity-probe corroboration before giving up;
  only repeated corroborated definitive failures (e.g. bad credentials) stop
  reconnection.
- Exponential backoff with ±25 % jitter, clamped between configurable bounds
  (default 1–30 s), to prevent thundering-herd reconnects.
- KeepAlive heartbeats on every streaming socket (configurable interval and
  message; idle-only mode for the Voice Agent API).
- Graceful close with `CloseStream` drain: final results keep flowing to
  listeners during the bounded teardown window.
- Resilient HTTP engine with automatic retries (429/5xx/transient transport),
  `Retry-After` support, payload-scaled timeouts (base + ~2 s per MB for
  audio uploads), and per-request `HttpCancelToken`s.
- Typed exception hierarchy mapping every HTTP status and failure mode
  (`DeepgramAuthException`, `DeepgramBadRequestException`,
  `DeepgramRateLimitException`, `DeepgramQuotaException`, and friends), with
  `request_id` / `err_code` propagation.
- Pluggable logging via `DeepgramLogger` — the SDK never prints.
- Regional endpoints (`DeepgramConfig.region`, EU/AU/India data residency).
- Authentication with API keys, JWTs, or a token provider, plus temporary
  token grants (`POST /v1/auth/grant`) and automatic switching to short-lived
  Bearer tokens; web WebSocket auth via `Sec-WebSocket-Protocol` subprotocols
  through conditional imports.

#### Speech-to-Text

- Pre-recorded REST transcription (`POST /v1/listen`) from URLs or raw bytes
  with the full documented option surface: smart format, diarization,
  entities, sentiment, topics (incl. custom topics and modes), intents
  (incl. custom intents and modes), v1/v2 summarization, redaction policies,
  keyword boosting and Nova-3 keyterms, search/replace, utterances,
  paragraphs, language detection, callbacks, and more — all as typed,
  immutable options.
- Live streaming transcription (`WSS /v1/listen`) with interim results,
  endpointing, VAD `SpeechStarted` events, `UtteranceEnd` events, `Finalize`,
  mid-stream `Configure` (keyterms and formatting features), and a defensive
  message pump that never throws on malformed frames.
- Disconnect gap recovery for live sessions: audio sent while offline is
  buffered (bounded), small gaps are flushed into the reconnected socket, and
  large gaps are recovered in parallel through the pre-recorded HTTPS API,
  anchored at the disconnect instant and surfaced on a dedicated
  `recoveredResults` stream (`LiveGapRecoveryOptions`).
- Turn-based Flux STT (`WSS /v2/listen`) with end-of-turn, eager end-of-turn
  thresholds and timeout, `ForceEndTurn`, mid-stream `Configure`, language
  hints, and full `TurnInfo` event modeling.

#### Text-to-Speech

- Aura and Aura-2 voices over REST (`POST /v1/speak`) with complete audio
  options, plus streamed byte responses for progressive playback.
- Flux TTS batch synthesis (`POST /v2/speak`) with expressivity control.
- Continuous streaming synthesis (`WSS /v1/speak`): `sendText` / `flush` /
  `clear` with sequence acknowledgments, metadata, and warning streams.
- Turn-based Flux TTS (`WSS /v2/speak`): `speak` / `flush` /
  `interrupt(playbackOffsetMs)` barge-in with spoken/unspoken text splitting,
  mid-session `Configure` speed changes, per-turn and per-session billing
  metadata, and inline pronunciation control support.
- Compile-time voice catalogs: all 12 Aura, 90 Aura-2, and 36 Flux voice IDs
  with family/language lookups and validation helpers.

#### Voice Agent API

- Full `Settings` handshake (connect → `Welcome` → `Settings` →
  `SettingsApplied`) with per-stage timeouts and automatic Settings re-sending
  after reconnects.
- All typed server events: `ConversationText`, `UserStartedSpeaking` (barge-in),
  `AgentThinking`, `AgentStartedSpeaking`, `AgentAudioDone`, `LatencyReport`
  (per-stage timings), `FunctionCallRequest`/`FunctionCallCancelled`,
  `InjectionRefused`, `History`, `Error`, `Warning`, and binary agent audio.
- Function calling with client-side execution (reply via
  `FunctionCallResponse`) and server-side HTTP endpoints, `defer_until_eot`
  support, and JSON Schema parameters.
- Conversation context injection, mid-session `UpdateListen`/`UpdateThink`/
  `UpdateSpeak`/`UpdatePrompt`, `InjectUserMessage`/`InjectAgentMessage`
  (default/queue/interrupt behaviors), `ForceEndTurn`, and custom
  think-provider passthrough.
- API-mandated 8-second idle-only KeepAlive enforced automatically.
- Think providers: OpenAI, Anthropic, Google, AWS Bedrock (STS/IAM
  credentials), Groq, and custom BYO endpoints.
- Agent configuration management over REST: reusable stored agent
  configurations, template variables, and the think-model catalog.

#### Text Intelligence

- `POST /v1/read` text analysis for sentiment, topics, summaries, and intents,
  with custom topics/intents and modes, language hints, tags, and callbacks;
  envelope-tolerant parsing of both legacy segment-based and current
  list-based response shapes, plus average-sentiment extraction and
  `analyzeUrl` for hosted text files.
