/// Turn-based Flux text-to-speech over `WSS /v2/speak`.
///
/// [FluxTtsClient] — created via `DeepgramClient.createFluxTtsClient` — is
/// built for voice-agent pipelines: stream LLM tokens into a turn with
/// [FluxTtsClient.speak], end the turn with [FluxTtsClient.flush],
/// interrupt the turn when the user barges in with
/// [FluxTtsClient.interrupt], and read per-turn and per-session billing
/// from typed event streams.
library;

import 'dart:async';
import 'dart:convert';

import '../core/deepgram_auth.dart';
import '../core/deepgram_config.dart';
import '../core/deepgram_exception.dart';
import '../core/deepgram_logger.dart';
import '../core/http/http_engine.dart';
import 'speak_stream_client.dart';

export '../core/ws/resilient_websocket.dart';
export 'speak_options.dart';
export 'speak_stream_client.dart' show TtsWarning;

/// A turn-based Flux TTS session over `WSS /v2/speak`.
///
/// ```dart
/// final tts = deepgram.createFluxTtsClient(
///   options: const FluxTtsOptions(model: DeepgramVoices.fluxAlexisEn),
/// );
/// await tts.start();
/// tts.audio.listen((chunk) => player.push(chunk));
/// tts.speak('Hello! How can I help you today?');
/// tts.flush();
/// await tts.close(); // SessionMetadata arrives just before the close
/// ```
///
/// ## Turns
///
/// [speak] appends text to the active turn. [flush] ends the turn and
/// generates the remaining audio; the server then reports the turn's
/// billing and timing on [speechMetadata]. [interrupt] cancels the active
/// turn when the user barges in; the server reports what was heard and
/// what remains on [speechInterrupted].
///
/// ## Reconnect behavior
///
/// The underlying [ResilientWebSocket] reconnects automatically with
/// backoff and sends `{"type":"KeepAlive"}` every 5 s by default. After a
/// reconnect the server starts a brand-new session: turns buffered but
/// not flushed when the connection dropped are lost, and session billing
/// totals restart. Re-send pending text after observing the next open
/// state on [connectionStates].
class FluxTtsClient {
  /// Creates a turn-based Flux TTS session for `WSS /v2/speak`.
  ///
  /// [options] carry the required Flux model (`flux-{voice}-{lang}`) and
  /// the audio format, and are serialized into the connection URL's query
  /// string. [wsOptions] tune keepalive and reconnection behavior.
  FluxTtsClient({
    required DeepgramConfig config,
    required DeepgramAuth auth,
    required HttpEngine http,
    FluxTtsOptions? options,
    ResilientWebSocketOptions? wsOptions,
    DeepgramLogger? logger,
  })  : _logger = logger ?? config.logger ?? DeepgramLogger(),
        _ws = ResilientWebSocket(
          uri: config.wsUri('/v2/speak', options?.toQuery()),
          config: config,
          auth: auth,
          options: wsOptions ?? const ResilientWebSocketOptions(),
          logger: logger,
        ) {
    _listenForMessages();
  }

  final DeepgramLogger _logger;
  final ResilientWebSocket _ws;

  final StreamController<List<int>> _audioController =
      StreamController<List<int>>.broadcast();
  final StreamController<FluxSpeakConnected> _connectedController =
      StreamController<FluxSpeakConnected>.broadcast();
  final StreamController<FluxSpeechStarted> _speechStartedController =
      StreamController<FluxSpeechStarted>.broadcast();
  final StreamController<FluxSpeechMetadata> _speechMetadataController =
      StreamController<FluxSpeechMetadata>.broadcast();
  final StreamController<FluxSpeechInterrupted> _speechInterruptedController =
      StreamController<FluxSpeechInterrupted>.broadcast();
  final StreamController<FluxFlushed> _flushedController =
      StreamController<FluxFlushed>.broadcast();
  final StreamController<FluxSessionMetadata> _sessionMetadataController =
      StreamController<FluxSessionMetadata>.broadcast();
  final StreamController<FluxSpeakConfigureSuccess>
      _configureSuccessController =
      StreamController<FluxSpeakConfigureSuccess>.broadcast();
  final StreamController<FluxSpeakConfigureFailure>
      _configureFailureController =
      StreamController<FluxSpeakConfigureFailure>.broadcast();
  final StreamController<TtsWarning> _warningsController =
      StreamController<TtsWarning>.broadcast();
  final StreamController<FluxSpeakError> _errorsController =
      StreamController<FluxSpeakError>.broadcast();

