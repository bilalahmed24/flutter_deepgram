/// A self-healing WebSocket session for Deepgram streaming APIs.
///
/// This component ports the reliability engine of a production Flutter
/// Deepgram deployment:
///
/// * **Generation tokens** — every reconnect chain carries a generation
///   number. A superseded or explicitly-closed chain can never resurrect a
///   dead connection or clobber a newer one.
/// * **Failure classification** — a failed connect is classified as
///   Deepgram-definitive (the upgrade was refused over a working network
///   path), ambiguous (a peer answered, but a middlebox may be involved), or
///   internet-suspect (DNS / unreachable / timeout). Ambiguous and suspect
///   failures are *corroborated* with a fresh connectivity probe before the
///   SDK concludes the service is down.
/// * **Exponential backoff with jitter** — clamped between configurable
///   bounds so a fleet of clients doesn't reconnect in lockstep.
/// * **KeepAlive heartbeat** — a configurable JSON control message sent on
///   an interval (optionally only while idle), preventing Deepgram from
///   closing silent sessions.
/// * **Graceful close with drain** — an optional close control message
///   (e.g. `CloseStream`) followed by a bounded wait for the server to
///   finish flushing results.
library;

import 'dart:async';

import '../deepgram_auth.dart';
import '../deepgram_config.dart';
import '../deepgram_logger.dart';
import 'backoff_policy.dart';
import 'connectivity_probe.dart';
import 'ws_failure_classifier.dart';
import 'ws_factory.dart';

/// Lifecycle states of a [ResilientWebSocket].
enum WsConnectionState {
  /// Not yet connected.
  idle,

  /// A connection attempt is in flight.
  connecting,

  /// Connected and exchanging frames.
  open,

  /// Unexpectedly disconnected; reconnection attempts are underway.
  reconnecting,

  /// Closed by the user (or closed cleanly). Terminal.
  closed,

  /// Gave up after repeated failures. Terminal until
  /// [ResilientWebSocket.connect] is called again.
  failed,
}

/// A single inbound WebSocket frame.
class WsMessage {
  /// Creates a message wrapping raw [data] (`String` or `List<int>`).
  const WsMessage(this.data);

  /// Raw frame payload.
  final dynamic data;

  /// Whether this frame carries text.
  bool get isText => data is String;

  /// Whether this frame carries binary data.
  bool get isBinary => data is List<int>;

  /// The text payload, or `null` for binary frames.
  String? get text => data is String ? data as String : null;

  /// The binary payload, or `null` for text frames.
  List<int>? get bytes => data is List<int> ? data as List<int> : null;
}

/// Context handed to [ResilientWebSocketOptions.shouldReconnect] after an
/// unexpected disconnect or failed connect.
class WsCloseContext {
  /// Creates a close context.
  const WsCloseContext({
    this.closeCode,
    this.closeReason,
    this.error,
    required this.attempt,
    this.classification,
    this.internetUp,
  });

  /// WebSocket close code, when the server sent one.
  final int? closeCode;

  /// WebSocket close reason, when the server sent one.
  final String? closeReason;

  /// The underlying error for connect failures, when captured.
  final Object? error;

  /// 1-based reconnection attempt about to be scheduled.
  final int attempt;

  /// Classification of a failed connect attempt, when applicable.
  final WsFailureClassification? classification;

  /// Connectivity probe result at failure time, when a probe was performed.
  final bool? internetUp;
}

/// Context describing a scheduled reconnection.
class WsReconnectContext {
  /// Creates a reconnect context.
  const WsReconnectContext({
    required this.attempt,
    required this.nextDelay,
    this.classification,
    this.internetUp,
  });

  /// 1-based attempt number.
  final int attempt;

  /// How long the SDK will wait before retrying.
  final Duration nextDelay;

  /// Failure classification that led to this reconnect, when applicable.
  final WsFailureClassification? classification;

  /// Connectivity probe result at failure time, when performed.
  final bool? internetUp;
}

