# flutter_deepgram

A complete, production-grade Deepgram SDK for Dart and Flutter — speech-to-text, text-to-speech, voice agents and text intelligence, all on resilient, auto-reconnecting WebSocket sessions.

[![pub version](https://img.shields.io/pub/v/flutter_deepgram.svg)](https://pub.dev/packages/flutter_deepgram)
[![CI](https://github.com/bilalahmed24/flutter_deepgram/actions/workflows/ci.yml/badge.svg)](https://github.com/bilalahmed24/flutter_deepgram/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Web%20%7C%20macOS%20%7C%20Windows%20%7C%20Linux-lightgrey.svg)](#supported-platforms)
[![Coverage](https://img.shields.io/badge/coverage-98%25-brightgreen)](#testing)
![SDK: Dart 3.3+](https://img.shields.io/badge/SDK-Dart%203.3%2B-blue)

The package is 100% pure Dart (no platform channels, no native code). Every Deepgram API is plain HTTPS or a WebSocket, so the same source runs on **Android, iOS, Web, macOS, Windows, and Linux** without any bridging.

> **This is a community SDK and is not affiliated with, endorsed by, or sponsored by Deepgram.** Deepgram is a trademark of Deepgram, Inc. For the official HTTP/WS APIs see [developers.deepgram.com](https://developers.deepgram.com).

## Supported platforms

| Platform | Minimum | Notes |
|---|---|---|
| Android | API 21+ (any Flutter-supported version) | No manifest permissions required by the SDK — it never touches the microphone or speakers |
| iOS | 12+ (any Flutter-supported version) | No Info.plist keys required by the SDK |
| Web | Any browser with WebSocket | Auth uses Deepgram's `Sec-WebSocket-Protocol` fallback (browsers cannot set WS headers); Wasm-ready |
| macOS / Windows / Linux | Any Flutter desktop target | Uses `dart:io` WebSockets |
| Pure Dart (server/CLI) | Dart 3.3+ | No Flutter dependency at all |

Because the SDK is transport-only (you feed it audio, it returns transcripts and speech bytes), microphone/speaker access and their permissions stay in your app — pair it with any recorder/player plugin you like.

## Features

| Deepgram API surface | SDK entry point |
|---|---|
| **Pre-recorded STT** (`POST /v1/listen`) — full option set + audio intelligence | `deepgram.prerecorded` |
| **Live STT** (`WSS /v1/listen`) — interim results, endpointing, VAD/utterance events, mid-stream `Configure`, **disconnect gap recovery** | `deepgram.createLiveClient()` |
| **Flux STT** (`WSS /v2/listen`) — turn-based transcription with end-of-turn thresholds, `ForceEndTurn`, `Configure` | `deepgram.createFluxClient()` |
| **TTS REST** (`POST /v1/speak`, `POST /v2/speak`) — Aura & Aura-2 voices, Flux batch, streamed downloads | `deepgram.tts` |
| **TTS streaming WS** (`WSS /v1/speak`) — continuous synthesis: `sendText` / `flush` / `clear` | `deepgram.createTtsStreamClient()` |
| **Flux TTS WS** (`WSS /v2/speak`) — turn-based synthesis with **barge-in interrupts** (`interrupt(playbackOffsetMs)`) and mid-session speed | `deepgram.createFluxTtsClient()` |
| **Voice Agent API** (`WSS /v1/agent/converse`) — listen + think (any major LLM) + speak on one socket, **function calling**, conversation context, mid-session updates, latency reports | `deepgram.createVoiceAgent()` |
| **Voice Agent configuration management** — reusable agent configs, template variables, think-model catalog | `deepgram.agentConfigurations` |
| **Text Intelligence** (`POST /v1/read`) — sentiment, topics, summaries, intents | `deepgram.intelligence` |
| **Auth** — API key, JWT, token provider, temporary token grants (`POST /v1/auth/grant`) | `DeepgramClient` / `deepgram.auth` |
| **Regional endpoints** — EU, Australia, India (data residency) | `DeepgramConfig.region(...)` |
| **Resilience engine** — failure classification, generation tokens, backoff + jitter, keepalives, graceful drain | built into every streaming session |

Every streaming session runs on a self-healing WebSocket with generation-token reconnection, failure classification, exponential backoff with jitter, and keepalive heartbeats (see [Resilience & gap recovery](#resilience--gap-recovery)).

## Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_deepgram: ^1.0.0
```

Then import it:

```dart
import 'package:flutter_deepgram/flutter_deepgram.dart';
```

> Requires **Dart 3.3+** (Flutter 3.19+). No native dependencies — works in every Flutter app and in pure Dart servers. Because the SDK only speaks HTTPS/WebSocket, apps need **no extra permissions** (microphone access belongs to your recorder plugin of choice).

## Quick start

```dart
import 'package:flutter_deepgram/flutter_deepgram.dart';

Future<void> main() async {
  final deepgram = DeepgramClient(apiKey: 'YOUR_DEEPGRAM_API_KEY');

  final result = await deepgram.prerecorded.transcribeFromUrl(
    'https://example.com/podcast.mp3',
    options: const PrerecordedOptions(
      model: DeepgramSttModels.nova3,
      smartFormat: true,
      diarize: true,
    ),
  );

  print(result.channels.first.alternatives.first.transcript);

  deepgram.close();
}
```

Get a free API key at [console.deepgram.com](https://console.deepgram.com).

## Usage

### Pre-recorded transcription

Transcribe audio that has already been recorded — either a publicly reachable URL or raw bytes. `PrerecordedOptions` covers **every** documented `POST /v1/listen` query parameter; `null` fields are simply not sent.

```dart
final deepgram = DeepgramClient(apiKey: 'YOUR_DEEPGRAM_API_KEY');

// 1) Deepgram fetches the media itself.
final byUrl = await deepgram.prerecorded.transcribeFromUrl(
  'https://example.com/meeting.mp3',
  options: const PrerecordedOptions(
    model: DeepgramSttModels.nova3,
    smartFormat: true,
    diarize: true,
    detectEntities: true,
    sentiment: true,
    topics: true,
    intents: true,
    summarize: SummarizeOptions(
      mode: SummarizeMode.paragraphs,
      audioType: SummarizeAudioType.meeting,
    ),
    customTopic: ['product feedback', 'pricing'],
    customTopicMode: CustomTopicMode.extended,
    customIntent: ['cancel subscription'],
    redact: [DeepgramRedactions.pci, DeepgramRedactions.ssn],
    keywords: ['Deepgram:10', 'SDK'],
    search: ['refund'],
    replace: ['um:'],
    keyterm: ['Kubernetes'],   // keyterm prompting (Nova-3)
    utterances: true,
    paragraphs: true,
  ),
);

final alt = byUrl.channels.first.alternatives.first;
print(alt.transcript);
print(byUrl.summary);                 // results-level summary, when requested
print(alt.sentiments?.first.sentiment);
print(alt.topics?.first.topic);

// 2) Upload bytes directly (WAV, MP3, MP4, FLAC, ... or raw PCM).
final bytes = await File('call.wav').readAsBytes();
final byBytes = await deepgram.prerecorded.transcribeBytes(
  bytes,
  contentType: 'audio/wav',           // or 'audio/raw;rate=16000' for raw PCM
  options: const PrerecordedOptions(smartFormat: true),
);

// Raw PCM: pass the encoding as options instead.
final pcm = await File('chunk.pcm').readAsBytes();
final raw = await deepgram.prerecorded.transcribeBytes(
  pcm,
  contentType: 'audio/raw;rate=16000',
  options: const PrerecordedOptions(
    model: DeepgramSttModels.nova2Phonecall,
    encoding: 'linear16',
    sampleRate: 16000,
  ),
);
```

Highlights:

- `smartFormat: true` implies punctuation, so `punctuate` is omitted automatically.
- List parameters (`keywords`, `search`, `replace`, `customTopic`, `tag`, ...) are sent as repeated query keys.
- Uploads use payload-scaled timeouts (base 60 s + ~2 s per MB), so long recordings never die on a fixed default.
- Every request accepts an optional `HttpCancelToken`:

```dart
final token = HttpCancelToken();
final future = deepgram.prerecorded.transcribeBytes(bytes, cancelToken: token);
token.cancel('user navigated away');
```

- Results are fully typed: `PrerecordedTranscriptionResult` → `channels` → `alternatives` → `words`, `paragraphs`, `summaries`, `sentiments`, `topics`, `intents`, `entities`, `translations`; plus results-level `utterances`, `summary`, and `requestId`.

### Live streaming transcription

Stream audio to `wss://api.deepgram.com/v1/listen` and receive interim and final results as they are produced. Raw (uncontainerized) audio requires `encoding` + `sampleRate`; containerized audio (WAV, Ogg, ...) must omit them.

```dart
final deepgram = DeepgramClient(apiKey: 'YOUR_DEEPGRAM_API_KEY');

final live = deepgram.createLiveClient(
  options: const LiveTranscriptionOptions(
    model: 'nova-3',
    language: 'en-US',
    encoding: LiveEncoding.linear16,
    sampleRate: 16000,
    channels: 1,
    interimResults: true,
    smartFormat: true,
    endpointingMs: 300,        // silence window that finalizes an utterance
    vadEvents: true,           // emits SpeechStarted events
    utteranceEndMs: 1000,      // emits UtteranceEnd (requires vadEvents)
  ),
);

live.results.listen((result) {
  if (result.isFinal) {
    print('FINAL: ${result.transcript}');
  } else {
    print('interim: ${result.transcript}');
  }
});

live.utteranceEnds.listen((e) => print('utterance ended at ${e.lastWordEnd}s'));
live.speechStarted.listen((_) => print('speech started'));
live.errors.listen((e) => print('error ${e.variant}: ${e.description}'));
live.connectionStates.listen(print); // idle/connecting/open/reconnecting/...

await live.start();

// Push PCM chunks from your microphone / file stream:
live.sendAudio(chunk);

// Flush pending results without closing the stream:
await live.finish();

// Update keyterms mid-stream (Nova-3); an empty list clears them:
await live.configure(keyterms: ['Deepgram', 'Flutter']);

// Graceful close: sends CloseStream, drains final results (up to 5 s).
await live.close();
```

Notes:

- `results` carries both interim (`isFinal == false`) and final results; `speechFinal` marks endpointing boundaries and `fromFinalize` marks results flushed by `finish()`.
- `LiveTranscriptionOptions.redact` accepts `true`, a policy string (`'pci'`, `'numbers'`, `'ssn'`, ...), or a list of policies.
- `keywords` is not supported by Nova-3 — use `keyterm` (plain terms) instead.
- Non-fatal server errors arrive on `errors` (`LiveErrorMessage.variant`), never as exceptions.

### Resilience & gap recovery

Every streaming client is backed by `ResilientWebSocket`, a port of the reliability engine of a production Flutter Deepgram deployment. Nothing here requires configuration — it is the default behavior — but every knob is exposed.

**Failure classification.** When a connection attempt fails, the error is classified:

| Classification | Meaning | Evidence |
|---|---|---|
| `WsFailureClassification.deepgramDefinitive` | Deepgram answered and refused the upgrade | WebSocket upgrade refusal with an HTTP status — the round trip succeeded, so the network path is exonerated |
| `WsFailureClassification.ambiguous` | A peer answered, but a middlebox may be involved | TLS / connection-refused / reset errors |
| `WsFailureClassification.internetSuspect` | The network path looks broken | Unreachable, DNS failure, timeout |

Ambiguous and suspect failures are **corroborated with a fresh connectivity probe** (`ConnectivityProbe`, configurable via `DeepgramConfig.probeUrl`) before the SDK concludes anything. The only signal that stops reconnecting by default is a *corroborated definitive* failure — e.g. bad credentials — repeated `corroboratedFailureThreshold` (default 2) times. Everything else is retried indefinitely: on a flaky mobile network, losing RAM is cheap, losing transcripts is not.

**Generation tokens.** Every reconnect chain carries a monotonically increasing generation number. A superseded chain (the user called `connect()` again, or closed the session) can never resurrect a dead connection or clobber a newer one — zombie sockets are detected and closed.

**Backoff with jitter.** Reconnect delays grow exponentially from `minReconnectDelay` (default 1 s), capped at `maxReconnectDelay` (default 30 s), with ±25 % random jitter so fleets of clients never reconnect in lockstep.

**Keepalive heartbeats.** A JSON control message (`{"type":"KeepAlive"}` by default) is sent every `keepAliveInterval` (5 s for media APIs) so Deepgram never closes a silent session. The Voice Agent client always enforces its API-mandated 8 s idle-only heartbeat.

**Graceful close with drain.** `close()` sends a close control message (e.g. `CloseStream`), then waits up to 5 s for the server to flush pending results — frames keep flowing to your listeners during the drain. `forceClose()` abandons the session immediately.

**Disconnect buffering & gap recovery** (live STT only). While the socket is down, `sendAudio` keeps buffering audio (up to `LiveGapRecoveryOptions.maxBufferBytes`, 5 MB by default; newer audio is dropped with a logged warning once the cap is hit). The moment the connection returns, the gap is harvested:

- **Small gaps** (≤ `maxLiveFlushBytes`, 320 KB ≈ 10 s of 16 kHz 16-bit mono) are flushed straight into the reconnected socket, before live audio continues.
- **Large gaps** are recovered **in parallel** through the pre-recorded HTTPS API (`POST /v1/listen`), with streaming-only parameters stripped from the query. Recovered results are emitted on `recoveredResults` with `recovered: true` and `recoveredAtUtc` **anchored at the instant the connection was lost**, so the transcript keeps its true position in your timeline. Concurrent episodes are serialized so recoveries never interleave.

```dart
// Tune gap recovery (construct the client directly to pass gapRecovery):
final live = DeepgramLiveClient(
  config: deepgram.config,
  auth: deepgram.auth,
  http: deepgram.http,
  options: const LiveTranscriptionOptions(
    encoding: LiveEncoding.linear16,
    sampleRate: 16000,
  ),
  gapRecovery: const LiveGapRecoveryOptions(
    enabled: true,
    maxLiveFlushBytes: 320000,   // gaps up to this size go straight to the socket
    maxBufferBytes: 5242880,     // 5 MB of disconnect buffering
  ),
);

live.recoveredResults.listen((r) {
  print('recovered (lost at ${r.recoveredAtUtc}): ${r.transcript}');
});
```

**Custom reconnection policy.** Pass `shouldReconnect` to decide, per failure, whether to keep going. The context includes the close code, the failure classification, and the probe result:

```dart
final live = deepgram.createLiveClient(
  options: const LiveTranscriptionOptions(smartFormat: true),
  wsOptions: ResilientWebSocketOptions(
    maxReconnectAttempts: 10,               // 0 = unlimited (default)
    minReconnectDelay: const Duration(seconds: 1),
    maxReconnectDelay: const Duration(seconds: 30),
    onReconnecting: (ctx) => print(
      'reconnect #${ctx.attempt} in ${ctx.nextDelay} '
      '(${ctx.classification?.name}, internetUp: ${ctx.internetUp})',
    ),
    shouldReconnect: (ctx) => ctx.closeCode != 4008, // e.g. never retry quota closes
  ),
);
```

**What happens when the network drops — a walkthrough:**

1. The socket dies mid-session. `connectionStates` emits `reconnecting`; the live client stamps the disconnect anchor (this timestamp is what large-gap recovery will report against).
2. `sendAudio` calls keep succeeding from your code's point of view — audio is buffered (gap recovery) instead of sent.
3. The SDK classifies the failure and probes the internet. If the probe is green and Deepgram answered with a refusal, the definitive counter increments; otherwise it resets.
4. After a jittered backoff delay, the next connect attempt runs under a fresh generation token. Repeat until success or the policy gives up.
5. On success, `onReconnected` fires, the buffered gap is dispatched (small → socket flush, large → HTTPS recovery anchored at step 1's timestamp), and live results resume. Voice Agent sessions additionally re-send their `Settings` automatically.

If the reconnect chain gives up (terminal `failed` state), `start()` throws `DeepgramWebSocketException` and the same client can be restarted with another `start()` call.

### Flux STT (turn-based transcription)

`/v2/listen` delivers conversational transcription with contextual turn detection: the server reports `StartOfTurn`, `Update`, `EagerEndOfTurn`, `TurnResumed`, and `EndOfTurn` events, and you can force a turn to end or reconfigure thresholds mid-stream.

```dart
final flux = deepgram.createFluxClient(
  options: const FluxSttOptions(
    model: 'flux-general-en',      // or 'flux-general-multi'
    encoding: LiveEncoding.linear16,
    sampleRate: 16000,
    eotThreshold: 0.6,             // end-of-turn confidence (0.5–1.0; default 0.7)
    eagerEotThreshold: 0.45,       // enables EagerEndOfTurn / TurnResumed
    eotTimeoutMs: 5000,            // hard per-turn speech timeout
    keyterms: ['Deepgram'],
    // languageHints: ['en', 'es'],  // flux-general-multi only
  ),
);

flux.turnInfo.listen((turn) {
  switch (turn.event) {
    case 'StartOfTurn':
      print('turn ${turn.turnIndex} started');
    case 'Update':
      print('  ... ${turn.transcript} '
          '(eot confidence: ${turn.endOfTurnConfidence})');
    case 'EagerEndOfTurn':
      print('  (agent can start preparing a reply)');
    case 'EndOfTurn':
      print('turn ${turn.turnIndex} done (${turn.trigger}): '
          '${turn.transcript}');
  }
});

flux.configureSuccess.listen(print);
flux.fatalErrors.listen((e) => print('fatal: ${e.description}'));

await flux.start();
flux.sendAudio(chunk);

// End the current turn immediately (EndOfTurn arrives with trigger: manual):
flux.forceEndTurn();

// Adjust thresholds / keyterms mid-session:
flux.configure(const FluxConfigure(eotThreshold: 0.8, keyterms: ['Flutter']));

await flux.close();
```

Note: Flux performs no disconnect audio buffering (that is a `/v1/listen` feature). Fatal `Error` messages close the session server-side; an auto-reconnect starts a **new** session with a new `request_id`, and no turn state carries over.

### Text-to-speech

#### REST — one-shot synthesis

```dart
final deepgram = DeepgramClient(apiKey: 'YOUR_DEEPGRAM_API_KEY');

// Complete audio in memory:
final mp3 = await deepgram.tts.speak(
  'Hello, and welcome to Deepgram!',
  options: const SpeakOptions(
    model: DeepgramVoices.aura2ThaliaEn,
    encoding: TtsEncoding.mp3,
    container: TtsContainer.none,
  ),
);
await File('greeting.mp3').writeAsBytes(mp3);

// Or stream the bytes as they download (progressive playback):
final audioStream = await deepgram.tts.speakStream(
  'Hello, and welcome to Deepgram!',
  options: const SpeakOptions(model: DeepgramVoices.aura2ThaliaEn),
);
await for (final chunk in audioStream) {
  player.push(chunk);
}

// Flux batch synthesis (POST /v2/speak), with expressivity -2..2:
final fluxAudio = await deepgram.tts.speakFlux(
  'This is Flux TTS.',
  options: const FluxTtsOptions(
    model: DeepgramVoices.fluxAlexisEn,
    expressivity: 1,
  ),
);
```

Text is capped at `TtsClient.maxTextLength` (2000 characters) and rejected up front with `DeepgramBadRequestException` — split longer text into multiple requests.

#### Streaming WebSocket — continuous synthesis (`/v1/speak`)

```dart
final tts = deepgram.createTtsStreamClient(
  options: const SpeakOptions(
    model: DeepgramVoices.aura2ThaliaEn,
    encoding: TtsEncoding.linear16,
    sampleRate: 24000,
  ),
);

tts.audio.listen((chunk) => player.push(chunk)); // binary frames, in order
tts.flushed.listen((sequenceId) => print('flush $sequenceId complete'));
tts.warnings.listen((w) => print('warning ${w.code}: ${w.description}'));

await tts.start();
tts.sendText('Hello, ');
tts.sendText('and welcome to Deepgram!');
tts.flush();   // ask for audio covering everything sent so far

// Later: discard unflushed text server-side
tts.clear();

await tts.close(); // sends Close (flushing pending audio), drains 5 s
```

After a reconnect the server starts a brand-new session: text sent but not yet flushed when the connection dropped is lost — re-send it after observing the next open state on `connectionStates`.

#### Flux TTS — turn-based synthesis with barge-in (`/v2/speak`)

Built for voice-agent pipelines: stream LLM tokens into a turn, end the turn with `flush`, and cancel it when the user barges in.

```dart
final fluxTts = deepgram.createFluxTtsClient(
  options: const FluxTtsOptions(model: DeepgramVoices.fluxAlexisEn),
);

fluxTts.audio.listen((chunk) => player.push(chunk));
fluxTts.speechStarted.listen((e) => print('turn ${e.speechId} started'));
fluxTts.speechMetadata.listen((m) => print('turn billed: ${m.audioDurationMs} ms'));
fluxTts.speechInterrupted.listen((e) {
  print('user heard: ${e.textSpoken}');
  print('never heard: ${e.textRemaining}');
});
fluxTts.sessionMetadata.listen((m) => print(
    'session totals: ${m.totalBillableCharacterCount} billable chars'));
fluxTts.configureFailure.listen((f) => print('speed rejected: ${f.code}'));

await fluxTts.start();

// Stream an LLM reply token by token:
for (final token in llmTokens) {
  fluxTts.speak(token);
}
fluxTts.flush();

// The user barged in after 3.2 s of session audio:
fluxTts.interrupt(playbackOffsetMs: 3200);

// Change the speaking rate mid-session (0.5–1.5 in 0.05 steps):
fluxTts.configureSpeed(1.2);

await fluxTts.close(); // drains and delivers the final SessionMetadata
```

`speak` also accepts inline pronunciation controls (Early Access), e.g. `təˈmɑːtoʊ`-style IPA objects embedded in the text; they cannot be combined with a speed other than 1.0 (server rejects with `DATA-0002`).

#### Voice catalog

`DeepgramVoices` is a compile-time catalog of all **138** voice IDs — 12 Aura + 90 Aura-2 (English, Spanish, German, Dutch, French, Italian, Japanese) served by `/v1/speak`, and 36 Flux voices (`flux-{voice}-{lang}`) served by `/v2/speak`:

```dart
DeepgramVoices.auraAsteriaEn;     // 'aura-asteria-en' — the server default
DeepgramVoices.aura2ThaliaEn;     // 'aura-2-thalia-en'
DeepgramVoices.fluxAlexisEn;      // 'flux-alexis-en'

DeepgramVoices.aura;              // List<String> of all Aura voices
DeepgramVoices.aura2;
DeepgramVoices.flux;
DeepgramVoices.all;               // every known voice ID

DeepgramVoices.isAura2Voice(id);  // validate user-supplied IDs
DeepgramVoices.languageOf(id);    // 'en', 'es', 'de', ...
```

### Voice Agent

One WebSocket runs listening (Deepgram STT), thinking (any major LLM), and speaking (Deepgram TTS). `start()` performs the required handshake — connect → `Welcome` → send `Settings` → `SettingsApplied` — and the client keeps the session alive with the API-mandated 8-second idle-only keepalive automatically.

```dart
final deepgram = DeepgramClient(apiKey: 'YOUR_DEEPGRAM_API_KEY');
final agent = deepgram.createVoiceAgent();

// ---- typed event streams -------------------------------------------------
agent.conversationText.listen((e) => print('${e.role}: ${e.content}'));
agent.audio.listen((chunk) => player.push(chunk));     // agent speech (binary)
agent.userStartedSpeaking.listen((_) => player.stop()); // barge-in: mute now
agent.agentAudioDone.listen((_) => player.onTrackEnd());
agent.latencyReports.listen((r) => print(
    'total ${r.totalLatency}s (stt ${r.sttLatency}, ttt ${r.tttTextLatency}, '
    'tts ${r.ttsLatency})'));
agent.errors.listen((e) => print('agent error: ${e.description}'));

// ---- function calling (client-side) ---------------------------------------
agent.functionCallRequests.listen((request) async {
  for (final fn in request.functions) {
    final result = await runLocally(fn.name, fn.arguments); // your code
    agent.sendFunctionCallResponse(
      id: fn.id,
      name: fn.name,
      content: result,
    );
  }
});
agent.functionCallCancelled.listen((c) {
  for (final fn in c.functions) {
    pending.remove(fn.id); // drop it; send no response for these ids
  }
});

// ---- settings --------------------------------------------------------------
const settings = VoiceAgentSettings(
  audio: AgentAudioSettings(
    input: AgentAudioInput(
      encoding: AgentAudioEncoding.linear16,
      sampleRate: 16000,
    ),
    output: AgentAudioOutput(
      encoding: AgentAudioOutputEncoding.linear16,
      sampleRate: 24000,
    ),
  ),
  agent: AgentAgentSettings(
    greeting: 'Hello! How can I help you today?',
    context: AgentContext(messages: [
      AgentHistoryMessage.text(
        role: 'user',
        content: 'I ordered a coffee machine last Tuesday.',
      ),
      AgentHistoryMessage.text(
        role: 'assistant',
        content: 'Got it — what would you like to know?',
      ),
    ]),
    listen: AgentListen(
      provider: AgentListenProvider.v1(
        model: 'nova-3',
        language: 'en-US',
        smartFormat: true,
      ),
    ),
    think: AgentThink(
      provider: AgentThinkProvider.openAi(model: 'gpt-4o-mini'),
      prompt: 'You are a friendly order-support agent. Be concise.',
      functions: [
        AgentFunctionDefinition.client(
          name: 'get_order_status',
          description: 'Fetches the current status of a customer order.',
          parameters: {
            'type': 'object',
            'properties': {
              'order_id': {'type': 'string'},
            },
            'required': ['order_id'],
          },
        ),
        AgentFunctionDefinition.server(
          name: 'issue_refund',
          description: 'Issues a refund through the payments service.',
          url: 'https://api.example.com/refunds',
          method: 'POST',
          authorization: {'Authorization': 'Bearer <server-token>'},
        ),
      ],
    ),
    speak: AgentSpeak(
      provider: AgentSpeakProvider(model: 'aura-2-thalia-en'),
    ),
  ),
);

await agent.start(settings);

// ---- conversation ----------------------------------------------------------
agent.sendAudio(pcmChunk); // stream microphone audio (binary Media frames)

// Mid-session updates:
agent.updatePrompt('You are now a technical support agent.');
agent.updateThink(AgentThink(
  provider: AgentThinkProvider.anthropic(model: 'claude-sonnet-4-20250514'),
));
agent.injectUserMessage('What is my order status?');
agent.injectAgentMessage('One moment, checking that for you.',
    behavior: 'interrupt');
agent.forceEndTurn();

await agent.close();
```

More agent capabilities:

- **Think providers**: `AgentThinkProvider.openAi / anthropic / google / awsBedrock / groq / custom` (BYO endpoint with `url`, `headers`, `authHeaders`).
- **Flux listening**: `AgentListenProvider.v2(model: 'flux-general-en', eotThreshold: 0.7, ...)` with eager end-of-turn.
- **Flux speaking**: `AgentSpeakProvider(model: 'flux-kit-en', version: 'v2', expressivity: 1)`.
- **Deferred function calls**: `deferUntilEot: true` holds the call until the user's turn is confirmed — for actions that cannot be undone.
- **Custom LLM passthrough**: `sendCustomToThinkProvider(payload)` + `customThinkProviderMessages` for providers with extra protocol steps.
- **Reconnects**: after an automatic reconnect the client re-sends your `Settings` for you, so the fresh session is configured identically.
- **Reusable stored configurations**: create agents once with
  `deepgram.agentConfigurations.create(...)` and reuse the returned
  `agentId` across sessions and teams (the API accepts a stored agent id in
  place of an inline settings object).

### Text Intelligence

Analyze plain text (or a text-file URL) for sentiment, topics, summaries, and intents over `POST /v1/read`:

```dart
final result = await deepgram.intelligence.analyze(
  'I love this product. It changed my life! The delivery was slow though.',
  options: const TextIntelligenceOptions(
    sentiment: true,
    topics: true,
    summarize: true,
    intents: true,
    customTopic: ['delivery', 'product quality'],
    customTopicMode: 'extended',
    language: 'en',
  ),
);

print(result.averageSentiment);          // e.g. 'positive'
for (final s in result.sentiments) {
  print('${s.sentiment} (${s.sentimentScore}): ${s.text}');
}
for (final t in result.topics) {
  print('${t.topic} @ ${t.confidenceScore}');
}
print(result.summaries.first.summary);

// Analyze a hosted text file instead:
final urlResult = await deepgram.intelligence.analyzeUrl(
  'https://example.com/article.txt',
  options: const TextIntelligenceOptions(topics: true),
);
```

### Voice Agent configuration management

Reusable, server-side agent configurations and template variables, plus the
think-model catalog:

```dart
// Voice Agent configurations (reusable, server-side)
final agents = await deepgram.agentConfigurations.list(projectId);
final created = await deepgram.agentConfigurations.create(
  projectId,
  settings: {
    'greeting': 'Hello!',
    'think': {
      'provider': {'type': 'open_ai', 'model': 'gpt-4o-mini'},
      'prompt': 'You are a helpful assistant.',
    },
  },
  metadata: {'env': 'staging'},
);
final thinkModels = await deepgram.agentConfigurations.listThinkModels();
```

### Authentication options

```dart
// 1) API key (Authorization: Token <key>) — the common case.
final a = DeepgramClient(apiKey: 'YOUR_DEEPGRAM_API_KEY');

// 2) Pre-issued JWT (Authorization: Bearer <jwt>).
final b = DeepgramClient.withConfig(DeepgramConfig(jwt: 'YOUR_JWT'));

// 3) Token provider — ideal for web: your backend mints short-lived JWTs,
//    the secret never ships to the client.
//    (Uses package:http — `import 'package:http/http.dart' as http;`
//    and `import 'dart:convert';`)
Future<String> fetchToken() async {
  final res = await http.get(Uri.parse('https://my-backend.example.com/deepgram/token'));
  return (jsonDecode(res.body) as Map<String, dynamic>)['token'] as String;
}
final c = DeepgramClient.withTokenProvider(tokenProvider: fetchToken);

// 4) Temporary token grants (POST /v1/auth/grant) — mint a short-lived JWT
//    from an API key (requires a Member-or-higher key).
final grant = await a.auth.grantTemporaryToken(
  ttl: const Duration(minutes: 5),
);
print(grant.accessToken);   // use as a JWT anywhere Bearer auth is accepted
print(grant.expiresIn);     // seconds

// Switch a client to auto-renewing temporary tokens (recommended for web):
await a.auth.useTemporaryTokens();
```

### Regional endpoints

Route all API traffic (REST + WebSocket, including the Voice Agent) through a data-residency region:

```dart
final deepgram = DeepgramClient.withConfig(
  DeepgramConfig.region(DeepgramRegion.eu, apiKey: 'YOUR_DEEPGRAM_API_KEY'),
);
// → https://api.eu.deepgram.com / wss://api.eu.deepgram.com

// Available regions: DeepgramRegion.global (default), .eu, .au, .india
```

### Logging

The SDK never prints. Attach listeners to route events into your logging pipeline:

```dart
final logger = DeepgramLogger();

final detach = logger.addListener((level, message, error) {
  // level is 'debug', 'info', 'warn', or 'error'
  debugPrint('[$level] $message${error == null ? '' : ' — $error'}');
});

final deepgram = DeepgramClient.withConfig(
  DeepgramConfig(apiKey: 'YOUR_DEEPGRAM_API_KEY', logger: logger),
);

// ...
detach(); // stop listening
```

You can also construct `DeepgramLogger(sink: (level, message, error) { ... })` with a single sink function.

### Error handling

Every failure surfaces as a typed `DeepgramException` subtype carrying `requestId` and `code` when Deepgram provides them, so you can `switch` on the concrete type instead of parsing strings:

```dart
try {
  final result = await deepgram.prerecorded.transcribeFromUrl(url);
} on DeepgramRateLimitException catch (e) {
  print('throttled; retry after ${e.retryAfter}');
} on DeepgramAuthException {
  print('check your API key');
} on DeepgramException catch (e) {
  print('${e.message} (request_id: ${e.requestId})');
}
```

| HTTP status | Exception | Extra fields / notes |
|---|---|---|
| `400` | `DeepgramBadRequestException` | Invalid parameters; also thrown locally for oversize TTS text |
| `401`, `403` | `DeepgramAuthException` | Missing, malformed, expired, or unauthorized credentials |
| `402` | `DeepgramQuotaException` | Account is out of credit |
| `404` | `DeepgramNotFoundException` | |
| `429` | `DeepgramRateLimitException` | `retryAfter` parsed from the `Retry-After` header; retried automatically up to `DeepgramConfig.maxRetries` |
| `5xx` | `DeepgramServerException` | Retried automatically with backoff before throwing |
| transport | `DeepgramNetworkException` | DNS/TCP/TLS failures; `cause` holds the underlying error; retried |
| timeout | `DeepgramTimeoutException` | Request or handshake exceeded its deadline |
| WebSocket | `DeepgramWebSocketException` | `closeCode` / `closeReason` when the server sent them |
| misuse | `DeepgramStateException` | Operation on a closed session/client |

## Web platform notes

The SDK runs in the browser with zero changes. Three things to know:

1. **Subprotocol authentication.** Browsers do not allow custom headers on WebSocket upgrades, so the web factory authenticates with Deepgram's documented `Sec-WebSocket-Protocol` approach: it offers the subprotocols `token, <API key>` (or `bearer, <JWT>`) during the handshake. This is handled automatically by the conditional import in `ws_factory.dart` — your code is identical across platforms.
2. **CORS / proxy guidance.** Deepgram's REST endpoints do not send permissive CORS headers for browser use, and shipping an API key to the browser is unsafe anyway. The recommended deployment is a thin token-minting endpoint on your backend (which calls `grantTemporaryToken` or `POST /v1/auth/grant`) plus `DeepgramClient.withTokenProvider` — the SDK then attaches the short-lived JWT to every request. If you cannot add a backend, proxy `api.deepgram.com` and `agent.deepgram.com` through your own origin and set `baseUrl`/`agentBaseUrl` accordingly.
3. **No `dart:io`.** Every client is web-safe; there is deliberately no `transcribeFromFile` — read the file into bytes (`File(...).readAsBytes()` on VM platforms) and pass them to `transcribeBytes`.

## API surface overview

| `DeepgramClient` member | Returns | Feature |
|---|---|---|
| `prerecorded` | `PrerecordedClient` | Pre-recorded STT (`transcribeFromUrl`, `transcribeBytes`) |
| `createLiveClient(options:, wsOptions:)` | `DeepgramLiveClient` | Live STT + gap recovery |
| `createFluxClient(options:, wsOptions:)` | `FluxSttClient` | Turn-based Flux STT |
| `tts` | `TtsClient` | REST TTS (`speak`, `speakStream`, `speakFlux`, `speakFluxStream`) |
| `createTtsStreamClient(options:, wsOptions:)` | `TtsStreamClient` | Continuous WS TTS |
| `createFluxTtsClient(options:, wsOptions:)` | `FluxTtsClient` | Turn-based Flux TTS with interrupts |
| `createVoiceAgent(wsOptions:)` | `DeepgramVoiceAgent` | Voice Agent API |
| `agentConfigurations` | `AgentConfigurationsClient` | Stored agent configs, variables, think models |
| `intelligence` | `TextIntelligenceClient` | Text Intelligence (`analyze`, `analyzeUrl`) |
| `auth` | `DeepgramAuth` | Credentials, temporary token grants |
| `config` / `logger` / `http` | — | Shared configuration, logging, HTTP engine |
| `close()` | — | Release the shared HTTP engine |

Every streaming factory also accepts `ResilientWebSocketOptions` (`autoReconnect`, `maxReconnectAttempts`, backoff bounds, keepalive, `shouldReconnect`, `onReconnecting`, `onReconnected`) — see [Resilience & gap recovery](#resilience--gap-recovery).

## Testing

The SDK ships with a deterministic, network-free test suite (765 tests, **98.3% line coverage**) built on scriptable WebSocket factories and a queued HTTP client:

```bash
dart pub get --no-example   # resolve SDK deps (example/ needs the Flutter SDK)
dart test                                   # all 765 tests
dart test --coverage=coverage               # with coverage instrumentation
dart pub global run coverage:format_coverage --lcov \
  --in=coverage --out=coverage/lcov.info \
  --report-on=lib --packages=.dart_tool/package_config.json
python3 tool/coverage.py coverage/lcov.info # per-file + overall summary
```

The resilience engine itself (failure classification, generation tokens, backoff, keepalive, graceful drain) is covered end-to-end by fake-socket tests in `test/resilient_websocket_test.dart`.

## Migrating from in-app code

If you are extracting an existing in-app Deepgram service (singletons, rxdart subjects, app loggers) into this package, the mapping is:

| In-app pattern | flutter_deepgram equivalent |
|---|---|
| `DeepGramService()` singleton | `DeepgramClient(apiKey: ...)` — plain object, create per usage scope, call `close()` when done |
| `getTranscriptionStream(audioStream)` | `deepgram.createLiveClient()` + `start()`, then `sendAudio(chunk)` per chunk; results via the `results` stream |
| `onTranscriptReceived` BehaviorSubject | `live.results` broadcast stream (typed `LiveTranscriptionResult`) |
| `streamRestarted` / `streamClosed` subjects | `live.connectionStates` stream (`open` / `reconnecting` / `closed` / `failed`) |
| `closeWebsocketStream(forceStop:)` | `live.close()` (graceful, bounded drain) or `live.forceClose()` (immediate, cancels gap recoveries) |
| Manual KeepAlive timer | Built-in (5 s default; agent sessions use 8 s idle-only automatically) |
| Hand-rolled reconnect + backoff | `ResilientWebSocketOptions` (`minReconnectDelay`, `maxReconnectDelay`, `shouldReconnect`, `onReconnecting`) |
| Custom logging (`LoggerService`) | `DeepgramConfig(logger: ...)` with a `DeepgramLogger` sink, or `deepgram.logger.addListener(...)` |
| Custom config storage | Your concern — pass values into `DeepgramConfig` at construction |

Behavior carried over from that service's production hardening: connect-failure classification with connectivity corroboration, generation tokens that stop superseded reconnect chains, disconnect audio buffering with small-gap socket flush vs large-gap HTTPS recovery (anchored at the disconnect instant), per-recovery cancellation tokens, payload-scaled timeouts, and a bounded wait for in-flight recoveries at graceful close (`LiveGapRecoveryOptions.maxCloseWait`).

## Troubleshooting / FAQ

<details>
<summary><b>“The WebSocket connection failed to open” on startup</b></summary>

The SDK gives up only after repeated *corroborated* failures (a definitive Deepgram refusal **plus** a healthy internet probe — see the [failure classification table](#resilience--gap-recovery)). Check the API key first (`Token` auth shows 401 as a definitive refusal), then your network. On the web, confirm you are not hitting CORS — see [Web platform notes](#web-platform-notes).
</details>

<details>
<summary><b>Audio is transcribed after reconnect, but timestamps jump</b></summary>

That is gap recovery working: recovered transcripts are anchored at `connectionLostAt` so they land at their true position even though they arrive after some live results. Subscribe to `recoveredResults` (or check `result.recovered` / `result.recoveredAtUtc`) to route them separately.
</details>

<details>
<summary><b>I need to record the microphone</b></summary>

The SDK deliberately does not touch devices. Use `record`, `flutter_sound`, or `mic_stream`, and forward chunks to `sendAudio`. Raw PCM works with `LiveTranscriptionOptions(encoding: LiveEncoding.linear16, sampleRate: 16000)`.
</details>

<details>
<summary><b>How do I run against a proxy or local mock server?</b></summary>

Since 1.0.0, `DeepgramConfig.baseUrl` accepts `host:port` (e.g. `127.0.0.1:8080`), including IPv6 `[::1]:9000`. Pair it with `useTls: false` for plain HTTP/WS local mocks.
</details>

<details>
<summary><b>Transcripts stop after ~10 seconds of silence</b></summary>

Deepgram closes idle live sockets. Keepalives are built in, but audio must flow for long sessions — send silent frames or close and reopen the session deliberately.
</details>

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for the development setup, project layout, and pull-request checklist.

## License

This project is licensed under the [MIT License](LICENSE).