  StreamSubscription<WsMessage>? _messagesSub;
  bool _startCalled = false;
  bool _closed = false;

  /// Binary audio frames as they are generated.
  ///
  /// Concatenating the chunks in order yields the complete audio stream —
  /// raw (non-containerized) audio in the negotiated encoding and sample
  /// rate.
  Stream<List<int>> get audio => _audioController.stream;

  /// The `Connected` handshake, sent once after the socket opens: the
  /// request id and the resolved model details.
  Stream<FluxSpeakConnected> get connected => _connectedController.stream;

  /// `SpeechStarted` messages: the server-minted identifier of each new
  /// turn (of the form `dg_sp_<12 hex digits>`).
  Stream<FluxSpeechStarted> get speechStarted =>
      _speechStartedController.stream;

  /// `SpeechMetadata` messages: per-turn billing and timing, delivered
  /// after each manual flush.
  Stream<FluxSpeechMetadata> get speechMetadata =>
      _speechMetadataController.stream;

  /// `SpeechInterrupted` messages: what the user heard — and the
  /// interrupted turn's billing — after an interrupt.
  Stream<FluxSpeechInterrupted> get speechInterrupted =>
      _speechInterruptedController.stream;

  /// `Flushed` messages: echoes confirming receipt of a manual flush,
  /// carrying the turn's speech id.
  Stream<FluxFlushed> get flushed => _flushedController.stream;

  /// `SessionMetadata` messages: cumulative session totals, delivered
  /// just before the socket closes after a graceful [close].
  Stream<FluxSessionMetadata> get sessionMetadata =>
      _sessionMetadataController.stream;

  /// `ConfigureSuccess` messages: acknowledgments of successful
  /// mid-session configuration changes (e.g. speed).
  Stream<FluxSpeakConfigureSuccess> get configureSuccess =>
      _configureSuccessController.stream;

  /// `ConfigureFailure` messages: rejections of configuration changes,
  /// with a machine-readable code.
  Stream<FluxSpeakConfigureFailure> get configureFailure =>
      _configureFailureController.stream;

  /// Warnings from the server, plus `MALFORMED_FRAME` warnings emitted by
  /// this SDK when it drops an unparseable frame. Synthesis continues and
  /// the connection stays up.
  Stream<TtsWarning> get warnings => _warningsController.stream;

  /// `Error` messages: fatal protocol errors. The server follows an error
  /// with a WebSocket close; observe [connectionStates] for the
  /// transition.
  Stream<FluxSpeakError> get errors => _errorsController.stream;

  /// Connection state transitions of the underlying socket.
  Stream<WsConnectionState> get connectionStates => _ws.states;

  /// Whether the socket is currently open.
  bool get isConnected => _ws.isConnected;

  /// Opens the connection to `wss://api.deepgram.com/v2/speak`.
  ///
  /// Completes when the socket is open. Throws [DeepgramWebSocketException]
  /// when the underlying [ResilientWebSocket] gives up reconnecting (its
  /// terminal `failed` state) — the same session may then be restarted
  /// with another `start()` call, or replaced with a new client.
  Future<void> start() {
    if (_closed) {
      throw const DeepgramStateException('This Flux TTS session was closed.');
    }
    if (_startCalled && _ws.state != WsConnectionState.failed) {
      throw const DeepgramStateException('start() was already called.');
    }
    _startCalled = true;
    // Subscribe to the state stream BEFORE connecting so the open/failed
    // transition can never race the subscription.
    final completion = _ws.states
        .firstWhere((WsConnectionState state) =>
            state == WsConnectionState.open ||
            state == WsConnectionState.failed ||
            state == WsConnectionState.closed)
        .then<void>((WsConnectionState state) {
      if (state != WsConnectionState.open) {
        throw DeepgramWebSocketException(
          'The /v2/speak WebSocket connection did not open '
          '(terminal state: ${state.name}).',
        );
      }
    });
    unawaited(_ws.connect());
    return completion;
  }

