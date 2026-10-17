/// Turn-based Flux speech-to-text client for `/v2/listen`.
///
/// Flux delivers conversational transcription with contextual turn
/// detection: the server reports `StartOfTurn` / `Update` /
/// `EagerEndOfTurn` / `TurnResumed` / `EndOfTurn` events on [turnInfo],
/// and the client can force a turn to end or reconfigure thresholds
/// mid-stream.
///
/// The session is backed by the SDK's [ResilientWebSocket] (classified
/// failures, backoff, KeepAlive). Fatal `Error` messages close the session
/// server-side; if auto-reconnect is left enabled, a reconnect attempt
/// opens a NEW session with a new `request_id` — no turn state carries
/// over. This client performs no disconnect audio buffering (gap recovery
/// is a `/v1/listen` feature).
///
/// ```dart
/// final flux = deepgram.createFluxClient(
///   options: const FluxSttOptions(model: 'flux-general-en'),
/// );
/// flux.turnInfo.listen((turn) => print('${turn.event}: ${turn.transcript}'));
/// await flux.start();
/// flux.sendAudio(chunk);
/// await flux.close();
/// ```
library;

import 'dart:async';
import 'dart:convert';

import '../../core/deepgram_auth.dart';
import '../../core/deepgram_config.dart';
import '../../core/deepgram_exception.dart';
import '../../core/deepgram_logger.dart';
import '../../core/http/http_engine.dart';
import '../../core/ws/resilient_websocket.dart';
import 'flux_stt_models.dart';
import 'flux_stt_options.dart';

/// A Flux speech-to-text session over `wss://api.deepgram.com/v2/listen`.
class FluxSttClient {
  /// Creates a session. Call [start] to connect.
  FluxSttClient({
    required DeepgramConfig config,
    required DeepgramAuth auth,
    required HttpEngine http,
    FluxSttOptions? options,
    ResilientWebSocketOptions? wsOptions,
    DeepgramLogger? logger,
  }) : _logger = logger ?? DeepgramLogger() {
    _ws = ResilientWebSocket(
      uri: config.wsUri('/v2/listen', options?.toQuery()),
      config: config,
      auth: auth,
      options: wsOptions ?? const ResilientWebSocketOptions(),
      logger: _logger,
    );
    _messagesSub = _ws.messages.listen(
      _handleMessage,
      onError: _handleStreamError,
    );
  }

  /// Logger for this session.
  final DeepgramLogger _logger;

  late final ResilientWebSocket _ws;
  StreamSubscription<WsMessage>? _messagesSub;

  final StreamController<FluxConnected> _connectedController =
      StreamController<FluxConnected>.broadcast();
  final StreamController<FluxTurnInfo> _turnInfoController =
      StreamController<FluxTurnInfo>.broadcast();
  final StreamController<FluxConfigureSuccess> _configureSuccessController =
      StreamController<FluxConfigureSuccess>.broadcast();
  final StreamController<FluxConfigureFailure> _configureFailureController =
      StreamController<FluxConfigureFailure>.broadcast();
  final StreamController<FluxWarning> _warningsController =
      StreamController<FluxWarning>.broadcast();
  final StreamController<FluxFatalError> _fatalErrorsController =
      StreamController<FluxFatalError>.broadcast();

  bool _closed = false;

  // ---------------------------------------------------------------------
  // Event streams
  // ---------------------------------------------------------------------

  /// The `Connected` message of the session.
  Stream<FluxConnected> get connected => _connectedController.stream;

  /// Turn events: `StartOfTurn`, `Update`, `EagerEndOfTurn`, `TurnResumed`,
  /// and `EndOfTurn`.
  Stream<FluxTurnInfo> get turnInfo => _turnInfoController.stream;

  /// Confirmations of applied `Configure` messages.
  Stream<FluxConfigureSuccess> get configureSuccess =>
      _configureSuccessController.stream;

  /// Rejections of `Configure` messages.
  Stream<FluxConfigureFailure> get configureFailure =>
      _configureFailureController.stream;

  /// Non-fatal warnings and frames the SDK could not parse (`PARSE_ERROR`).
  Stream<FluxWarning> get warnings => _warningsController.stream;

  /// Fatal `Error` messages. After emitting one, the server closes the
  /// session; a subsequent auto-reconnect (if enabled) starts a brand-new
  /// session with a new `request_id`.
  Stream<FluxFatalError> get fatalErrors => _fatalErrorsController.stream;

  /// Connection state changes of the underlying socket.
  Stream<WsConnectionState> get connectionStates => _ws.states;

  /// Whether the socket is currently open.
  bool get isConnected => _ws.isConnected;

  /// 1-based count of reconnection attempts in the current episode.
  int get reconnectAttempts => _ws.reconnectAttempts;

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  /// Connects the session. Resolves once the socket is open.
  ///
  /// Throws [DeepgramWebSocketException] when the connection gives up after
  /// repeated failures, and [DeepgramStateException] when called after
  /// [close].
  Future<void> start() async {
    if (_closed) {
      throw const DeepgramStateException(
        'This Flux speech-to-text session has already been closed.',
      );
    }
    final current = _ws.state;
    if (current == WsConnectionState.open) return;
    // Subscribe BEFORE connecting so the open/failed transition is never
    // missed; connect() only resolves when the whole session ends.
    final completion = _ws.states.firstWhere(
      (WsConnectionState state) =>
          state == WsConnectionState.open ||
          state == WsConnectionState.failed ||
          state == WsConnectionState.closed,
    );
    if (current == WsConnectionState.idle ||
        current == WsConnectionState.closed ||
        current == WsConnectionState.failed) {
      unawaited(_ws.connect());
    }
    final state = await completion;
    if (state != WsConnectionState.open) {
      throw const DeepgramWebSocketException(
        'The /v2/listen WebSocket connection failed to open (gave up after '
        'retries or was closed while connecting).',
      );
    }
  }

