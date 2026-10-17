/// Live (streaming) speech-to-text client for `/v1/listen`.
///
/// The session is backed by the SDK's [ResilientWebSocket]: it survives
/// disconnects with classified failures, exponential backoff, and KeepAlive
/// heartbeats. On top of that, the client ports the production gap-recovery
/// pattern: audio sent while disconnected is buffered, and on reconnection
/// small gaps are flushed straight into the new socket while large gaps are
/// recovered in parallel through the pre-recorded HTTPS API — anchored at the
/// disconnect instant so the recovered transcript keeps its true position in
/// the timeline.
///
/// ```dart
/// final live = deepgram.createLiveClient(
///   options: const LiveTranscriptionOptions(smartFormat: true),
/// );
/// live.results.listen((result) => print(result.transcript));
/// await live.start();
/// live.sendAudio(chunk);
/// await live.close();
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
import '../stt_models.dart';
import 'live_models.dart';
import 'live_options.dart';

/// A live transcription session over `wss://api.deepgram.com/v1/listen`.
class DeepgramLiveClient {
  /// Creates a session. Call [start] to connect.
  DeepgramLiveClient({
    required DeepgramConfig config,
    required DeepgramAuth auth,
    required HttpEngine http,
    LiveTranscriptionOptions? options,
    ResilientWebSocketOptions? wsOptions,
    this.gapRecovery = const LiveGapRecoveryOptions(),
    DeepgramLogger? logger,
  })  : _http = http,
        _options = options,
        _logger = logger ?? DeepgramLogger() {
    _ws = ResilientWebSocket(
      uri: config.wsUri('/v1/listen', options?.toQuery()),
      config: config,
      auth: auth,
      options: _composeWsOptions(wsOptions),
      logger: _logger,
    );
    _messagesSub = _ws.messages.listen(
      _handleMessage,
      onError: _handleStreamError,
    );
    _statesSub = _ws.states.listen(_handleState);
  }

  /// HTTP engine, used only for large-gap HTTPS recovery.
  final HttpEngine _http;

  /// The options this session was created with.
  final LiveTranscriptionOptions? _options;

  /// Logger for this session.
  final DeepgramLogger _logger;

  /// Gap-recovery behaviour for disconnects.
  final LiveGapRecoveryOptions gapRecovery;

  late final ResilientWebSocket _ws;
  StreamSubscription<WsMessage>? _messagesSub;
  StreamSubscription<WsConnectionState>? _statesSub;

  final StreamController<LiveTranscriptionResult> _resultsController =
      StreamController<LiveTranscriptionResult>.broadcast();
  final StreamController<LiveMetadataMessage> _metadataController =
      StreamController<LiveMetadataMessage>.broadcast();
  final StreamController<LiveUtteranceEnd> _utteranceEndsController =
      StreamController<LiveUtteranceEnd>.broadcast();
  final StreamController<LiveSpeechStarted> _speechStartedController =
      StreamController<LiveSpeechStarted>.broadcast();
  final StreamController<LiveErrorMessage> _errorsController =
      StreamController<LiveErrorMessage>.broadcast();
  final StreamController<LiveTranscriptionResult> _recoveredResultsController =
      StreamController<LiveTranscriptionResult>.broadcast();

  bool _closed = false;
  bool _hadOpenConnection = false;
  bool _recoveryInFlight = false;
  Future<void> _recoveryChain = Future<void>.value();

  /// Cancellation tokens for in-flight HTTPS gap-recovery uploads; all
  /// cancelled by [forceClose].
  final Set<HttpCancelToken> _activeRecoveryTokens = {};
  List<List<int>> _gapBuffer = <List<int>>[];
  int _gapBufferLength = 0;
  DateTime? _gapAnchorUtc;

  // ---------------------------------------------------------------------
  // Event streams
  // ---------------------------------------------------------------------

  /// Interim and final transcription results.
  Stream<LiveTranscriptionResult> get results => _resultsController.stream;

  /// The final `Metadata` summary flushed after `CloseStream`.
  Stream<LiveMetadataMessage> get metadata => _metadataController.stream;

  /// Utterance-end events (requires `utterance_end_ms`).
  Stream<LiveUtteranceEnd> get utteranceEnds => _utteranceEndsController.stream;

  /// Speech-started events (requires `vad_events`).
  Stream<LiveSpeechStarted> get speechStarted =>
      _speechStartedController.stream;

  /// Non-fatal server error messages and frames the SDK could not parse.
  Stream<LiveErrorMessage> get errors => _errorsController.stream;