  /// Sends text to be synthesized into the active turn:
  /// `{"type": "Speak", "text": "..."}`.
  ///
  /// [text] may contain inline pronunciation controls (Early Access) of
  /// the form {"word": "tomato", "pronounce": "təˈmɑːtoʊ"} — a JSON
  /// object with curly braces embedded directly in the text. Two
  /// restrictions apply: pronunciation controls cannot be combined with a
  /// speed other than 1.0, and inline pause markers are batch-only — both
  /// fail the connection with a `DATA-0002` error. Frames sent while
  /// disconnected are dropped silently; check [isConnected] if you need
  /// gap recovery.
  void speak(String text) {
    _send(<String, dynamic>{'type': 'Speak', 'text': text});
  }

  /// Ends the active turn and generates the remaining audio:
  /// `{"type": "Flush"}`.
  ///
  /// The server echoes on [flushed], then delivers the turn's billing on
  /// [speechMetadata] once its audio is complete.
  void flush() {
    _send(<String, dynamic>{'type': 'Flush'});
  }

  /// Cancels the active turn because the user barged in:
  /// `{"type": "Interrupt"}`.
  ///
  /// When [playbackOffsetMs] is provided, the message carries
  /// `playback_offset: {"type": "time_ms", "value": N}` — milliseconds of
  /// session audio the client had played — which lets the server split
  /// the turn's text (see [FluxSpeechInterrupted.textSpoken] and
  /// [FluxSpeechInterrupted.textRemaining]). The offset is cumulative
  /// from the start of the session, and each successive interrupt must
  /// advance past the position the previous one established.
  void interrupt({int? playbackOffsetMs}) {
    if (playbackOffsetMs == null) {
      _send(<String, dynamic>{'type': 'Interrupt'});
      return;
    }
    _send(<String, dynamic>{
      'type': 'Interrupt',
      'playback_offset': <String, dynamic>{
        'type': 'time_ms',
        'value': playbackOffsetMs,
      },
    });
  }

  /// Updates the speech-rate multiplier mid-session:
  /// `{"type": "Configure", "speed": S}`.
  ///
  /// [speed] must be between 0.5 and 1.5 in 0.05 increments. Invalid
  /// values are not thrown locally — the server answers on
  /// [configureFailure] with a code such as `SPEED_OUT_OF_RANGE` or
  /// `SPEED_INCREMENT_INVALID`, while successful changes are echoed on
  /// [configureSuccess].
  void configureSpeed(double speed) {
    _send(<String, dynamic>{'type': 'Configure', 'speed': speed});
  }

