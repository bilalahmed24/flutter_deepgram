# Architecture

This document records the architectural decision behind `flutter_deepgram`, the
shape of its public API, and the reasoning that future maintainers need before
changing it.

## Decision: pure Dart package (no platform channels)

**Chosen structure:** a single, pure Dart package with no Flutter SDK
dependency, no platform channels, and no native code.

**Why:** every Deepgram API surface is plain HTTPS or WebSocket traffic:

| API | Transport |
| --- | --- |
| Pre-recorded STT (`POST /v1/listen`) | HTTPS |
| Text Intelligence (`POST /v1/read`) | HTTPS |
| TTS batch (`POST /v1/speak`, `/v2/speak`) | HTTPS |
| Auth grant (`POST /v1/auth/grant`) | HTTPS |
| Live STT (`wss:///v1/listen`), Flux STT (`/v2/listen`) | WebSocket |
| TTS streaming (`/v1/speak`, `/v2/speak`) | WebSocket |
| Voice Agent (`wss://agent.deepgram.com/v1/agent/converse`) | WebSocket |

`dart:io` provides production-grade `WebSocket` and `HttpClient` on Android,
iOS, macOS, Windows, and Linux; `package:web_socket_channel` (which is
`package:web`-based since 3.x, hence Wasm-compatible) provides the browser
implementation. The only platform difference is that browsers cannot set
custom headers on a WebSocket upgrade, which Deepgram documents and solves
with the `Sec-WebSocket-Protocol` fallback (`token, <key>` / `bearer, <jwt>`)
— implemented once in `ws_factory_web.dart`.

Consequences:

- **Android and iOS (the targets for this extraction) need no native code.**
  There is nothing to bridge: the SDK does not touch the microphone, speaker,
  files, or permissions. Audio comes *in* as `Stream<List<int>>`/`Uint8List`
  from the app (e.g. `record` or `flutter_sound`), and synthesized speech
  comes *out* as byte streams for the app's player of choice.
- One codebase for six Flutter platforms plus pure Dart VM/CLI usage.
- `plugin_platform_interface`, Pigeon, and federated packaging solve problems
  this package does not have (typed platform-channel protocols and
  third-party native implementations). Adopting them would add three
  packages, generated code, and an indirection layer for zero behavior gain —
  the "where applicable" clause in the extraction spec does not apply.
- Testability comes from **injectable transports instead of a platform
  interface**: `ResilientWebSocket` accepts any `WsFactory`, `ConnectivityProbe`
  is injectable, `BackoffPolicy` accepts a seeded `Random`, and `DeepgramLogger`
  is pluggable. Every WebSocket session in the SDK is therefore unit-testable
  with a fake socket — no emulators required for the transport logic.

## WebAssembly readiness

The conditional export in `ws_factory.dart` selects the web factory with
`dart.library.js_interop` (not `dart.library.html`), and the web factory only
imports `package:web`-based code (`web_socket_channel/html.dart` is
`package:web` since 3.0). The package therefore compiles for the Wasm
platform. The minimum SDK is `3.3.0` because that is where `dart:js_interop`
(and `web_socket_channel` 3.x) landed.

## Layering

```
lib/flutter_deepgram.dart                    <- single public entry point (barrel)
lib/src/
  core/
    deepgram_config.dart             <- endpoints, regions, tuning knobs
    deepgram_auth.dart               <- API key | JWT | temp-token provider
    deepgram_exception.dart          <- typed error hierarchy (no leaks)
    deepgram_logger.dart             <- opt-in logging (never logs secrets)
    deepgram_client.dart             <- facade composing all feature clients
    http/http_engine.dart            <- retries, backoff, payload-scaled
                                         timeouts, cancellation
    ws/
      ws_factory.dart                <- conditional export (io | web | stub)
      resilient_websocket.dart       <- auto-reconnect state machine
      ws_failure_classifier.dart     <- deepgramDefinitive | ambiguous | internetSuspect
      connectivity_probe.dart        <- corroboration evidence
      backoff_policy.dart            <- exponential backoff + jitter
  listen/                            <- STT: prerecorded, live, flux + models
  speak/                             <- TTS: REST, WS v1, WS v2 (Flux) + voices
  agent/                             <- Voice Agent: settings, messages, client,
                                         configurations (REST)
  intelligence/                      <- Text Intelligence (read API)
```

