/// Continuous text-to-speech streaming over `WSS /v1/speak` (Aura and
/// Aura-2 voices).
///
/// Use [TtsStreamClient] — created via
/// `DeepgramClient.createTtsStreamClient` — to convert a stream of text
/// into a stream of audio.
library;

import 'dart:async';
import 'dart:convert';

import '../core/deepgram_auth.dart';
import '../core/deepgram_config.dart';
import '../core/deepgram_exception.dart';
import '../core/deepgram_logger.dart';
import '../core/http/http_engine.dart';
import '../core/ws/resilient_websocket.dart';
import 'speak_options.dart';

export '../core/ws/resilient_websocket.dart';
export 'speak_options.dart';

/// A continuous text-to-speech session over `WSS /v1/speak`.
///
/// ```dart
/// final tts = deepgram.createTtsStreamClient(
///   options: const SpeakOptions(model: DeepgramVoices.aura2ThaliaEn),
/// );
/// await tts.start();
/// tts.audio.listen((chunk) => player.push(chunk));
/// tts.sendText('Hello, ');
/// tts.sendText('world!');
/// tts.flush(); // ask for audio covering everything sent so far
/// await tts.close();
/// ```
///
/// ## Lifecycle
///
/// 1. `await start()` — opens the socket. Throws
///    [DeepgramWebSocketException] when the connection cannot be
///    established.
/// 2. [sendText] buffers text server-side; [flush] asks the server to
///    emit audio for everything buffered so far; [clear] discards
///    unflushed text.
/// 3. `await close()` — sends a Close message (which flushes any pending
///    audio), drains briefly, and releases resources.
///
/// ## Reconnect behavior
///
/// The underlying [ResilientWebSocket] reconnects automatically with
/// backoff and sends `{"type":"KeepAlive"}` every 5 s by default. After a
/// reconnect the server starts a brand-new session: any text that was
/// sent but not yet flushed when the connection dropped is lost, so
/// re-send it after observing the next open state on [connectionStates].
class TtsStreamClient {
  /// Creates a continuous TTS session for `WSS /v1/speak`.
  ///
  /// [options] select the voice and audio format and are serialized into
  /// the connection URL's query string. [wsOptions] tune keepalive and
  /// reconnection behavior (the defaults are suitable for TTS).
  TtsStreamClient({
    required DeepgramConfig config,
    required DeepgramAuth auth,
    required HttpEngine http,
    SpeakOptions? options,
    ResilientWebSocketOptions? wsOptions,
    DeepgramLogger? logger,
  }) : _logger = logger ?? config.logger ?? DeepgramLogger(),
       _ws = ResilientWebSocket(
         uri: config.wsUri('/v1/speak', options?.toQuery()),
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
  final StreamController<TtsMetadataMessage> _metadataController =
      StreamController<TtsMetadataMessage>.broadcast();
  final StreamController<int> _flushedController =
      StreamController<int>.broadcast();
  final StreamController<int> _clearedController =
      StreamController<int>.broadcast();
  final StreamController<TtsWarning> _warningsController =
      StreamController<TtsWarning>.broadcast();

  StreamSubscription<WsMessage>? _messagesSub;
  bool _startCalled = false;
  bool _closed = false;

  /// Binary audio frames as they are generated.
  ///
  /// Concatenating the chunks in order yields the complete audio stream —
  /// raw (non-containerized) audio in the negotiated encoding and sample
  /// rate.
  Stream<List<int>> get audio => _audioController.stream;

  /// `Metadata` messages: model information about each audio generation.
  Stream<TtsMetadataMessage> get metadata => _metadataController.stream;

  /// `Flushed` messages: the sequence id of each completed flush.
  Stream<int> get flushed => _flushedController.stream;

  /// `Cleared` messages: the sequence id of each completed clear.
  Stream<int> get cleared => _clearedController.stream;

  /// Warnings from the server, plus `MALFORMED_FRAME` warnings emitted by
  /// this SDK when it drops an unparseable frame. A warning never closes
  /// the connection.
  Stream<TtsWarning> get warnings => _warningsController.stream;

  /// Connection state transitions of the underlying socket.
  Stream<WsConnectionState> get connectionStates => _ws.states;

  /// Whether the socket is currently open.
  bool get isConnected => _ws.isConnected;

  /// Opens the connection to `wss://api.deepgram.com/v1/speak`.
  ///
  /// Completes when the socket is open. Throws [DeepgramWebSocketException]
  /// when the underlying [ResilientWebSocket] gives up reconnecting (its
  /// terminal `failed` state) — the same session may then be restarted
  /// with another `start()` call, or replaced with a new client.
  Future<void> start() {
    if (_closed) {
      throw const DeepgramStateException('This TTS session was closed.');
    }
    if (_startCalled && _ws.state != WsConnectionState.failed) {
      throw const DeepgramStateException('start() was already called.');
    }
    _startCalled = true;
    // Subscribe to the state stream BEFORE connecting so the open/failed
    // transition can never race the subscription.
    final completion = _ws.states
        .firstWhere(
          (WsConnectionState state) =>
              state == WsConnectionState.open ||
              state == WsConnectionState.failed ||
              state == WsConnectionState.closed,
        )
        .then<void>((WsConnectionState state) {
          if (state != WsConnectionState.open) {
            throw DeepgramWebSocketException(
              'The /v1/speak WebSocket connection did not open '
              '(terminal state: ${state.name}).',
            );
          }
        });
    unawaited(_ws.connect());
    return completion;
  }

  /// Sends text to be synthesized: `{"type": "Speak", "text": "..."}`.
  ///
  /// The server buffers the text until a [flush] or [close] asks for
  /// audio. Keep the accumulated unflushed text within the per-request
  /// character limit (2000 for Aura and Aura-2). Frames sent while
  /// disconnected are dropped silently; check [isConnected] (or buffer at
  /// the call site) if you need gap recovery.
  void sendText(String text) {
    _send(<String, dynamic>{'type': 'Speak', 'text': text});
  }

  /// Asks the server to emit audio for all text sent so far:
  /// `{"type": "Flush"}`.
  ///
  /// The server acknowledges on [flushed] once the audio for that batch
  /// has been fully delivered.
  void flush() {
    _send(<String, dynamic>{'type': 'Flush'});
  }

  /// Discards all unflushed text server-side: `{"type": "Clear"}`.
  ///
  /// Audio already flushed (or in flight) is unaffected. The server
  /// acknowledges on [cleared].
  void clear() {
    _send(<String, dynamic>{'type': 'Clear'});
  }

  /// Closes the session gracefully.
  ///
  /// Sends `{"type": "Close"}` — which asks the server to flush any
  /// pending audio — waits up to 5 s for the drain, then releases the
  /// socket and the client's streams (their listeners receive onDone).
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _ws.close(closeMessage: '{"type":"Close"}');
    await _teardown();
  }