  /// Closes the session gracefully.
  ///
  /// Sends `{"type": "Close"}` — which drains all remaining and queued
  /// audio and makes the server deliver a final [FluxSessionMetadata]
  /// message with the session totals — waits up to 5 s for the drain,
  /// then releases the socket and the client's streams (their listeners
  /// receive onDone).
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _ws.close(closeMessage: '{"type":"Close"}');
    await _teardown();
  }

  /// Closes the session immediately, dropping the active turn and any
  /// pending audio.
  Future<void> forceClose() async {
    if (_closed) return;
    _closed = true;
    await _ws.forceClose();
    await _teardown();
  }

  // -------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------

  Future<void> _teardown() async {
    try {
      await _messagesSub?.cancel();
    } catch (_) {}
    _messagesSub = null;
    await _ws.dispose();
    await _audioController.close();
    await _connectedController.close();
    await _speechStartedController.close();
    await _speechMetadataController.close();
    await _speechInterruptedController.close();
    await _flushedController.close();
    await _sessionMetadataController.close();
    await _configureSuccessController.close();
    await _configureFailureController.close();
    await _warningsController.close();
    await _errorsController.close();
  }

  void _send(Map<String, dynamic> message) {
    if (_closed) {
      _logger.warn('Dropping outbound Flux TTS message: the session is '
          'closed.');
      return;
    }
    _ws.send(jsonEncode(message));
  }

  void _listenForMessages() {
    _messagesSub = _ws.messages.listen(
      (WsMessage message) {
        if (message.isBinary) {
          _safeAdd(_audioController, message.bytes ?? const <int>[]);
          return;
        }
        final decoded = _tryDecodeJson(message.text);
        if (decoded == null) {
          _emitMalformedWarning('frame is not a JSON object', message.text);
          return;
        }
        final dynamic rawType = decoded['type'];
        if (rawType is! String) {
          _emitMalformedWarning('frame has no "type" field', message.text);
          return;
        }
        switch (rawType) {
          case 'Connected':
            _safeAdd(
              _connectedController,
              FluxSpeakConnected.fromJson(decoded),
            );
            break;
          case 'SpeechStarted':
            _safeAdd(
              _speechStartedController,
              FluxSpeechStarted.fromJson(decoded),
            );
            break;
          case 'SpeechMetadata':
            _safeAdd(
              _speechMetadataController,
              FluxSpeechMetadata.fromJson(decoded),
            );
            break;
          case 'SpeechInterrupted':
            _safeAdd(
              _speechInterruptedController,
              FluxSpeechInterrupted.fromJson(decoded),
            );
            break;
          case 'Flushed':
            _safeAdd(_flushedController, FluxFlushed.fromJson(decoded));
            break;
          case 'SessionMetadata':
            _safeAdd(
              _sessionMetadataController,
              FluxSessionMetadata.fromJson(decoded),
            );
            break;
          case 'ConfigureSuccess':
            _safeAdd(
              _configureSuccessController,
              FluxSpeakConfigureSuccess.fromJson(decoded),
            );
            break;
          case 'ConfigureFailure':
            _safeAdd(
              _configureFailureController,
              FluxSpeakConfigureFailure.fromJson(decoded),
            );
            break;
          case 'Warning':
            _safeAdd(_warningsController, TtsWarning.fromJson(decoded));
            break;
          case 'Error':
            _safeAdd(_errorsController, FluxSpeakError.fromJson(decoded));
            break;
          default:
            _logger.debug('Ignoring unknown /v2/speak frame type: $rawType');
        }
      },
      onError: (Object error) {
        _logger.warn('Error on the /v2/speak message stream.', error);
      },
    );
  }

  void _safeAdd<T>(StreamController<T> controller, T event) {
    if (!controller.isClosed) {
      controller.add(event);
    }
  }

  void _emitMalformedWarning(String reason, String? rawFrame) {
    _logger.warn('Malformed /v2/speak frame ($reason): $rawFrame');
    _safeAdd(
      _warningsController,
      TtsWarning(
        code: 'MALFORMED_FRAME',
        description: 'Dropped a malformed server frame ($reason).',
      ),
    );
  }
}

/// The `Connected` handshake of a `/v2/speak` session.
class FluxSpeakConnected {
  /// Creates a connected message.
  const FluxSpeakConnected({
    required this.requestId,
    required this.modelName,
    required this.modelVersion,
    required this.modelUuids,
  });

  /// Unique identifier of the `/v2/speak` request.
  final String requestId;

  /// Resolved model name.
  final String modelName;

  /// Resolved model version.
  final String modelVersion;

  /// Resolved model UUIDs — a list, because a resolved model may be
  /// backed by more than one underlying model.
  final List<String> modelUuids;

  /// Defensively parses a `Connected` frame; missing fields fall back to
  /// empty values.
  factory FluxSpeakConnected.fromJson(Map<String, dynamic> json) {
    return FluxSpeakConnected(
      requestId: _stringOf(json, 'request_id'),
      modelName: _stringOf(json, 'model_name'),
      modelVersion: _stringOf(json, 'model_version'),
      modelUuids: _stringListOf(json, 'model_uuids'),
    );
  }
}

