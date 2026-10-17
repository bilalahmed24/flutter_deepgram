/// A complete, production-grade Deepgram SDK for Dart and Flutter.
///
/// ## What's included
///
/// * **Speech-to-Text** — pre-recorded (REST), live streaming (WebSocket),
///   and turn-based Flux (WebSocket) transcription, with the full option
///   surface of every API.
/// * **Text-to-Speech** — Aura, Aura-2, and Flux voices over REST and
///   WebSocket, including turn-based Flux TTS with barge-in interrupts.
/// * **Voice Agent API** — a single WebSocket that runs listening, thinking
///   (any major LLM), and speaking, with function calling and conversation
///   context.
/// * **Text Intelligence** — sentiment, topics, summarization, and intents
///   for plain text.
/// * **Resilience** — every streaming session runs on a self-healing
///   WebSocket with generation-token reconnection, failure classification,
///   exponential backoff with jitter, keepalive heartbeats, and (for live
///   transcription) disconnect gap recovery through the pre-recorded API.
///
/// ## Quick start
///
/// ```dart
/// final deepgram = DeepgramClient(apiKey: 'YOUR_DEEPGRAM_API_KEY');
///
/// final result = await deepgram.prerecorded.transcribeFromUrl(
///   'https://example.com/podcast.mp3',
///   options: const PrerecordedOptions(
///     smartFormat: true,
///     diarize: true,
///     summarize: SummarizeOptions(mode: SummarizeMode.paragraphs),
///   ),
/// );
/// print(result.channels.first.alternatives.first.transcript);
/// ```
library;

// ── Core ────────────────────────────────────────────────────────────────
export 'src/core/deepgram_client.dart';
export 'src/core/deepgram_config.dart';
export 'src/core/deepgram_exception.dart';
export 'src/core/deepgram_logger.dart';
export 'src/core/deepgram_auth.dart';
export 'src/core/http/http_engine.dart';
export 'src/core/ws/backoff_policy.dart';
export 'src/core/ws/connectivity_probe.dart';
export 'src/core/ws/ws_failure_classifier.dart';
export 'src/core/ws/resilient_websocket.dart';
export 'src/core/ws/ws_factory.dart';

// ── Speech-to-Text ──────────────────────────────────────────────────────
export 'src/listen/stt_models.dart';
export 'src/listen/prerecorded/prerecorded_options.dart';
export 'src/listen/prerecorded/prerecorded_client.dart';
export 'src/listen/live/live_options.dart';
export 'src/listen/live/live_models.dart';
export 'src/listen/live/live_client.dart';
export 'src/listen/flux/flux_stt_options.dart';
export 'src/listen/flux/flux_stt_models.dart';
export 'src/listen/flux/flux_stt_client.dart';

// ── Text-to-Speech ──────────────────────────────────────────────────────
export 'src/speak/voices.dart';
export 'src/speak/speak_options.dart';
export 'src/speak/speak_client.dart';
export 'src/speak/speak_stream_client.dart';
export 'src/speak/flux_speak_client.dart';

// ── Voice Agent ─────────────────────────────────────────────────────────
export 'src/agent/agent_settings.dart';
export 'src/agent/agent_messages.dart';
export 'src/agent/agent_client.dart';
export 'src/agent/agent_configurations.dart';

// ── Text Intelligence ───────────────────────────────────────────────────
export 'src/intelligence/text_intelligence.dart';