/// Tuning knobs for a [ResilientWebSocket].
class ResilientWebSocketOptions {
  /// Creates an options bundle.
  const ResilientWebSocketOptions({
    this.autoReconnect = true,
    this.maxReconnectAttempts = 0,
    this.keepAliveInterval = const Duration(seconds: 5),
    this.keepAliveMessage = '{"type":"KeepAlive"}',
    this.sendKeepAliveOnlyWhenIdle = false,
    this.minReconnectDelay = const Duration(seconds: 1),
    this.maxReconnectDelay = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 15),
    this.corroboratedFailureThreshold = 2,
    this.shouldReconnect,
    this.onReconnecting,
    this.onReconnected,
  });

  /// Whether the socket reconnects automatically after unexpected
  /// disconnects.
  final bool autoReconnect;

  /// Hard cap on reconnection attempts; `0` means unlimited.
  final int maxReconnectAttempts;

  /// Interval between application-level KeepAlive messages.
  final Duration keepAliveInterval;

  /// The KeepAlive control message sent on the interval.
  final String keepAliveMessage;

  /// When `true`, KeepAlive is only sent if no outbound traffic occurred
  /// recently (recommended for the Voice Agent API; the media streaming
  /// APIs accept unconditional keepalives).
  final bool sendKeepAliveOnlyWhenIdle;

  /// Lower bound for reconnect backoff.
  final Duration minReconnectDelay;

  /// Upper bound for reconnect backoff.
  final Duration maxReconnectDelay;

  /// Timeout for establishing each connection.
  final Duration connectTimeout;

  /// Consecutive corroborated failures (definitive failure + healthy
  /// internet) required before the SDK gives up and reports
  /// [WsConnectionState.failed].
  final int corroboratedFailureThreshold;

  /// Callback deciding whether to schedule another reconnect. Return
  /// `false` to give up. When `null`, the default policy applies: stop
  /// after [corroboratedFailureThreshold] consecutive definitive failures
  /// with a healthy internet probe (e.g. bad credentials); retry everything
  /// else indefinitely.
  final bool Function(WsCloseContext context)? shouldReconnect;

  /// Callback invoked before waiting out a backoff delay.
  final void Function(WsReconnectContext context)? onReconnecting;

  /// Callback invoked when a connection is (re)established after at least
  /// one failure. Use this to re-send protocol setup (e.g. agent Settings).
  final void Function()? onReconnected;
}

/// A resilient, auto-reconnecting WebSocket session.
class ResilientWebSocket {
  /// Creates a session for [uri].
  ResilientWebSocket({
    required Uri uri,
    required DeepgramConfig config,
    required DeepgramAuth auth,
    ResilientWebSocketOptions options = const ResilientWebSocketOptions(),
    WsFactory? wsFactory,
    ConnectivityProbe? probe,
    DeepgramLogger? logger,
  })  : _uri = uri,
        _auth = auth,
        _options = options,
        _factory = wsFactory ?? defaultWsFactory,
        _probe = probe ?? ConnectivityProbe(probeUrl: config.effectiveProbeUrl),
        _logger = logger ?? DeepgramLogger(),
        _backoff = BackoffPolicy(
          baseDelay: options.minReconnectDelay,
          maxDelay: options.maxReconnectDelay,
        );

  final Uri _uri;
  final DeepgramAuth _auth;
  final ResilientWebSocketOptions _options;
  final WsFactory _factory;
  final ConnectivityProbe _probe;
  final DeepgramLogger _logger;
  final BackoffPolicy _backoff;

  final StreamController<WsMessage> _messagesController =
      StreamController<WsMessage>.broadcast();
  final StreamController<WsConnectionState> _statesController =
      StreamController<WsConnectionState>.broadcast();

  /// Monotonically increasing generation token. Reconnect loops capture the
  /// token at start and bail out whenever it no longer matches — a newer
  /// [connect]/[close] call supersedes everything from an older chain.
  int _generation = 0;

  WsConnectionState _state = WsConnectionState.idle;
  int _reconnectAttempts = 0;
  int _corroboratedFailures = 0;
  DateTime? _connectedAt;
  DateTime? _lastOutboundAt;
  DateTime? _connectionLostAt;

  // Active connection state (guarded by generation checks).
  WsSocket? _activeSocket;
  StreamSubscription<dynamic>? _socketSub;
  Completer<void>? _socketDone;
  Timer? _keepAliveTimer;
  bool _userClosed = false;
  bool _disposed = false;