/// A `SpeechStarted` message: the start of a new turn.
class FluxSpeechStarted {
  /// Creates a speech-started message.
  const FluxSpeechStarted({required this.speechId});

  /// Server-minted identifier for this turn, of the form
  /// `dg_sp_<12 hex digits>`. Informational.
  final String speechId;

  /// Defensively parses a `SpeechStarted` frame; a missing speech id
  /// falls back to an empty string.
  factory FluxSpeechStarted.fromJson(Map<String, dynamic> json) {
    return FluxSpeechStarted(speechId: _stringOf(json, 'speech_id'));
  }
}

/// Counts of the inline controls the server acted on during a turn.
class FluxControlsApplied {
  /// Creates a controls-applied summary.
  const FluxControlsApplied({
    required this.pronunciationsApplied,
    required this.breaksApplied,
    required this.pronunciationWarnings,
  });

  /// Pronunciation overrides successfully applied. Mirrors the Aura-2
  /// `dg-pronunciations-applied` REST header.
  final int pronunciationsApplied;

  /// Pause (break) controls successfully applied — always 0 on the
  /// WebSocket, where inline pause controls are not supported.
  final int breaksApplied;

  /// Pronunciation entries that triggered a warning (invalid IPA, word
  /// too long).
  final int pronunciationWarnings;

  /// Defensively parses a `controls_applied` object; missing fields fall
  /// back to zero.
  factory FluxControlsApplied.fromJson(Map<String, dynamic> json) {
    return FluxControlsApplied(
      pronunciationsApplied: _intOr(json, 'pronunciations_applied', 0),
      breaksApplied: _intOr(json, 'breaks_applied', 0),
      pronunciationWarnings: _intOr(json, 'pronunciation_warnings', 0),
    );
  }
}

/// Per-turn billing and timing for a `SpeechMetadata` message.
///
/// The same shape (without the `type` field) is embedded inside
/// [FluxSpeechInterrupted.metadata].
class FluxSpeechMetadata {
  /// Creates per-turn metadata.
  const FluxSpeechMetadata({
    required this.speechId,
    required this.audioDurationMs,
    required this.inputCharacterCount,
    required this.billableCharacterCount,
    required this.controlsApplied,
  });

  /// Server-assigned turn identifier.
  final String speechId;

  /// Total audio duration produced for this turn, in milliseconds.
  final int audioDurationMs;

  /// Raw input character count for this turn, before text normalization.
  final int inputCharacterCount;

  /// Billable character count for this turn — the input count with
  /// stripped control characters removed. Always less than or equal to
  /// [inputCharacterCount].
  final int billableCharacterCount;

  /// Counts of the inline controls the server acted on during the turn.
  final FluxControlsApplied controlsApplied;

  /// Defensively parses a `SpeechMetadata` frame (or the embedded
  /// `metadata` object of a `SpeechInterrupted` frame); missing fields
  /// fall back to empty or zero values.
  factory FluxSpeechMetadata.fromJson(Map<String, dynamic> json) {
    return FluxSpeechMetadata(
      speechId: _stringOf(json, 'speech_id'),
      audioDurationMs: _intOr(json, 'audio_duration_ms', 0),
      inputCharacterCount: _intOr(json, 'input_character_count', 0),
      billableCharacterCount: _intOr(json, 'billable_character_count', 0),
      controlsApplied: _parseControlsApplied(json['controls_applied']),
    );
  }
}

/// A `SpeechInterrupted` message: what the user heard when barging in.
class FluxSpeechInterrupted {
  /// Creates a speech-interrupted message.
  const FluxSpeechInterrupted({
    required this.audioPlayedMs,
    required this.textSpoken,
    required this.textRemaining,
    required this.metadata,
  });

  /// How much audio the client had played when the interrupt landed, in
  /// milliseconds from the start of the session. Echoes the interrupt's
  /// `playback_offset` when one was supplied; otherwise it is the
  /// server's own total.
  final int audioPlayedMs;

