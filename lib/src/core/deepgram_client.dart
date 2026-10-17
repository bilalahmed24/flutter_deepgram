/// The main entry point of the flutter_deepgram SDK.
///
/// ```dart
/// final deepgram = DeepgramClient(apiKey: 'YOUR_KEY');
///
/// // Pre-recorded transcription
/// final result = await deepgram.prerecorded.transcribeFromUrl(
///   'https://example.com/audio.mp3',
///   options: const PrerecordedOptions(smartFormat: true, detectEntities: true),
/// );
///
/// // Live streaming transcription
/// final live = deepgram.createLiveClient(
///   options: const LiveTranscriptionOptions(
///     model: DeepgramSttModels.nova3,
///     interimResults: true,
///     smartFormat: true,
///   ),
/// );
/// await live.start();
/// live.sendAudio(chunk);
/// ```
library;

import 'deepgram_auth.dart';
import 'deepgram_config.dart';
import 'deepgram_logger.dart';
import 'http/http_engine.dart';
import '../agent/agent_client.dart';
import '../agent/agent_configurations.dart';
import '../intelligence/text_intelligence.dart';
import '../listen/flux/flux_stt_client.dart';
import '../listen/flux/flux_stt_options.dart';
import '../listen/live/live_client.dart';
import '../listen/live/live_options.dart';
import '../listen/prerecorded/prerecorded_client.dart';
import '../speak/flux_speak_client.dart';
import '../speak/speak_client.dart';
import '../speak/speak_stream_client.dart';

/// Provides access to every Deepgram API surface.
class DeepgramClient {
  /// Creates a client authenticated with an API key.
  ///
  /// Any [config] provided supplies non-credential settings (region,
  /// timeouts, retry policy); its credentials are replaced by [apiKey].
  DeepgramClient({required String apiKey, DeepgramConfig? config})
    : this.withConfig(
        (config ?? const DeepgramConfig(apiKey: '')).copyWith(apiKey: apiKey),
      );

  /// Creates a client from a full [config].
  DeepgramClient.withConfig(this.config, {DeepgramTokenProvider? tokenProvider})
    : logger = config.logger ?? DeepgramLogger(),
      auth = DeepgramAuth(config, tokenProvider: tokenProvider) {
    _http = HttpEngine(config: config, auth: auth);
  }

  /// Creates a client that obtains short-lived JWTs from [tokenProvider].
  ///
  /// Ideal for browser deployments where the API key must stay on your
  /// backend: the provider typically calls your server, which uses
  /// `POST /v1/auth/grant` to mint a temporary token.
  DeepgramClient.withTokenProvider({
    required DeepgramTokenProvider tokenProvider,
    DeepgramConfig? config,
  }) : this.withConfig(
         (config ?? const DeepgramConfig(apiKey: '', jwt: '')).copyWith(
           apiKey: '',
           jwt: '',
         ),
         tokenProvider: tokenProvider,
       );

  /// The configuration this client was built from.
  final DeepgramConfig config;

  /// Shared logger.
  final DeepgramLogger logger;

  /// Credential manager (also exposes temporary-token grants).
  final DeepgramAuth auth;

  late final HttpEngine _http;
  bool _closed = false;

  // ---------------------------------------------------------------------
  // REST sub-clients (stateless — lazily created singletons)
  // ---------------------------------------------------------------------

  late final PrerecordedClient _prerecorded = PrerecordedClient(
    http: _http,
    config: config,
  );

  late final TtsClient _tts = TtsClient(http: _http, config: config);

  late final TextIntelligenceClient _intelligence = TextIntelligenceClient(
    http: _http,
    config: config,
  );

  late final AgentConfigurationsClient _agentConfigurations =
      AgentConfigurationsClient(http: _http, config: config);

  /// Pre-recorded (batch) speech-to-text over REST.
  PrerecordedClient get prerecorded => _prerecorded;

  /// Text-to-speech over REST (Aura/Aura-2 single requests and Flux batch).
  TtsClient get tts => _tts;

  /// Text intelligence (sentiment, topics, summarization, intents) over
  /// `POST /v1/read`.
  TextIntelligenceClient get intelligence => _intelligence;

  /// Voice Agent configuration management over REST (reusable agent
  /// configurations and variables, think-model catalog).
  AgentConfigurationsClient get agentConfigurations => _agentConfigurations;

  // ---------------------------------------------------------------------
  // Streaming session factories (each call returns a NEW session)
  // ---------------------------------------------------------------------

  /// Creates a live streaming transcription session
  /// (`wss://api.deepgram.com/v1/listen`).
  DeepgramLiveClient createLiveClient({
    LiveTranscriptionOptions? options,
    ResilientWebSocketOptions? wsOptions,
  }) {
    _ensureOpen();
    return DeepgramLiveClient(
      config: config,
      auth: auth,
      http: _http,
      options: options,
      wsOptions: wsOptions,
      logger: logger,
    );
  }

  /// Creates a turn-based Flux speech-to-text session
  /// (`wss://api.deepgram.com/v2/listen`).
  FluxSttClient createFluxClient({
    FluxSttOptions? options,
    ResilientWebSocketOptions? wsOptions,
  }) {
    _ensureOpen();
    return FluxSttClient(
      config: config,
      auth: auth,
      http: _http,
      options: options,
      wsOptions: wsOptions,
      logger: logger,
    );
  }

  /// Creates a continuous text-to-speech streaming session
  /// (`wss://api.deepgram.com/v1/speak`).
  TtsStreamClient createTtsStreamClient({
    SpeakOptions? options,
    ResilientWebSocketOptions? wsOptions,
  }) {
    _ensureOpen();
    return TtsStreamClient(
      config: config,
      auth: auth,
      http: _http,
      options: options,
      wsOptions: wsOptions,
      logger: logger,
    );
  }

  /// Creates a turn-based Flux text-to-speech session
  /// (`wss://api.deepgram.com/v2/speak`).
  FluxTtsClient createFluxTtsClient({
    FluxTtsOptions? options,
    ResilientWebSocketOptions? wsOptions,
  }) {
    _ensureOpen();
    return FluxTtsClient(
      config: config,
      auth: auth,
      http: _http,
      options: options,
      wsOptions: wsOptions,
      logger: logger,
    );
  }

  /// Creates a Voice Agent session
  /// (`wss://agent.deepgram.com/v1/agent/converse`).
  DeepgramVoiceAgent createVoiceAgent({ResilientWebSocketOptions? wsOptions}) {
    _ensureOpen();
    return DeepgramVoiceAgent(
      config: config,
      auth: auth,
      http: _http,
      wsOptions: wsOptions,
      logger: logger,
    );
  }

  /// The shared HTTP engine (exposed for advanced use cases).
  HttpEngine get http => _http;

  /// Closes the shared HTTP engine. Streaming sessions created from this
  /// client are unaffected; close them individually.
  void close() {
    if (_closed) return;
    _closed = true;
    _http.close();
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('DeepgramClient.close() was already called.');
    }
  }
}