  /// Results recovered from disconnect gaps (marked `recovered` and anchored
  /// at the disconnect instant). They are NOT repeated on [results].
  Stream<LiveTranscriptionResult> get recoveredResults =>
      _recoveredResultsController.stream;

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
        'This live transcription session has already been closed.',
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
        'The /v1/listen WebSocket connection failed to open (gave up after '
        'retries or was closed while connecting).',
      );
    }
  }

  /// Sends a chunk of audio.
  ///
  /// While connected, the bytes go straight to the socket. While
  /// disconnected and gap recovery is enabled, the bytes are buffered (up to
  /// [LiveGapRecoveryOptions.maxBufferBytes]; newer audio is dropped with a
  /// logged warning once the cap is hit) and recovered on reconnection.
  void sendAudio(List<int> bytes) {
    if (_closed || bytes.isEmpty) return;
    if (_ws.isConnected) {
      _ws.sendBytes(bytes);
      return;
    }
    if (!gapRecovery.enabled) return;
    if (_gapBufferLength + bytes.length > gapRecovery.maxBufferBytes) {
      _logger.warn(
        'Live gap buffer is full ($_gapBufferLength bytes buffered); '
        'dropping a new ${bytes.length}-byte chunk — transcript for this '
        'part of the outage window will be lost.',
      );
      return;
    }
    _gapAnchorUtc ??= DateTime.now().toUtc();
    _gapBuffer.add(bytes);
    _gapBufferLength += bytes.length;
  }

  /// Sends a `Finalize` message, flushing pending results without closing
  /// the stream.
  Future<void> finish() async {
    if (_closed) return;
    _ws.send('{"type":"Finalize"}');
  }

  /// Sends a `Configure` message, updating keyterms and formatting features
  /// mid-stream. Null fields are omitted; a field set to an empty list
  /// clears the current keyterms.
  Future<void> configure({
    List<String>? keyterms,
    Map<String, bool>? features,
  }) async {
    if (_closed) return;
    if (keyterms == null && features == null) return;
    final payload = <String, dynamic>{'type': 'Configure'};
    if (keyterms != null) {
      payload['keyterms'] = keyterms;
    }
    if (features != null) {
      payload['features'] = features;
    }
    _ws.send(jsonEncode(payload));
  }

  /// Gracefully closes the session: sends `CloseStream`, waits up to five
  /// seconds for the server to flush final results (still delivered through
  /// [results] and [metadata] during the drain), then tears everything down.
  /// Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _ws.close(
        closeMessage: '{"type":"CloseStream"}',
        drainTimeout: const Duration(seconds: 5),
      );
      // Bounded wait for in-flight HTTPS gap recoveries so their
      // transcripts are delivered before the streams close (production
      // pattern: bounded wait at graceful close).
      if (_recoveryInFlight) {
        try {
          await _recoveryChain.timeout(gapRecovery.maxCloseWait);
        } on TimeoutException {
          _logger.warn(
            'Gap recovery still running after '
            '${gapRecovery.maxCloseWait.inSeconds}s at close; proceeding.',
          );
        }
      }
    } finally {
      await _teardown();
    }
  }

  /// Immediately closes without draining. Use when abandoning the session.
  /// Any in-flight HTTPS gap-recovery upload is cancelled. Idempotent.
  Future<void> forceClose() async {
    if (_closed) return;
    _closed = true;
    for (final token in List<HttpCancelToken>.of(_activeRecoveryTokens)) {
      token.cancel('session force-closed');
    }
    _activeRecoveryTokens.clear();
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
    // /v1/listen never sends binary frames; ignore them defensively.
    if (message.isBinary) return;
    final text = message.text;
    if (text == null || text.isEmpty) return;
    final decoded = _tryDecode(text);
    if (decoded == null) {
      _emitError(LiveErrorMessage(
        variant: 'ParseError',
        description: 'Received a frame that is not valid JSON.',
        message: text,
      ));
      return;
    }
    if (decoded is! Map) {
      _emitError(LiveErrorMessage(
        variant: 'ParseError',
        description: 'Received a frame that is not a JSON object.',
        message: text,
      ));
      return;
    }
    final frame = _stringMap(decoded);
    final rawType = frame['type'];
    if (rawType is! String) {
      _emitError(LiveErrorMessage(
        variant: 'ParseError',
        description: 'Received a frame without a message type.',
        message: text,
      ));
      return;
    }
    switch (rawType) {
      case 'Results':
        _emitParsed(
          () => LiveTranscriptionResult.fromJson(frame),
          _resultsController,
          'Results',
          text,
        );
        break;
      case 'Metadata':
        _emitParsed(
          () => LiveMetadataMessage.fromJson(frame),
          _metadataController,
          'Metadata',
          text,
        );
        break;
      case 'UtteranceEnd':
        _emitParsed(
          () => LiveUtteranceEnd.fromJson(frame),
          _utteranceEndsController,
          'UtteranceEnd',
          text,
        );
        break;
      case 'SpeechStarted':
        _emitParsed(
          () => LiveSpeechStarted.fromJson(frame),
          _speechStartedController,
          'SpeechStarted',
          text,
        );
        break;
      case 'Error':
        _emitParsed(
          () => LiveErrorMessage.fromJson(frame),
          _errorsController,
          'Error',
          text,
        );
        break;
      default:
        _logger.debug('Ignoring unknown message type from /v1/listen: '
            '$rawType');
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
      _logger.warn('Malformed $type message from /v1/listen.', error);
      _emitError(LiveErrorMessage(
        variant: 'ParseError',
        description: 'Malformed $type message from /v1/listen.',
        message: raw,
      ));
    }
  }

  void _emitError(LiveErrorMessage error) {
    if (!_errorsController.isClosed) _errorsController.add(error);
  }

  void _handleStreamError(Object error) {
    _logger.warn('Error on the /v1/listen message stream.', error);
  }

  // ---------------------------------------------------------------------
  // Gap recovery
  // ---------------------------------------------------------------------

  /// Composes the effective socket options: every user setting is forwarded,
  /// and `onReconnected` is wrapped so the gap buffer is harvested right
  /// after every successful reconnection.
  ResilientWebSocketOptions _composeWsOptions(
    ResilientWebSocketOptions? userOptions,
  ) {
    final base = userOptions ?? const ResilientWebSocketOptions();
    final userOnReconnected = base.onReconnected;
    return ResilientWebSocketOptions(
      autoReconnect: base.autoReconnect,
      maxReconnectAttempts: base.maxReconnectAttempts,
      keepAliveInterval: base.keepAliveInterval,
      keepAliveMessage: base.keepAliveMessage,
      sendKeepAliveOnlyWhenIdle: base.sendKeepAliveOnlyWhenIdle,
      minReconnectDelay: base.minReconnectDelay,
      maxReconnectDelay: base.maxReconnectDelay,
      connectTimeout: base.connectTimeout,
      corroboratedFailureThreshold: base.corroboratedFailureThreshold,
      shouldReconnect: base.shouldReconnect,
      onReconnecting: base.onReconnecting,
      onReconnected: () {
        userOnReconnected?.call();
        _recoverGap();
      },
    );
  }

  void _handleState(WsConnectionState state) {
    if (state == WsConnectionState.reconnecting ||
        state == WsConnectionState.failed) {
      // Stamp the disconnect anchor. First write wins, so the anchor stays
      // at the true moment the connection was lost across the whole
      // reconnect episode (including a later manual restart).
      _gapAnchorUtc ??= DateTime.now().toUtc();
      return;
    }
    if (state == WsConnectionState.open) {
      if (_gapBuffer.isEmpty) {
        // Nothing buffered for this episode — clean the anchor for the next.
        _gapAnchorUtc = null;
        _hadOpenConnection = true;
        return;
      }
      if (!_hadOpenConnection) {
        // Audio buffered before the very first connect: `onReconnected`
        // does not fire for the initial connection, so flush from here.
        _hadOpenConnection = true;
        _recoverGap();
      }
      // Reconnects are handled by the composed `onReconnected` hook, which
      // the socket invokes right after entering the open state.
    }
  }

  /// Takes (and clears) the gap buffer and dispatches it: small gaps are
  /// flushed straight into the live socket, large gaps go to the HTTPS
  /// pre-recorded API. Never blocks and never throws.
  void _recoverGap() {
    if (!gapRecovery.enabled) return;
    if (_gapBuffer.isEmpty) return;
    final chunks = _gapBuffer;
    final byteCount = _gapBufferLength;
    _gapBuffer = <List<int>>[];
    _gapBufferLength = 0;
    final anchor = _gapAnchorUtc ?? DateTime.now().toUtc();
    _gapAnchorUtc = null;

    if (byteCount <= gapRecovery.maxLiveFlushBytes) {
      _logger.info(
        'Flushing $byteCount buffered audio bytes into the reconnected '
        'socket.',
      );
      for (final chunk in chunks) {
        _ws.sendBytes(chunk);
      }
      return;
    }

    if (_recoveryInFlight) {
      _logger.info(
        'A large-gap HTTPS recovery is already running; the new gap '
        '($byteCount bytes) is queued behind it.',
      );
    }
    // Large gap: recover through the pre-recorded HTTPS API IN PARALLEL with
    // live transcription. Recoveries are serialized on a chain so concurrent
    // disconnect episodes never interleave; each carries its own anchor.
    final gap = <int>[for (final chunk in chunks) ...chunk];
    _recoveryChain = _recoveryChain
        .then((_) => _recoverGapViaHttps(gap, anchor))
        .catchError((Object error) {
      _logger.warn('Unexpected failure in the gap-recovery chain.', error);
    });
  }

  Future<void> _recoverGapViaHttps(List<int> gap, DateTime anchorUtc) async {
    _recoveryInFlight = true;
    // Per-recovery cancellation token — cancelled by forceClose so a
    // forceful teardown never leaves an upload running (production
    // pattern: cancellation tokens per HTTPS recovery).
    final cancelToken = HttpCancelToken();
    _activeRecoveryTokens.add(cancelToken);
    try {
      final response = await _http.postAudio(
        '/v1/listen',
        audio: gap,
        contentType: _gapContentType(),
        query: _gapQuery(),
        cancelToken: cancelToken,
      );
      _emitRecoveredResults(response.body, anchorUtc);
      _logger.info(
        'HTTPS gap recovery complete (${gap.length} bytes, anchored at '
        '${anchorUtc.toIso8601String()}).',
      );
    } catch (error) {
      // Transcript loss equals the Deepgram-down window — same trade-off as
      // the production service this pattern was ported from.
      _logger.warn(
        'HTTPS gap recovery failed (${gap.length} bytes); transcript for '
        'the outage window is lost.',
        error,
      );
    } finally {
      _activeRecoveryTokens.remove(cancelToken);
      _recoveryInFlight = false;
    }
  }

  /// The content type for gap uploads: an explicit override, else
  /// `audio/raw;rate=<sampleRate>` for raw streams, else `audio/wav`.
  String _gapContentType() {
    final override = gapRecovery.audioContentType;
    if (override != null && override.isNotEmpty) return override;
    final options = _options;
    if (options != null &&
        options.encoding != null &&
        options.sampleRate != null) {
      return 'audio/raw;rate=${options.sampleRate}';
    }
    return 'audio/wav';
  }

  /// The query for the gap recovery call: the session query minus the
  /// streaming-only parameters the pre-recorded REST API does not accept
  /// (`channels` is a streaming-only channel-count hint and is rejected by
  /// REST, which uses `multichannel` instead).
  Map<String, dynamic> _gapQuery() {
    final query = _options?.toQuery() ?? <String, dynamic>{};
    query
      ..remove('interim_results')
      ..remove('endpointing')
      ..remove('utterance_end_ms')
      ..remove('vad_events')
      ..remove('channels');
    return query;
  }

  /// Parses a pre-recorded REST response into recovered results, one per
  /// channel, and emits each on [recoveredResults]. Late arrivals after the
  /// session was torn down are dropped silently.
  void _emitRecoveredResults(Map<String, dynamic> body, DateTime anchorUtc) {
    if (_recoveredResultsController.isClosed) return;
    try {
      final results = body['results'];
      if (results is! Map) return;
      final channels = results['channels'];
      if (channels is! List) return;
      final metaMap = _stringMap(body['metadata']);
      final duration = _asDouble(metaMap['duration'], 0);
      final metadata = SttMetadata.fromJson(metaMap);
      for (var i = 0; i < channels.length; i++) {
        final channel = channels[i];
        if (channel is! Map) continue;
        final channelMap = _stringMap(channel);
        final alternatives = <SttAlternative>[];
        final rawAlternatives = channelMap['alternatives'];
        if (rawAlternatives is List) {
          for (final item in rawAlternatives) {
            if (item is! Map) continue;
            try {
              alternatives.add(SttAlternative.fromJson(_stringMap(item)));
            } catch (_) {
              // Skip a malformed alternative.
            }
          }
        }
        if (alternatives.isEmpty) continue;
        final recovered = LiveTranscriptionResult(
          alternatives: alternatives,
          channelIndex: <int>[i],
          duration: duration,
          start: 0,
          isFinal: true,
          speechFinal: true,
          metadata: metadata,
          recovered: true,
          recoveredAtUtc: anchorUtc,
        );
        if (!_recoveredResultsController.isClosed) {
          _recoveredResultsController.add(recovered);
        }
      }
    } catch (error) {
      _logger.warn(
        'Failed to interpret the gap-recovery response; recovered transcript '
        'for the outage window is unavailable.',
        error,
      );
    }
  }

  // ---------------------------------------------------------------------
  // Teardown
  // ---------------------------------------------------------------------

  Future<void> _teardown() async {
    try {
      await _messagesSub?.cancel();
      await _statesSub?.cancel();
    } catch (_) {}
    _messagesSub = null;
    _statesSub = null;
    await _ws.dispose();
    await _closeControllers();
  }

  Future<void> _closeControllers() async {
    await _resultsController.close();
    await _metadataController.close();
    await _utteranceEndsController.close();
    await _speechStartedController.close();
    await _errorsController.close();
    await _recoveredResultsController.close();
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

double _asDouble(dynamic value, double fallback) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}