  /// The portion of the turn's text the user heard. Null when the
  /// interrupt carried no playback offset.
  final String? textSpoken;

  /// The portion of the turn's text the user did not hear. Null when the
  /// interrupt carried no playback offset.
  final String? textRemaining;

  /// Billing and timing for the interrupted turn. Null when absent or
  /// malformed.
  final FluxSpeechMetadata? metadata;

  /// Defensively parses a `SpeechInterrupted` frame; missing fields fall
  /// back to zero or null values.
  factory FluxSpeechInterrupted.fromJson(Map<String, dynamic> json) {
    return FluxSpeechInterrupted(
      audioPlayedMs: _intOr(json, 'audio_played_ms', 0),
      textSpoken: _nullableStringOf(json, 'text_spoken'),
      textRemaining: _nullableStringOf(json, 'text_remaining'),
      metadata: _parseOptionalSpeechMetadata(json['metadata']),
    );
  }
}

/// A `Flushed` message: an echo confirming receipt of a manual flush.
class FluxFlushed {
  /// Creates a flushed message.
  const FluxFlushed({required this.speechId});

  /// Server-assigned identifier of the turn that was flushed.
  final String speechId;

  /// Defensively parses a `Flushed` frame; a missing speech id falls back
  /// to an empty string.
  factory FluxFlushed.fromJson(Map<String, dynamic> json) {
    return FluxFlushed(speechId: _stringOf(json, 'speech_id'));
  }
}

/// A `SessionMetadata` message: cumulative session totals, delivered
/// before the socket closes.
class FluxSessionMetadata {
  /// Creates a session-metadata message.
  const FluxSessionMetadata({
    required this.totalAudioDurationMs,
    required this.totalInputCharacterCount,
    required this.totalBillableCharacterCount,
  });

  /// Cumulative audio duration produced across the session, in
  /// milliseconds. An interrupt rebases this onto the audio the client
  /// actually played.
  final int totalAudioDurationMs;

  /// Cumulative raw input character count across the session.
  final int totalInputCharacterCount;

  /// Cumulative billable character count across the session.
  final int totalBillableCharacterCount;

  /// Defensively parses a `SessionMetadata` frame; missing fields fall
  /// back to zero.
  factory FluxSessionMetadata.fromJson(Map<String, dynamic> json) {
    return FluxSessionMetadata(
      totalAudioDurationMs: _intOr(json, 'total_audio_duration_ms', 0),
      totalInputCharacterCount: _intOr(json, 'total_input_character_count', 0),
      totalBillableCharacterCount:
          _intOr(json, 'total_billable_character_count', 0),
    );
  }
}

/// The synthesis configuration in effect after a successful Configure.
///
/// A field is present only when it has been set on the session.
class FluxAppliedConfig {
  /// Creates an applied-configuration snapshot.
  const FluxAppliedConfig({required this.speed});

  /// The speech-rate multiplier in effect (1.0 is the model's nominal
  /// rate). Null when speed has not been set.
  final double? speed;

  /// Defensively parses an `applied` object.
  factory FluxAppliedConfig.fromJson(Map<String, dynamic> json) {
    return FluxAppliedConfig(speed: _doubleOf(json, 'speed'));
  }
}

/// A `ConfigureSuccess` message: acknowledgment of a configuration
/// change.
class FluxSpeakConfigureSuccess {
  /// Creates a configure-success message.
  const FluxSpeakConfigureSuccess({required this.applied});

  /// The synthesis configuration now in effect. Null when absent or
  /// malformed.
  final FluxAppliedConfig? applied;

  /// Defensively parses a `ConfigureSuccess` frame.
  factory FluxSpeakConfigureSuccess.fromJson(Map<String, dynamic> json) {
    return FluxSpeakConfigureSuccess(
        applied: _parseAppliedConfig(json['applied']));
  }
}