  /// Closes the session immediately, dropping unflushed text and any
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
    await _metadataController.close();
    await _flushedController.close();
    await _clearedController.close();
    await _warningsController.close();
  }

  void _send(Map<String, dynamic> message) {
    if (_closed) {
      _logger.warn('Dropping outbound TTS message: the session is closed.');
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
          case 'Metadata':
            _safeAdd(_metadataController, TtsMetadataMessage.fromJson(decoded));
            break;
          case 'Flushed':
            _handleSequenceId(decoded, _flushedController, 'Flushed');
            break;
          case 'Cleared':
            _handleSequenceId(decoded, _clearedController, 'Cleared');
            break;
          case 'Warning':
            _safeAdd(_warningsController, TtsWarning.fromJson(decoded));
            break;
          default:
            _logger.debug('Ignoring unknown /v1/speak frame type: $rawType');
        }
      },
      onError: (Object error) {
        _logger.warn('Error on the /v1/speak message stream.', error);
      },
    );
  }

  void _handleSequenceId(
    Map<String, dynamic> decoded,
    StreamController<int> controller,
    String label,
  ) {
    final sequenceId = _intOf(decoded, 'sequence_id');
    if (sequenceId == null) {
      _emitMalformedWarning(
        '$label frame has no valid sequence_id',
        jsonEncode(decoded),
      );
      return;
    }
    _safeAdd(controller, sequenceId);
  }

  void _safeAdd<T>(StreamController<T> controller, T event) {
    if (!controller.isClosed) {
      controller.add(event);
    }
  }

  void _emitMalformedWarning(String reason, String? rawFrame) {
    _logger.warn('Malformed /v1/speak frame ($reason): $rawFrame');
    _safeAdd(
      _warningsController,
      TtsWarning(
        code: 'MALFORMED_FRAME',
        description: 'Dropped a malformed server frame ($reason).',
      ),
    );
  }
}

/// Metadata about an audio generation on `/v1/speak`.
class TtsMetadataMessage {
  /// Creates a metadata message.
  const TtsMetadataMessage({
    required this.requestId,
    required this.modelName,
    required this.modelVersion,
    required this.modelUuid,
    required this.additionalModelUuids,
  });

  /// Unique identifier for the request.
  final String requestId;

  /// Name of the model (voice) used.
  final String modelName;

  /// Version of the primary model used.
  final String modelVersion;

  /// Unique identifier of the primary model used.
  final String modelUuid;

  /// Identifiers of any additional models used to serve the request.
  final List<String> additionalModelUuids;

  /// Defensively parses a `Metadata` frame. Fields that are missing or of
  /// the wrong type fall back to empty values instead of throwing.
  factory TtsMetadataMessage.fromJson(Map<String, dynamic> json) {
    return TtsMetadataMessage(
      requestId: _stringOf(json, 'request_id'),
      modelName: _stringOf(json, 'model_name'),
      modelVersion: _stringOf(json, 'model_version'),
      modelUuid: _stringOf(json, 'model_uuid'),
      additionalModelUuids: _stringListOf(json, 'additional_model_uuids'),
    );
  }
}

/// A non-fatal warning from a TTS WebSocket API.
class TtsWarning {
  /// Creates a warning with the given [code] and [description].
  const TtsWarning({required this.code, required this.description});

  /// Machine-readable warning code.
  ///
  /// Server codes are SCREAMING_SNAKE_CASE strings (on Flux TTS, for
  /// example: `NO_ACTIVE_SPEECH`, `NO_SYNTHESIZABLE_TEXT`,
  /// `SYNTHESIS_RETRYING`, `PRONUNCIATION_WARNINGS`). This SDK
  /// additionally emits the synthetic `MALFORMED_FRAME` code whenever it
  /// drops a server frame it could not parse.
  final String code;

  /// Human-readable description of the condition.
  final String description;

  /// Defensively parses a `Warning` frame; missing fields default to
  /// empty strings.
  factory TtsWarning.fromJson(Map<String, dynamic> json) {
    return TtsWarning(
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