  /// The most recent socket, kept only so close code/reason can be read
  /// after an unexpected disconnect detaches [_activeSocket].
  WsSocket? _lastSocket;

  /// Inbound frames. Text frames arrive as [WsMessage.text]; binary frames
  /// as [WsMessage.bytes].
  Stream<WsMessage> get messages => _messagesController.stream;

  /// Connection state changes.
  Stream<WsConnectionState> get states => _statesController.stream;

  /// Current connection state.
  WsConnectionState get state => _state;

  /// Whether the socket is currently open.
  bool get isConnected => _state == WsConnectionState.open;

  /// 1-based count of reconnection attempts in the current episode;
  /// resets to 0 after a successful reconnect.
  int get reconnectAttempts => _reconnectAttempts;

  /// Wall clock (UTC) of the moment the current disconnect episode began,
  /// or `null` while connected. Anchors gap-recovery so buffered audio can
  /// be timestamped at the moment the connection was lost.
  DateTime? get connectionLostAt => _connectionLostAt;

  /// Wall clock (UTC) of the current connection, or `null`.
  DateTime? get connectedAt => _connectedAt;

  /// Whether the user explicitly closed this session.
  bool get isClosedByUser => _userClosed;

  /// Begins connecting. Safe to call again after a
  /// [WsConnectionState.failed] or [WsConnectionState.closed] state.
  ///
  /// Throws a [StateError] after [dispose].
  Future<void> connect() {
    if (_disposed) {
      throw StateError('This ResilientWebSocket has been disposed.');
    }
    if (_state == WsConnectionState.open ||
        _state == WsConnectionState.connecting ||
        _state == WsConnectionState.reconnecting) {
      return Future<void>.value();
    }
    _userClosed = false;
    // A brand-new session: reconnect bookkeeping from any previous episode
    // must not leak into this one (otherwise the first dial is reported as a
    // "reconnect" and fires [ResilientWebSocketOptions.onReconnected]).
    _reconnectAttempts = 0;
    _corroboratedFailures = 0;
    _setState(WsConnectionState.connecting);
    final generation = ++_generation;
    return _runLoop(generation);
  }

  /// Sends a text frame (silently ignored while disconnected — buffer at
  /// the call site if you need gap recovery).
  void send(String data) {
    _lastOutboundAt = DateTime.now();
    final socket = _activeSocket;
    if (socket == null) return;
    try {
      socket.add(data);
    } catch (e) {
      _logger.warn('Failed to send text frame: $e');
    }
  }

  /// Sends a binary frame (silently ignored while disconnected).
  void sendBytes(List<int> data) {
    _lastOutboundAt = DateTime.now();
    final socket = _activeSocket;
    if (socket == null) return;
    try {
      socket.add(data);
    } catch (e) {
      _logger.warn('Failed to send binary frame: $e');
    }
  }

  /// Gracefully closes the session.
  ///
  /// When [closeMessage] is provided (e.g. `{"type":"CloseStream"}`), it is
  /// sent first so the server can flush pending results; the method then
  /// waits up to [drainTimeout] (default 5 s) for the server to finish
  /// before closing the socket. Without [closeMessage] there is nothing to
  /// drain and the socket is torn down immediately.
  Future<void> close({
    String? closeMessage,
    Duration drainTimeout = const Duration(seconds: 5),
  }) async {
    if (_userClosed) return;
    _userClosed = true;
    // Kills every in-flight chain.
    ++_generation;
    // Stop the keepalive immediately: it must never fire after a close
    // control message (e.g. KeepAlive after CloseStream).
    _teardownKeepAlive();

    if (closeMessage != null) {
      final socket = _activeSocket;
      if (socket != null) {
        try {
          socket.add(closeMessage);
        } catch (_) {}
      }
      final done = _socketDone;
      if (done != null && !done.isCompleted) {
        try {
          await done.future.timeout(drainTimeout);
        } on TimeoutException {
          // Drain window elapsed — proceed with teardown.
        }
      }
    }

    await _teardownSocket();
    _setState(WsConnectionState.closed);
    _logger.debug('WebSocket closed by user.');
  }

  /// Immediately closes without draining. Use when abandoning the session.
  Future<void> forceClose() async {
    if (_userClosed && _state == WsConnectionState.closed) return;
    _userClosed = true;
    ++_generation;
    await _teardownSocket();
    _setState(WsConnectionState.closed);
  }