/// A `ConfigureFailure` message: rejection of a configuration change.
class FluxSpeakConfigureFailure {
  /// Creates a configure-failure message.
  const FluxSpeakConfigureFailure({
    required this.code,
    this.field,
    this.value,
    this.description,
  });

  /// Failure code: `SPEED_OUT_OF_RANGE` (outside the published range),
  /// `SPEED_INCREMENT_INVALID` (inside the range but off the 0.05
  /// increment), `SPEED_NOT_SUPPORTED` (this model or language has no
  /// runtime speed control), `CONTROL_COMBINATION_INVALID` (speed was set
  /// while a buffered turn still carries a pronunciation control), or
  /// `INTERNAL_ERROR` (server-side failure).
  final String code;

  /// The configuration field the failure is about (`speed`). Null when
  /// the failure is not tied to one field.
  final String? field;

  /// The rejected value for [field]. Null when there is no offending
  /// value to echo.
  final double? value;

  /// Human-readable description of the failure.
  final String? description;

  /// Defensively parses a `ConfigureFailure` frame; missing fields fall
  /// back to empty or null values.
  factory FluxSpeakConfigureFailure.fromJson(Map<String, dynamic> json) {
    return FluxSpeakConfigureFailure(
      code: _stringOf(json, 'code'),
      field: _nullableStringOf(json, 'field'),
      value: _doubleOf(json, 'value'),
      description: _nullableStringOf(json, 'description'),
    );
  }
}

/// An `Error` message: a fatal error, followed by a WebSocket close.
class FluxSpeakError {
  /// Creates an error message.
  const FluxSpeakError({required this.code, required this.description});

  /// Machine-readable error code: `MESSAGE-0000` (malformed message),
  /// `DATA-0000` / `DATA-0002` (invalid data — including invalid inline
  /// controls and speed), `BIG-0000` (message too large), or
  /// `NET-0000` through `NET-0004` (network-level errors).
  final String code;

  /// Human-readable description of the error.
  final String description;

  /// Defensively parses an `Error` frame; missing fields fall back to
  /// empty strings.
  factory FluxSpeakError.fromJson(Map<String, dynamic> json) {
    return FluxSpeakError(
      code: _stringOf(json, 'code'),
      description: _stringOf(json, 'description'),
    );
  }
}

// ---------------------------------------------------------------------------
// Defensive JSON helpers
// ---------------------------------------------------------------------------

Map<String, dynamic>? _tryDecodeJson(String? text) {
  if (text == null || text.isEmpty) return null;
  try {
    final dynamic decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

String _stringOf(Map<String, dynamic> json, String key) {
  final dynamic value = json[key];
  return value is String ? value : '';
}

String? _nullableStringOf(Map<String, dynamic> json, String key) {
  final dynamic value = json[key];
  return value is String ? value : null;
}

List<String> _stringListOf(Map<String, dynamic> json, String key) {
  final dynamic value = json[key];
  if (value is! List<dynamic>) return const <String>[];
  return <String>[
    for (final dynamic item in value)
      if (item is String) item,
  ];
}

int? _intOf(Map<String, dynamic> json, String key) {
  final dynamic value = json[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

int _intOr(Map<String, dynamic> json, String key, int fallback) {
  return _intOf(json, key) ?? fallback;
}

double? _doubleOf(Map<String, dynamic> json, String key) {
  final dynamic value = json[key];
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

FluxControlsApplied _parseControlsApplied(dynamic value) {
  if (value is! Map<String, dynamic>) {
    return const FluxControlsApplied(
      pronunciationsApplied: 0,
      breaksApplied: 0,
      pronunciationWarnings: 0,
    );
  }
  return FluxControlsApplied.fromJson(value);
}

FluxSpeechMetadata? _parseOptionalSpeechMetadata(dynamic value) {
  if (value is! Map<String, dynamic>) return null;
  return FluxSpeechMetadata.fromJson(value);
}

FluxAppliedConfig? _parseAppliedConfig(dynamic value) {
  if (value is! Map<String, dynamic>) return null;
  return FluxAppliedConfig.fromJson(value);
}