  /// Sends a chunk of audio. Silently ignored while disconnected — Flux has
  /// no disconnect buffering; capture-and-retry at the call site if needed.
  void sendAudio(List<int> bytes) {
    if (_closed || bytes.isEmpty) return;
    _ws.sendBytes(bytes);
  }

  /// Sends a `ForceEndTurn` message, ending the current turn immediately
  /// (the resulting `EndOfTurn` carries `trigger: manual`).
  void forceEndTurn() {
    if (_closed) return;
    _ws.send('{"type":"ForceEndTurn"}');
  }

  /// Sends a `Configure` message built from [configure].
  void configure(FluxConfigure configure) {
    if (_closed) return;
    _ws.send(jsonEncode(configure.toJson()));
  }

  /// Gracefully closes the session: sends `CloseStream`, waits up to five
  /// seconds for the server to finish, then tears everything down.
  /// Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _ws.close(
        closeMessage: '{"type":"CloseStream"}',
        drainTimeout: const Duration(seconds: 5),
      );
    } finally {
      await _teardown();
    }
  }

  /// Immediately closes without draining. Use when abandoning the session.
  /// Idempotent.
  Future<void> forceClose() async {
    if (_closed) return;
    _closed = true;
    try {
      await _ws.forceClose();
    } finally {
      await _teardown();
    }
  }

  // ---------------------------------------------------------------------
  // Message pump
  // ---------------------------------------------------------------------

  void _handleMessage(WsMessage message) {
    // /v2/listen never sends binary frames; ignore them defensively.
    if (message.isBinary) return;
    final text = message.text;
    if (text == null || text.isEmpty) return;
    final decoded = _tryDecode(text);
    if (decoded == null) {
      _emitParseWarning('Received a frame that is not valid JSON.', text);
      return;
    }
    if (decoded is! Map) {
      _emitParseWarning('Received a frame that is not a JSON object.', text);
      return;
    }
    final frame = _stringMap(decoded);
    final rawType = frame['type'];
    if (rawType is! String) {
      _emitParseWarning('Received a frame without a message type.', text);
      return;
    }
    switch (rawType) {
      case 'Connected':
        _emitParsed(
          () => FluxConnected.fromJson(frame),
          _connectedController,
          'Connected',
          text,
        );
        break;
      case 'TurnInfo':
        _emitParsed(
          () => FluxTurnInfo.fromJson(frame),
          _turnInfoController,
          'TurnInfo',
          text,
        );
        break;
      case 'ConfigureSuccess':
        _emitParsed(
          () => FluxConfigureSuccess.fromJson(frame),
          _configureSuccessController,
          'ConfigureSuccess',
          text,
        );
        break;
      case 'ConfigureFailure':
        _emitParsed(
          () => FluxConfigureFailure.fromJson(frame),
          _configureFailureController,
          'ConfigureFailure',
          text,
        );
        break;
      case 'Warning':
        _emitParsed(
          () => FluxWarning.fromJson(frame),
          _warningsController,
          'Warning',
          text,
        );
        break;
      case 'Error':
        _emitParsed(
          () => FluxFatalError.fromJson(frame),
          _fatalErrorsController,
          'Error',
          text,
        );
        break;
      default:
        _logger.debug(
          'Ignoring unknown message type from /v2/listen: '
          '$rawType',
        );
        break;
    }
  }

  void _emitParsed<T>(
    T Function() parse,
    StreamController<T> controller,
    String type,
    String raw,
  ) {
    try {
      final event = parse();
      if (!controller.isClosed) controller.add(event);
    } catch (error) {
      _logger.warn('Malformed $type message from /v2/listen.', error);
      _emitParseWarning('Malformed $type message.', raw);
    }
  }

  void _emitParseWarning(String description, String raw) {
    if (_warningsController.isClosed) return;
    var frameSummary = raw;
    if (frameSummary.length > 512) {
      frameSummary = '${frameSummary.substring(0, 512)}...';
    }
    _warningsController.add(
      FluxWarning(
        code: 'PARSE_ERROR',
        description: '$description (frame: $frameSummary)',
      ),
    );
  }

  void _handleStreamError(Object error) {
    _logger.warn('Error on the /v2/listen message stream.', error);
  }

  // ---------------------------------------------------------------------
  // Teardown
  // ---------------------------------------------------------------------

  Future<void> _teardown() async {
    try {
      await _messagesSub?.cancel();
    } catch (_) {}
    _messagesSub = null;
    await _ws.dispose();
    await _closeControllers();
  }

  Future<void> _closeControllers() async {
    await _connectedController.close();
    await _turnInfoController.close();
    await _configureSuccessController.close();
    await _configureFailureController.close();
    await _warningsController.close();
    await _fatalErrorsController.close();
  }
}

// ---------------------------------------------------------------------------
// Defensive JSON helpers (library-private)
// ---------------------------------------------------------------------------

dynamic _tryDecode(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _stringMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map(
      (dynamic key, dynamic val) => MapEntry(key.toString(), val),
    );
  }
  return <String, dynamic>{};
}