  /// Releases this object's streams. The socket is force-closed first.
  /// After disposal, [connect] throws a [StateError].
  Future<void> dispose() async {
    await forceClose();
    _disposed = true;
    if (!_messagesController.isClosed) await _messagesController.close();
    if (!_statesController.isClosed) await _statesController.close();
  }

  // -------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------

  Future<void> _runLoop(int generation) async {
    while (_generation == generation && !_userClosed) {
      try {
        await _connectOnce(generation);
        // _connectOnce returns only when the socket went down.
      } catch (error) {
        // Connect attempt failed — classify, corroborate, decide.
        final giveUp = await _handleConnectFailure(error, generation);
        if (giveUp) return;
        continue;
      }
      // Socket went down unexpectedly while we still own the generation.
      final giveUp = await _handleDisconnect(generation);
      if (giveUp) return;
    }
  }

  Future<void> _connectOnce(int generation) async {
    _teardownKeepAlive();
    _setState(_reconnectAttempts > 0
        ? WsConnectionState.reconnecting
        : WsConnectionState.connecting);
    final authHeader = await _auth.authorizationHeader();
    final socket = await _factory.connect(
      _uri,
      authorizationHeader: authHeader,
      connectTimeout: _options.connectTimeout,
    );
    if (_generation != generation || _userClosed) {
      // A newer chain took over while connecting — close the zombie socket.
      try {
        await socket.close();
      } catch (_) {}
      return;
    }
    _activeSocket = socket;
    _lastSocket = socket;
    _connectedAt = DateTime.now().toUtc();
    _corroboratedFailures = 0;

    final hadFailures = _reconnectAttempts > 0;
    final failureCount = _reconnectAttempts;
    _reconnectAttempts = 0;
    _connectionLostAt = null;
    _setState(WsConnectionState.open);
    _startKeepAlive();

    if (hadFailures) {
      _logger.info('Reconnected after $failureCount attempt(s).');
      _options.onReconnected?.call();
    } else {
      _logger.debug('WebSocket connected.');
    }

    // Pump frames until the socket closes. This future completes when the
    // socket stream is done (or errors, or is torn down).
    final done = Completer<void>();
    _socketDone = done;
    _socketSub = socket.stream.listen(
      (frame) {
        // Frames keep flowing until the subscription is torn down — this
        // includes the final flushed results delivered while a graceful
        // close() drains the socket.
        if (!_messagesController.isClosed) {
          _messagesController.add(WsMessage(frame));
        }
      },
      onError: (Object error) {
        _logger.warn('WebSocket stream error: $error');
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    await done.future;
  }

  /// Handles a failed connect attempt. Returns `true` when the loop should
  /// give up entirely.
  Future<bool> _handleConnectFailure(Object error, int generation) async {
    if (_generation != generation || _userClosed) return true;
    final classifier = WsFailureClassifier();
    final classification = classifier.classify(error);

    _connectionLostAt ??= DateTime.now().toUtc();
    _reconnectAttempts++;

    // Corroborate with a fresh probe at failure time — this is the evidence
    // that distinguishes "Deepgram is down / refused us" from "flaky
    // internet".
    final internetUp = await _probe.isInternetAvailable();

    bool corroboratedDefinitive = false;
    if (classification == WsFailureClassification.deepgramDefinitive &&
        internetUp) {
      _corroboratedFailures++;
      corroboratedDefinitive =
          _corroboratedFailures >= _options.corroboratedFailureThreshold;
    } else {
      _corroboratedFailures = 0;
    }

    _logger.warn(
      'Connect attempt $_reconnectAttempts failed '
      '(${classification.name}, internetUp: $internetUp).',
      error,
    );

    if (!_options.autoReconnect) {
      _setState(WsConnectionState.failed);
      return true;
    }
    if (_options.maxReconnectAttempts > 0 &&
        _reconnectAttempts >= _options.maxReconnectAttempts) {
      _setState(WsConnectionState.failed);
      return true;
    }

    final ctx = WsCloseContext(
      closeCode: null,
      closeReason: null,
      error: error,
      attempt: _reconnectAttempts,
      classification: classification,
      internetUp: internetUp,
    );

    final callback = _options.shouldReconnect;
    // Default policy: stop only on repeated definitive refusals with a
    // healthy internet (e.g. bad credentials); retry everything else.
    final policySaysStop =
        callback != null ? !callback(ctx) : corroboratedDefinitive;
    if (policySaysStop) {
      _logger.error(
        'Giving up after $_reconnectAttempts attempts '
        '($classification, internetUp: $internetUp).',
      );
      _setState(WsConnectionState.failed);
      return true;
    }

    final delay = _backoff.delayFor(_reconnectAttempts);
    _setState(WsConnectionState.reconnecting);
    _options.onReconnecting?.call(WsReconnectContext(
      attempt: _reconnectAttempts,
      nextDelay: delay,
      classification: classification,
      internetUp: internetUp,
    ));
    await Future<void>.delayed(delay);
    return _generation != generation || _userClosed;
  }

  /// Handles an unexpected disconnect after a successful connection.
  /// Returns `true` when the loop should give up.
  Future<bool> _handleDisconnect(int generation) async {
    if (_generation != generation || _userClosed) return true;
    _connectionLostAt = DateTime.now().toUtc();
    _teardownKeepAlive();
    // Detach the dead socket immediately: sends while `reconnecting` must
    // be dropped, not written into a stale connection.
    _activeSocket = null;
    _socketDone = null;

    final closeCode = _closeCodeOf(_lastSocket);
    final closeReason = _closeReasonOf(_lastSocket);
    _reconnectAttempts++;

    _logger.warn(
      'Connection lost (closeCode: $closeCode, closeReason: $closeReason). '
      'Attempt $_reconnectAttempts.',
    );

    if (!_options.autoReconnect) {
      _setState(WsConnectionState.failed);
      return true;
    }
    if (_options.maxReconnectAttempts > 0 &&
        _reconnectAttempts >= _options.maxReconnectAttempts) {
      _setState(WsConnectionState.failed);
      return true;
    }

    final ctx = WsCloseContext(
      closeCode: closeCode,
      closeReason: closeReason,
      attempt: _reconnectAttempts,
    );
    final callback = _options.shouldReconnect;
    if (callback != null && !callback(ctx)) {
      _setState(WsConnectionState.failed);
      return true;
    }

    final delay = _backoff.delayFor(_reconnectAttempts);
    _setState(WsConnectionState.reconnecting);
    _options.onReconnecting?.call(WsReconnectContext(
      attempt: _reconnectAttempts,
      nextDelay: delay,
    ));
    await Future<void>.delayed(delay);
    return _generation != generation || _userClosed;
  }

  void _startKeepAlive() {
    _teardownKeepAlive();
    if (_options.keepAliveInterval == Duration.zero) return;
    _keepAliveTimer = Timer.periodic(
      _options.keepAliveInterval,
      (_) {
        if (!_isSocketOpen()) return;
        if (_options.sendKeepAliveOnlyWhenIdle) {
          final last = _lastOutboundAt;
          final sinceLast =
              last == null ? null : DateTime.now().difference(last);
          // Recent outbound traffic already keeps the session alive.
          if (sinceLast != null && sinceLast < _options.keepAliveInterval) {
            return;
          }
        }
        send(_options.keepAliveMessage);
      },
    );
  }

  void _teardownKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  Future<void> _teardownSocket() async {
    _teardownKeepAlive();
    try {
      await _socketSub?.cancel();
    } catch (_) {}
    _socketSub = null;
    final socket = _activeSocket;
    _activeSocket = null;
    _connectedAt = null;
    final done = _socketDone;
    _socketDone = null;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
    if (socket != null) {
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  bool _isSocketOpen() =>
      _state == WsConnectionState.open && _activeSocket != null;

  int? _closeCodeOf(WsSocket? socket) {
    try {
      return socket?.closeCode;
    } catch (_) {
      return null;
    }
  }

  String? _closeReasonOf(WsSocket? socket) {
    try {
      return socket?.closeReason;
    } catch (_) {
      return null;
    }
  }

  void _setState(WsConnectionState state) {
    if (_state == state) return;
    _state = state;
    if (!_statesController.isClosed) {
      _statesController.add(state);
    }
  }
}