Rules:

- `lib/flutter_deepgram.dart` is the only file consumers import. It exports the
  complete public surface; nothing under `lib/src/` is public API.
- Feature clients (`listen`, `speak`, `agent`, `intelligence`)
  never open sockets or HTTP connections directly — they go through
  `ResilientWebSocket` and `HttpEngine`, so resilience policy lives in one
  place.
- `DeepgramClient` is a plain composition root (constructor injection of
  `DeepgramConfig`), not a singleton and not a global. `create*` methods are
  factories for session-scoped streaming clients.

## Resilience model (ported from the in-app service)

The reconnect engine is a direct port of the production in-app
`DeepGramService`, generalized:

1. **Connect-failure classification** (`WsFailureClassifier`): a refused
   upgrade (HTTP answer) is *deepgramDefinitive*; TLS/refused/reset is
   *ambiguous*; unreachable/timeout/DNS is *internetSuspect*.
2. **Corroboration**: ambiguous/suspect failures are probed with a fresh
   connectivity check at failure time. Two consecutive corroborated failures
   (definitive + healthy internet) end the episode as "Deepgram down";
   otherwise the SDK keeps retrying — losing RAM is cheap, losing transcripts
   is not.
3. **Generation tokens**: every reconnect chain captures a monotonically
   increasing generation; a superseded chain (new `connect()`, user `close()`)
   can never resurrect or clobber the newer session.
4. **KeepAlive**: application-level keepalives on a timer (5 s default,
   8 s idle-only for the Voice Agent per Deepgram's guidance).
5. **Backoff**: exponential with jitter, clamped to
   `[minReconnectDelay, maxReconnectDelay]` (defaults 1 s–30 s; the in-app
   service used a linear 3 s×n clamp 3–30 s — configurable via
   `BackoffPolicy`).
6. **Gap recovery** (live STT): while disconnected the app keeps feeding
   audio; on reconnect, small gaps are flushed straight into the new socket,
   large gaps are recovered in parallel through the pre-recorded HTTPS API,
   anchored at `connectionLostAt` so recovered transcripts land at their true
   position.
7. **Cancellation + payload-scaled timeouts**: every HTTPS call takes an
   `HttpCancelToken`; timeouts scale with payload size (60 s + 2 s/MB).

## Error model

All failures surface as `DeepgramException` subtypes
(`DeepgramAuthException`, `DeepgramRateLimitException` with `retryAfter`,
`DeepgramBadRequestException`, `DeepgramNotFoundException`,
`DeepgramServerException`, `DeepgramNetworkException`,
`DeepgramTimeoutException`, `DeepgramWebSocketException` with
`closeCode`/`closeReason`, `DeepgramQuotaException`). Raw `PlatformException`,
`SocketException`, or `http` exceptions never escape the package. WebSocket
*protocol* errors (Deepgram `Error` messages) are delivered as typed events on
per-session `errors` streams so streaming consumers can react without
catching.

## API design rules

- Streams for continuous events (results, audio bytes, connection states);
  `Future`s for one-shot calls (prerecorded transcription, agent
  configuration CRUD).
- Every streaming session is explicitly closable (`close()`/`dispose()`) and
  leak-free: timers cancelled, subscriptions cancelled, controllers closed.
- Options are immutable value classes with `toJson()` wire serialization
  colocated with the client that sends them.
- JSON parsing is defensive: malformed frames become typed warnings/events,
  never crashes.
- The package never prints; all logging flows through the opt-in
  `DeepgramLogger`, and secrets (API keys, JWTs) are never logged.

## What is intentionally NOT in this package

- Microphone/speaker access, permissions, or audio-file decoding — these are
  separate concerns with established plugins; the SDK stays transport-only.
- State management, DI, or UI — it must compose with any app architecture.
- Any app-specific services from the original codebase (config storage,
  conversation logging, analytics) were dropped during extraction.
