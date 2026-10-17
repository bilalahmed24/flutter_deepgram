/// Thorough unit tests for [ResilientWebSocket], the reconnect state machine
/// at the heart of the SDK's streaming clients.
///
/// Conventions:
/// * Every timing knob (backoff, keepalive, drain) is 1–50 ms.
/// * No network: sockets and probes are fakes. [FakeWsFactory] scripts
///   connect outcomes; [_ScriptedWsFactory] covers delayed dials, permanent
///   failures and non-[FakeWsSocket] sockets.
/// * Every wait is event-driven with a hard 4 s deadline (see [_eventually]),
///   so a regression fails fast instead of hanging the suite.
/// * connect() resolves only when the whole session ends, so tests either
///   `unawaited(ws.connect())` and await state transitions (the documented
///   usage pattern), or hold the session future and await it once a terminal
///   state (failed/closed) has been observed.
library;

import 'dart:async';
import 'dart:io' show WebSocketException;

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:test/test.dart';

import 'helpers/fake_ws.dart';
import 'helpers/fakes.dart';

final Uri _listenUri = Uri.parse('wss://api.deepgram.com/v1/listen');

/// Short drain window used whenever a test closes a still-open fake socket
/// (the default 5 s drain would stall every close on a socket that never
/// ends its stream by itself).
const Duration _drain = Duration(milliseconds: 30);

const Duration _deadline = Duration(seconds: 4);
const Duration _tick = Duration(milliseconds: 2);

/// Fast defaults: heartbeat effectively off, tiny backoff, 250 ms connect
/// budget delegated to the factory.
const ResilientWebSocketOptions _fastOptions = ResilientWebSocketOptions(
  keepAliveInterval: Duration(minutes: 30),
  minReconnectDelay: Duration(milliseconds: 5),
  maxReconnectDelay: Duration(milliseconds: 50),
  connectTimeout: Duration(milliseconds: 250),
);

ResilientWebSocket _makeWs(
  WsFactory factory, {
  ConnectivityProbe? probe,
  DeepgramLogger? logger,
  ResilientWebSocketOptions options = _fastOptions,
  DeepgramConfig config = testConfig,
}) {
  final ws = ResilientWebSocket(
    uri: _listenUri,
    config: config,
    auth: DeepgramAuth(config),
    wsFactory: factory,
    probe: probe ?? FakeProbe(),
    logger: logger,
    options: options,
  );
  addTearDown(ws.dispose);
  return ws;
}

/// Polls [condition] every [_tick] until it holds, failing after
/// [_deadline] with [description].
Future<void> _eventually(bool Function() condition, String description) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed >= _deadline) {
      fail('Timed out waiting for $description.');
    }
    await Future<void>.delayed(_tick);
  }
}

/// Lets one event-loop turn pass so that broadcast stream events added just
/// before an awaited future completed (e.g. the final `closed` emission
/// inside close()) reach the recorded listener lists.
Future<void> _flush() => Future<void>.delayed(Duration.zero);

/// Waits until the session's current state equals [expected]. Only used for
/// states that are stable once reached; transient states are asserted through
/// the recorded emission list ([_recordStates]) which never misses an event.
Future<void> _becomes(ResilientWebSocket ws, WsConnectionState expected) =>
    _eventually(() => ws.state == expected, 'state to become ${expected.name}');

/// Records every state emission for sequence assertions.
List<WsConnectionState> _recordStates(ResilientWebSocket ws) {
  final states = <WsConnectionState>[];
  final sub = ws.states.listen(states.add);
  addTearDown(sub.cancel);
  return states;
}

/// Records every inbound frame.
List<WsMessage> _recordMessages(ResilientWebSocket ws) {
  final messages = <WsMessage>[];
  final sub = ws.messages.listen(messages.add);
  addTearDown(sub.cancel);
  return messages;
}

/// A probe that counts how often the session corroborated a failure.
class _CountingProbe extends FakeProbe {
  int calls = 0;

  @override
  Future<bool> isInternetAvailable() async {
    calls++;
    return super.isInternetAvailable();
  }
}

/// A [WsFactory] whose outcomes are fully scripted.
///
/// [script] entries are consumed in order: a [WsSocket] entry is delivered,
/// anything else is thrown. Once the script runs dry a fresh [FakeWsSocket]
/// is delivered. [alwaysThrow] (when set) fails every dial, and [delay]
/// parks each dial before it resolves — used to race the dial against a
/// close()/connect() from the test.
class _ScriptedWsFactory implements WsFactory {
  _ScriptedWsFactory({
    List<Object> script = const <Object>[],
    this.delay = Duration.zero,
    this.alwaysThrow,
  }) : _script = List<Object>.of(script);

  final List<Object> _script;
  final Duration delay;
  final Object? alwaysThrow;
  int connectCalls = 0;

  @override
  Future<WsSocket> connect(
    Uri uri, {
    required String authorizationHeader,
    required Duration connectTimeout,
  }) async {
    connectCalls++;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final forced = alwaysThrow;
    if (forced != null) throw forced;
    if (_script.isEmpty) return FakeWsSocket();
    final entry = _script.removeAt(0);
    if (entry is WsSocket) return entry;
    throw entry;
  }
}

/// A [WsSocket] the test can break in three ways: its inbound stream can be
/// failed with an error (the session must treat that as a disconnect), its
/// close-code getters can throw (exercising the session's defensive
/// try/catch), and [close] itself can fail (exercising teardown tolerance).
class _FlakyWsSocket implements WsSocket {
  final StreamController<dynamic> _inbound =
      StreamController<dynamic>.broadcast();
  final List<Object> sent = [];

  /// When true, [closeCode] and [closeReason] throw.
  bool hideCloseInfo = false;

  /// When true, [close] throws.
  bool throwOnClose = false;

  @override
  Stream<dynamic> get stream => _inbound.stream;

  @override
  Future<void> get ready => Completer<void>().future;

  @override
  void add(Object data) => sent.add(data);

  @override
  Future<void> close() async {
    if (throwOnClose) throw StateError('close failed');
    if (!_inbound.isClosed) {
      await _inbound.close();
    }
  }

  @override
  int? get closeCode {
    if (hideCloseInfo) throw StateError('close code unavailable');
    return null;
  }

  @override
  String? get closeReason {
    if (hideCloseInfo) throw StateError('close reason unavailable');
    return null;
  }

  /// Fails the inbound stream; the session treats this as a disconnect.
  void fail(Object error) {
    if (!_inbound.isClosed) {
      _inbound.addError(error);
    }
  }
}

void main() {
  group('value types', () {
    test('WsMessage accessors distinguish text and binary payloads', () {
      const text = WsMessage('{"type":"Welcome"}');
      expect(text.isText, isTrue);
      expect(text.isBinary, isFalse);
      expect(text.text, '{"type":"Welcome"}');
      expect(text.bytes, isNull);

      const binary = WsMessage(<int>[1, 2, 3]);
      expect(binary.isText, isFalse);
      expect(binary.isBinary, isTrue);
      expect(binary.bytes, <int>[1, 2, 3]);
      expect(binary.text, isNull);

      const other = WsMessage(42);
      expect(other.isText, isFalse);
      expect(other.isBinary, isFalse);
      expect(other.text, isNull);
      expect(other.bytes, isNull);
    });

    test('WsCloseContext and WsReconnectContext expose their fields', () {
      final error = Exception('upgrade refused by edge');
      final closeCtx = WsCloseContext(
        closeCode: 1011,
        closeReason: 'internal error',
        error: error,
        attempt: 3,
        classification: WsFailureClassification.internetSuspect,
        internetUp: false,
      );
      expect(closeCtx.closeCode, 1011);
      expect(closeCtx.closeReason, 'internal error');
      expect(closeCtx.error, same(error));
      expect(closeCtx.attempt, 3);
      expect(closeCtx.classification, WsFailureClassification.internetSuspect);
      expect(closeCtx.internetUp, isFalse);

      const reconnectCtx = WsReconnectContext(
        attempt: 2,
        nextDelay: Duration(milliseconds: 5),
        classification: WsFailureClassification.ambiguous,
        internetUp: true,
      );
      expect(reconnectCtx.attempt, 2);
      expect(reconnectCtx.nextDelay, const Duration(milliseconds: 5));
      expect(reconnectCtx.classification, WsFailureClassification.ambiguous);
      expect(reconnectCtx.internetUp, isTrue);
    });
  });

  group('happy path', () {
    test(
      'connect opens the session, authenticates, and round-trips frames',
      () async {
        final factory = FakeWsFactory();
        final socket = factory.enqueueSocket();
        final ws = _makeWs(factory);
        final states = _recordStates(ws);
        final received = _recordMessages(ws);

        expect(ws.state, WsConnectionState.idle);
        expect(ws.isConnected, isFalse);
        expect(ws.reconnectAttempts, 0);
        expect(ws.isClosedByUser, isFalse);

        final session = ws.connect();
        await _becomes(ws, WsConnectionState.open);

        // The factory saw the URI, the API-key auth header and the configured
        // connect budget.
        expect(factory.connectCalls, 1);
        expect(factory.uris.single, _listenUri);
        expect(factory.authorizationHeaders.single, 'Token test-api-key');
        expect(
          factory.connectTimeouts.single,
          const Duration(milliseconds: 250),
        );

        expect(ws.isConnected, isTrue);
        expect(ws.connectedAt, isNotNull);
        expect(ws.connectedAt!.isUtc, isTrue);
        expect(ws.connectionLostAt, isNull);

        // Inbound round-trip: text and binary frames with typed accessors.
        socket.emit('{"type":"Metadata"}');
        socket.emit(<int>[1, 2, 3]);
        await _eventually(() => received.length == 2, 'both frames delivered');
        expect(received.first.isText, isTrue);
        expect(received.first.text, '{"type":"Metadata"}');
        expect(received.first.bytes, isNull);
        expect(received.last.isBinary, isTrue);
        expect(received.last.bytes, <int>[1, 2, 3]);
        expect(received.last.text, isNull);

        // Outbound round-trip: text and binary frames.
        ws.send('hello');
        ws.sendBytes(<int>[9, 9]);
        expect(
          socket.sent,
          containsAll(<Object>[
            'hello',
            <int>[9, 9],
          ]),
        );

        // connect() while already open resolves immediately (guarded no-op).
        await ws.connect().timeout(_deadline);

        await ws.close(drainTimeout: _drain);
        await session.timeout(_deadline);
        await _flush();

        expect(ws.state, WsConnectionState.closed);
        expect(ws.isClosedByUser, isTrue);
        expect(ws.isConnected, isFalse);
        expect(ws.connectedAt, isNull);
        expect(
          states,
          containsAllInOrder(<WsConnectionState>[
            WsConnectionState.connecting,
            WsConnectionState.open,
            WsConnectionState.closed,
          ]),
        );

        // Sends after close are silent no-ops: nothing reaches the retired
        // socket and nothing throws.
        final sentLength = socket.sent.length;
        ws.send('after-close');
        ws.sendBytes(<int>[7]);
        expect(socket.sent, hasLength(sentLength));
      },
    );

    test('uses Bearer auth when the config carries a JWT', () async {
      final factory = FakeWsFactory();
      factory.enqueueSocket();
      const config = DeepgramConfig(jwt: 'jwt-abc');
      final ws = _makeWs(factory, config: config);

      unawaited(ws.connect());
      await _becomes(ws, WsConnectionState.open);
      expect(factory.authorizationHeaders.single, 'Bearer jwt-abc');

      await ws.close(drainTimeout: _drain);
    });

    test('send and sendBytes while disconnected are silent no-ops', () async {
      final factory = FakeWsFactory();
      final ws = _makeWs(factory);

      // Never connected: nothing throws and no dial is made.
      ws.send('hello');
      ws.sendBytes(<int>[1, 2]);
      await Future<void>.delayed(_tick);
      expect(factory.connectCalls, 0);
      expect(ws.state, WsConnectionState.idle);

      // After a full session: no frames reach the retired socket.
      final socket = factory.enqueueSocket();
      unawaited(ws.connect());
      await _becomes(ws, WsConnectionState.open);
      await ws.close(drainTimeout: _drain);

      final sentLength = socket.sent.length;
      ws.send('late');
      ws.sendBytes(<int>[3]);
      expect(socket.sent, hasLength(sentLength));
    });

    test('falls back to the default factory and real probe when none are '
        'injected', () async {
      // Construction only: the default WsFactory (IoWsFactory on VM) and the
      // real ConnectivityProbe are built lazily — nothing touches the
      // network until connect() is called, and this test never connects.
      final ws = ResilientWebSocket(
        uri: _listenUri,
        config: testConfig,
        auth: DeepgramAuth(testConfig),
        options: _fastOptions,
      );
      addTearDown(ws.dispose);

      expect(ws.state, WsConnectionState.idle);
      expect(ws.isConnected, isFalse);

      await ws.close(drainTimeout: _drain);
      expect(ws.state, WsConnectionState.closed);
    });

    test(
      'connectTimeout is delegated to the factory; readiness is not awaited',
      () async {
        final factory = FakeWsFactory();
        // This fake socket's `ready` never completes.
        final socket = factory.enqueueSocket();
        final ws = _makeWs(factory);

        unawaited(ws.connect());
        await _becomes(ws, WsConnectionState.open);
        expect(
          factory.connectTimeouts.single,
          const Duration(milliseconds: 250),
        );

        // The session layer treats the socket returned by the factory as live:
        // handshake timeouts belong to the factory (IoWsFactory awaits `ready`
        // with the same budget), not to the session's run loop.
        expect(ws.isConnected, isTrue);
        ws.send('hi');
        expect(socket.sent, contains('hi'));

        await ws.close(drainTimeout: _drain);
      },
    );
  });

  group('keepalive heartbeat', () {
    test('is sent on the timer with the default KeepAlive JSON', () async {
      final factory = FakeWsFactory();
      final socket = factory.enqueueSocket();
      final ws = _makeWs(
        factory,
        options: const ResilientWebSocketOptions(
          keepAliveInterval: Duration(milliseconds: 20),
          minReconnectDelay: Duration(milliseconds: 5),
          maxReconnectDelay: Duration(milliseconds: 50),
          connectTimeout: Duration(milliseconds: 250),
        ),
      );

      unawaited(ws.connect());
      await _becomes(ws, WsConnectionState.open);

      // Timer.periodic: at least two heartbeats within the deadline.
      await _eventually(
        () =>
            socket.sent
                .where((Object s) => s == '{"type":"KeepAlive"}')
                .length >=
            2,
        'at least two KeepAlive frames',
      );

      await ws.close(drainTimeout: _drain);
    });

    test('fires when idle-only and nothing was ever sent', () async {
      final factory = FakeWsFactory();
      final socket = factory.enqueueSocket();
      final ws = _makeWs(
        factory,
        options: const ResilientWebSocketOptions(
          keepAliveInterval: Duration(milliseconds: 20),
          sendKeepAliveOnlyWhenIdle: true,
          minReconnectDelay: Duration(milliseconds: 5),
          maxReconnectDelay: Duration(milliseconds: 50),
          connectTimeout: Duration(milliseconds: 250),
        ),
      );

      unawaited(ws.connect());
      await _becomes(ws, WsConnectionState.open);

      // No outbound traffic at all: the idle-only gate still lets the very
      // first heartbeat through.
      await _eventually(
        () => socket.sent.contains('{"type":"KeepAlive"}'),
        'heartbeat with no prior outbound traffic',
      );

      await ws.close(drainTimeout: _drain);
    });

    test(
      'is suppressed by user traffic when sendKeepAliveOnlyWhenIdle',
      () async {
        final factory = FakeWsFactory();
        final socket = factory.enqueueSocket();
        const ping = '{"type":"Ping"}';
        final ws = _makeWs(
          factory,
          options: const ResilientWebSocketOptions(
            keepAliveInterval: Duration(milliseconds: 50),
            keepAliveMessage: ping,
            sendKeepAliveOnlyWhenIdle: true,
            minReconnectDelay: Duration(milliseconds: 5),
            maxReconnectDelay: Duration(milliseconds: 50),
            connectTimeout: Duration(milliseconds: 250),
          ),
        );

        unawaited(ws.connect());
        await _becomes(ws, WsConnectionState.open);

        // Continuous outbound traffic: every tick sees recent activity and is
        // suppressed.
        for (var i = 0; i < 30; i++) {
          ws.send('chunk-$i');
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(socket.sent.where((Object s) => s == ping), isEmpty);

        // Once idle for a full interval, the heartbeat resumes.
        await _eventually(
          () => socket.sent.contains(ping),
          'heartbeat to resume once idle',
        );

        await ws.close(drainTimeout: _drain);
      },
    );

    test('is disabled entirely by a zero keepAliveInterval', () async {
      final factory = FakeWsFactory();
      final socket = factory.enqueueSocket();
      final ws = _makeWs(
        factory,
        options: const ResilientWebSocketOptions(
          keepAliveInterval: Duration.zero,
          minReconnectDelay: Duration(milliseconds: 5),
          maxReconnectDelay: Duration(milliseconds: 50),
          connectTimeout: Duration(milliseconds: 250),
        ),
      );

      unawaited(ws.connect());
      await _becomes(ws, WsConnectionState.open);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(socket.sent, isEmpty);

      await ws.close(drainTimeout: _drain);
    });
  });

  group('unexpected disconnect', () {
    test('reconnects with backoff and restores the session', () async {
      final factory = FakeWsFactory();
      final first = factory.enqueueSocket();
      final second = factory.enqueueSocket();

      WsCloseContext? closeCtx;
      WsReconnectContext? reconnectCtx;
      final backoffWatch = Stopwatch();
      var reconnected = false;
      final logger = RecordingLogger();
      final ws = _makeWs(
        factory,
        logger: logger,
        options: ResilientWebSocketOptions(
          keepAliveInterval: const Duration(minutes: 30),
          minReconnectDelay: const Duration(milliseconds: 5),
          maxReconnectDelay: const Duration(milliseconds: 50),
          connectTimeout: const Duration(milliseconds: 250),
          shouldReconnect: (ctx) {
            closeCtx = ctx;
            return true;
          },
          onReconnecting: (ctx) {
            reconnectCtx = ctx;
            backoffWatch
              ..reset()
              ..start();
          },
          onReconnected: () {
            reconnected = true;
            backoffWatch.stop();
          },
        ),
      );
      final states = _recordStates(ws);

      unawaited(ws.connect());
      await _becomes(ws, WsConnectionState.open);
      expect(ws.connectionLostAt, isNull);

      first.serverClose(code: 4009, reason: 'Session expired');

      await _eventually(
        () => states.contains(WsConnectionState.reconnecting),
        'reconnecting state after server close',
      );

      // Disconnect accounting and the close context seen by the policy.
      expect(ws.reconnectAttempts, 1);
      expect(ws.connectionLostAt, isNotNull);
      expect(ws.connectionLostAt!.isUtc, isTrue);
      expect(closeCtx, isNotNull);
      final capturedClose = closeCtx!;
      expect(capturedClose.closeCode, 4009);
      expect(capturedClose.closeReason, 'Session expired');
      expect(capturedClose.attempt, 1);
      expect(capturedClose.error, isNull);
      // The disconnect path neither classifies nor probes — those are for
      // failed dials.
      expect(capturedClose.classification, isNull);
      expect(capturedClose.internetUp, isNull);

      // The reconnect context reports the backoff that is about to be
      // waited out: 5 ms base ±25% jitter for attempt 1.
      expect(reconnectCtx, isNotNull);
      final capturedReconnect = reconnectCtx!;
      expect(capturedReconnect.attempt, 1);
      expect(capturedReconnect.classification, isNull);
      expect(capturedReconnect.internetUp, isNull);
      expect(
        capturedReconnect.nextDelay.inMilliseconds,
        inInclusiveRange(3, 8),
      );

      await _becomes(ws, WsConnectionState.open);

      // A fresh dial was made and delivered the queued second socket.
      expect(factory.connectCalls, 2);
      expect(factory.delivered.last, same(second));

      // The backoff was actually waited out before the retry connected.
      expect(backoffWatch.elapsed >= capturedReconnect.nextDelay, isTrue);

      // Reconnect bookkeeping is reset.
      expect(reconnected, isTrue);
      expect(ws.reconnectAttempts, 0);
      expect(ws.connectionLostAt, isNull);
      expect(ws.connectedAt, isNotNull);
      expect(
        logger.infos.any((String m) => m.contains('Reconnected after')),
        isTrue,
      );
      await _flush();
      expect(
        states,
        containsAllInOrder(<WsConnectionState>[
          WsConnectionState.connecting,
          WsConnectionState.open,
          WsConnectionState.reconnecting,
          WsConnectionState.open,
        ]),
      );

      await ws.close(drainTimeout: _drain);
    });

    test('an error on the inbound stream is treated as a disconnect', () async {
      final flaky = _FlakyWsSocket()..hideCloseInfo = true;
      final factory = _ScriptedWsFactory(script: <Object>[flaky]);

      WsCloseContext? closeCtx;
      var reconnected = false;
      final ws = _makeWs(
        factory,
        options: ResilientWebSocketOptions(
          keepAliveInterval: const Duration(minutes: 30),
          minReconnectDelay: const Duration(milliseconds: 5),
          maxReconnectDelay: const Duration(milliseconds: 50),
          connectTimeout: const Duration(milliseconds: 250),
          shouldReconnect: (ctx) {
            closeCtx = ctx;
            return true;
          },
          onReconnected: () => reconnected = true,
        ),
      );
      final states = _recordStates(ws);

      unawaited(ws.connect());
      await _becomes(ws, WsConnectionState.open);

      flaky.fail('connection reset by peer');

      await _eventually(
        () => states.contains(WsConnectionState.reconnecting),
        'reconnecting after inbound stream error',
      );
      await _becomes(ws, WsConnectionState.open);

      // The flaky socket's closeCode/closeReason getters threw; the session
      // swallowed that and reported nulls through the defensive try/catch.
      expect(closeCtx, isNotNull);
      expect(closeCtx!.closeCode, isNull);
      expect(closeCtx!.closeReason, isNull);
      expect(closeCtx!.attempt, 1);

      expect(reconnected, isTrue);
      expect(factory.connectCalls, 2);

      await ws.close(drainTimeout: _drain);
    });

    test('closing during a post-disconnect backoff ends the session', () async {
      final factory = FakeWsFactory();
      final socket = factory.enqueueSocket();
      final ws = _makeWs(
        factory,
        options: const ResilientWebSocketOptions(
          keepAliveInterval: Duration(minutes: 30),
          minReconnectDelay: Duration(milliseconds: 40),
          maxReconnectDelay: Duration(milliseconds: 50),
          connectTimeout: Duration(milliseconds: 250),
        ),
      );
      final states = _recordStates(ws);

      final session = ws.connect();
      await _becomes(ws, WsConnectionState.open);
      socket.serverClose();
      await _eventually(
        () => states.contains(WsConnectionState.reconnecting),
        'reconnecting after disconnect',
      );

      // Close while the 40 ms backoff is still pending.
      await ws.close(drainTimeout: _drain);
      await session.timeout(_deadline);

      expect(ws.state, WsConnectionState.closed);
      expect(factory.connectCalls, 1, reason: 'chain died before redialing');
    });
  });

  group('connect failure classification', () {
    test(
      'repeated corroborated definitive failures give up as failed',
      () async {
        final factory = FakeWsFactory()
          ..enqueueError(WebSocketException('server did not upgrade'))
          ..enqueueError(WebSocketException('server did not upgrade'));
        final probe = _CountingProbe();
        final reconnectCtxs = <WsReconnectContext>[];
        final ws = _makeWs(
          factory,
          probe: probe,
          options: ResilientWebSocketOptions(
            keepAliveInterval: const Duration(minutes: 30),
            minReconnectDelay: const Duration(milliseconds: 5),
            maxReconnectDelay: const Duration(milliseconds: 50),
            connectTimeout: const Duration(milliseconds: 250),
            corroboratedFailureThreshold: 2,
            onReconnecting: reconnectCtxs.add,
          ),
        );
        final states = _recordStates(ws);

        final session = ws.connect();
        await _becomes(ws, WsConnectionState.failed);
        await session.timeout(_deadline);

        // First definitive failure retried (corroborated count 1 < 2), second
        // one gave up — without ever consulting a shouldReconnect callback.
        expect(factory.connectCalls, 2);
        expect(probe.calls, 2);
        expect(reconnectCtxs, hasLength(1));
        expect(reconnectCtxs.single.attempt, 1);
        expect(
          reconnectCtxs.single.classification,
          WsFailureClassification.deepgramDefinitive,
        );
        expect(reconnectCtxs.single.internetUp, isTrue);

        expect(ws.reconnectAttempts, 2);
        // The loss anchor is set even though no connection was ever open.
        expect(ws.connectionLostAt, isNotNull);
        await _flush();
        expect(
          states,
          containsAllInOrder(<WsConnectionState>[
            WsConnectionState.connecting,
            WsConnectionState.reconnecting,
            WsConnectionState.failed,
          ]),
        );
      },
    );

    test('ambiguous failures with the internet down keep retrying', () async {
      final factory = _ScriptedWsFactory(
        alwaysThrow: Exception('tls handshake failed'),
      );
      final probe = FakeProbe(result: false); // internet suspect
      final reconnectCtxs = <WsReconnectContext>[];
      final ws = _makeWs(
        factory,
        probe: probe,
        options: ResilientWebSocketOptions(
          keepAliveInterval: const Duration(minutes: 30),
          minReconnectDelay: const Duration(milliseconds: 5),
          maxReconnectDelay: const Duration(milliseconds: 50),
          connectTimeout: const Duration(milliseconds: 250),
          onReconnecting: reconnectCtxs.add,
        ),
      );
      final states = _recordStates(ws);

      final session = ws.connect();
      await _eventually(
        () => reconnectCtxs.length >= 3,
        'at least three scheduled retries',
      );

      // Every failure is ambiguous and corroborated as internet-down, so the
      // default policy never gives up.
      for (final ctx in reconnectCtxs) {
        expect(ctx.classification, WsFailureClassification.ambiguous);
        expect(ctx.internetUp, isFalse);
      }
      expect(reconnectCtxs.first.attempt, 1);
      expect(reconnectCtxs.last.attempt, greaterThanOrEqualTo(3));
      expect(factory.connectCalls, greaterThanOrEqualTo(3));
      expect(ws.state, WsConnectionState.reconnecting);
      expect(states, isNot(contains(WsConnectionState.failed)));

      // connect() while a reconnect chain owns the session is a guarded
      // no-op that resolves immediately.
      await ws.connect().timeout(_deadline);

      // The chain only ends when the user closes the session.
      var sessionDone = false;
      unawaited(session.then((_) => sessionDone = true));
      expect(sessionDone, isFalse);
      await ws.close(drainTimeout: _drain);
      await session.timeout(_deadline);
      expect(ws.state, WsConnectionState.closed);
    });

    test('shouldReconnect veto on a failed dial fails immediately', () async {
      final error = Exception('edge peer closed the handshake');
      final factory = FakeWsFactory()..enqueueError(error);
      WsCloseContext? vetoed;
      var onReconnectingFired = false;
      final ws = _makeWs(
        factory,
        options: ResilientWebSocketOptions(
          keepAliveInterval: const Duration(minutes: 30),
          minReconnectDelay: const Duration(milliseconds: 5),
          maxReconnectDelay: const Duration(milliseconds: 50),
          connectTimeout: const Duration(milliseconds: 250),
          shouldReconnect: (ctx) {
            vetoed = ctx;
            return false;
          },
          onReconnecting: (_) => onReconnectingFired = true,
        ),
      );

      final session = ws.connect();
      await _becomes(ws, WsConnectionState.failed);
      await session.timeout(_deadline);

      expect(factory.connectCalls, 1);
      expect(onReconnectingFired, isFalse);
      expect(vetoed, isNotNull);
      final captured = vetoed!;
      expect(captured.error, same(error));
      expect(captured.attempt, 1);
      expect(captured.classification, WsFailureClassification.ambiguous);
      expect(captured.internetUp, isTrue, reason: 'FakeProbe defaults to up');
      expect(captured.closeCode, isNull);
      expect(captured.closeReason, isNull);
    });

    test('shouldReconnect veto after a disconnect fails immediately', () async {
      final factory = FakeWsFactory();
      final socket = factory.enqueueSocket();
      WsCloseContext? vetoed;
      final ws = _makeWs(
        factory,
        options: ResilientWebSocketOptions(
          keepAliveInterval: const Duration(minutes: 30),
          minReconnectDelay: const Duration(milliseconds: 5),
          maxReconnectDelay: const Duration(milliseconds: 50),
          connectTimeout: const Duration(milliseconds: 250),
          shouldReconnect: (ctx) {
            vetoed = ctx;
            return false;
          },
        ),
      );

      final session = ws.connect();
      await _becomes(ws, WsConnectionState.open);
      socket.serverClose(code: 1011, reason: 'boom');
      await _becomes(ws, WsConnectionState.failed);
      await session.timeout(_deadline);

      expect(factory.connectCalls, 1);
      expect(vetoed, isNotNull);
      expect(vetoed!.closeCode, 1011);
      expect(vetoed!.closeReason, 'boom');
      expect(vetoed!.attempt, 1);
    });

    test('autoReconnect=false fails after the first failed dial', () async {
      final factory = FakeWsFactory()
        ..enqueueError(Exception('socket factory exploded'));
      final ws = _makeWs(
        factory,
        options: const ResilientWebSocketOptions(
          autoReconnect: false,
          keepAliveInterval: Duration(minutes: 30),
          minReconnectDelay: Duration(milliseconds: 5),
          maxReconnectDelay: Duration(milliseconds: 50),
          connectTimeout: Duration(milliseconds: 250),
        ),
      );

      final session = ws.connect();
      await _becomes(ws, WsConnectionState.failed);
      await session.timeout(_deadline);
      expect(factory.connectCalls, 1);
    });

    test('autoReconnect=false fails after an unexpected disconnect', () async {
      final factory = FakeWsFactory();
      final socket = factory.enqueueSocket();
      final ws = _makeWs(
        factory,
        options: const ResilientWebSocketOptions(
          autoReconnect: false,
          keepAliveInterval: Duration(minutes: 30),
          minReconnectDelay: Duration(milliseconds: 5),
          maxReconnectDelay: Duration(milliseconds: 50),
          connectTimeout: Duration(milliseconds: 250),
        ),
      );

      final session = ws.connect();
      await _becomes(ws, WsConnectionState.open);
      socket.serverClose(code: 1006);
      await _becomes(ws, WsConnectionState.failed);
      await session.timeout(_deadline);

      expect(factory.connectCalls, 1);
      expect(ws.connectionLostAt, isNotNull);
    });

    test('maxReconnectAttempts caps failed dials and reports timeouts as '
        'internetSuspect', () async {
      final timeout = TimeoutException('Connection timed out');
      final factory = FakeWsFactory()
        ..enqueueError(timeout)
        ..enqueueError(timeout);
      final reconnectCtxs = <WsReconnectContext>[];
      final ws = _makeWs(
        factory,
        options: ResilientWebSocketOptions(
          keepAliveInterval: const Duration(minutes: 30),
          minReconnectDelay: const Duration(milliseconds: 5),
          maxReconnectDelay: const Duration(milliseconds: 50),
          connectTimeout: const Duration(milliseconds: 250),
          maxReconnectAttempts: 2,
          onReconnecting: reconnectCtxs.add,
        ),
      );

      final session = ws.connect();
      await _becomes(ws, WsConnectionState.failed);
      await session.timeout(_deadline);

      expect(factory.connectCalls, 2);
      expect(reconnectCtxs, hasLength(1));
      expect(
        reconnectCtxs.single.classification,
        WsFailureClassification.internetSuspect,
      );
      expect(reconnectCtxs.single.internetUp, isTrue);
      expect(ws.reconnectAttempts, 2);
    });

    test('maxReconnectAttempts caps reconnects after disconnects', () async {
      final factory = FakeWsFactory();
      final socket = factory.enqueueSocket();
      final ws = _makeWs(
        factory,
        options: const ResilientWebSocketOptions(
          maxReconnectAttempts: 1,
          keepAliveInterval: Duration(minutes: 30),
          minReconnectDelay: Duration(milliseconds: 5),
          maxReconnectDelay: Duration(milliseconds: 50),
          connectTimeout: Duration(milliseconds: 250),
        ),
      );

      final session = ws.connect();
      await _becomes(ws, WsConnectionState.open);
      socket.serverClose();
      await _becomes(ws, WsConnectionState.failed);
      await session.timeout(_deadline);

      expect(factory.connectCalls, 1, reason: 'no second dial allowed');
    });

    test('connect() after failure starts a fresh session', () async {
      final factory = FakeWsFactory()
        ..enqueueError(WebSocketException('server did not upgrade'))
        ..enqueueError(WebSocketException('server did not upgrade'));
      final ws = _makeWs(
        factory,
        options: const ResilientWebSocketOptions(
          corroboratedFailureThreshold: 2,
          keepAliveInterval: Duration(minutes: 30),
          minReconnectDelay: Duration(milliseconds: 5),
          maxReconnectDelay: Duration(milliseconds: 50),
          connectTimeout: Duration(milliseconds: 250),
        ),
      );

      final firstSession = ws.connect();
      await _becomes(ws, WsConnectionState.failed);
      await firstSession.timeout(_deadline);

      // The failed state is not terminal for connect().
      factory.enqueueSocket();
      final secondSession = ws.connect();
      await _becomes(ws, WsConnectionState.open);

      expect(factory.connectCalls, 3);
      expect(ws.reconnectAttempts, 0, reason: 'reset by the fresh connect');
      expect(ws.isConnected, isTrue);

      await ws.close(drainTimeout: _drain);
      await secondSession.timeout(_deadline);
    });
  });

  group('generation tokens', () {
    test('closing during a backoff kills the chain; a superseded chain cannot '
        'resurrect', () async {
      final factory = FakeWsFactory()
        ..enqueueError(Exception('first dial failed'));
      final reconnectCtxs = <WsReconnectContext>[];
      final ws = _makeWs(
        factory,
        options: ResilientWebSocketOptions(
          keepAliveInterval: const Duration(minutes: 30),
          minReconnectDelay: const Duration(milliseconds: 40),
          maxReconnectDelay: const Duration(milliseconds: 50),
          connectTimeout: const Duration(milliseconds: 250),
          onReconnecting: reconnectCtxs.add,
        ),
      );
      final states = _recordStates(ws);

      final firstSession = ws.connect();
      await _eventually(
        () => reconnectCtxs.length == 1,
        'backoff to be scheduled',
      );
      expect(ws.state, WsConnectionState.reconnecting);

      // Close while the 40–50 ms backoff is still pending.
      await ws.close(drainTimeout: _drain);
      expect(ws.state, WsConnectionState.closed);

      // Start a brand-new session before the old backoff elapses.
      factory.enqueueSocket();
      final secondSession = ws.connect();
      await _becomes(ws, WsConnectionState.open);
      expect(factory.connectCalls, 2);

      // The superseded chain wakes up and dies without touching anything.
      await firstSession.timeout(_deadline);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        factory.connectCalls,
        2,
        reason: 'superseded chain must not dial again',
      );
      expect(ws.state, WsConnectionState.open);
      expect(
        states.where((WsConnectionState s) => s == WsConnectionState.open),
        hasLength(1),
        reason: 'only the new chain may open',
      );

      await ws.close(drainTimeout: _drain);
      await secondSession.timeout(_deadline);
    });

    test('a socket that lands after close() is closed as a zombie', () async {
      final socket = FakeWsSocket();
      final factory = _ScriptedWsFactory(
        script: <Object>[socket],
        delay: const Duration(milliseconds: 40),
      );
      final ws = _makeWs(factory);
      final states = _recordStates(ws);

      final session = ws.connect();
      await _eventually(
        () => states.contains(WsConnectionState.connecting),
        'dial to be in flight',
      );

      // connect() while a dial is already in flight resolves immediately.
      await ws.connect().timeout(_deadline);

      // Close while the dial is still parked in the factory.
      await ws.close(drainTimeout: _drain);
      expect(ws.state, WsConnectionState.closed);

      // The dial completes after close(); the zombie socket is closed and
      // the dead chain never reports open.
      await socket.closedByConsumer.timeout(_deadline);
      await session.timeout(_deadline);
      await _flush();

      expect(factory.connectCalls, 1);
      expect(states, isNot(contains(WsConnectionState.open)));
      expect(ws.isConnected, isFalse);
      expect(
        states,
        containsAllInOrder(<WsConnectionState>[
          WsConnectionState.connecting,
          WsConnectionState.closed,
        ]),
      );
    });

    test('a dial error that lands after close() is discarded by the dead '
        'chain', () async {
      final factory = _ScriptedWsFactory(
        alwaysThrow: Exception('late failure'),
        delay: const Duration(milliseconds: 40),
      );
      final ws = _makeWs(factory);
      final states = _recordStates(ws);

      final session = ws.connect();
      await _eventually(
        () => states.contains(WsConnectionState.connecting),
        'dial to be in flight',
      );
      await ws.close(drainTimeout: _drain);

      // The session future is still parked on the in-flight dial.
      var sessionDone = false;
      unawaited(session.then((_) => sessionDone = true));
      expect(sessionDone, isFalse);

      // The error lands; the generation check discards it silently.
      await session.timeout(_deadline);
      expect(factory.connectCalls, 1);
      expect(ws.state, WsConnectionState.closed);
      expect(states, isNot(contains(WsConnectionState.failed)));
    });
  });

  group('graceful close and dispose', () {
    test(
      'close(closeMessage) sends CloseStream, drains, then reports closed',
      () async {
        final factory = FakeWsFactory();
        final socket = factory.enqueueSocket();
        final ws = _makeWs(factory);
        final received = _recordMessages(ws);

        unawaited(ws.connect());
        await _becomes(ws, WsConnectionState.open);

        final closing = ws.close(
          closeMessage: '{"type":"CloseStream"}',
          drainTimeout: const Duration(milliseconds: 500),
        );

        // The close message went out immediately, before any waiting.
        expect(socket.sent, contains('{"type":"CloseStream"}'));

        // While draining the session is still open and still receives the
        // server's final flushed results.
        socket.emit('{"type":"FinalTranscript"}');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(ws.state, WsConnectionState.open);
        var closed = false;
        unawaited(closing.then((_) => closed = true));
        expect(closed, isFalse, reason: 'server has not finished yet');

        // The server finishes: the stream ends, the drain completes.
        socket.serverClose();
        await closing.timeout(_deadline);

        expect(ws.state, WsConnectionState.closed);
        expect(ws.isClosedByUser, isTrue);
        expect(ws.connectedAt, isNull);
        expect(received.last.text, '{"type":"FinalTranscript"}');
      },
    );

    test('close() on a never-connected session reports closed and is '
        'idempotent', () async {
      final factory = FakeWsFactory();
      final ws = _makeWs(factory);

      await ws.close(drainTimeout: _drain);
      expect(ws.state, WsConnectionState.closed);
      expect(ws.isClosedByUser, isTrue);
      expect(factory.connectCalls, 0);

      // A second close() returns immediately without throwing.
      await ws.close(drainTimeout: _drain);
      expect(ws.state, WsConnectionState.closed);
    });

    test('forceClose tears down immediately without draining', () async {
      final factory = FakeWsFactory();
      final socket = factory.enqueueSocket();
      final ws = _makeWs(factory);

      unawaited(ws.connect());
      await _becomes(ws, WsConnectionState.open);
      socket.emit('{"type":"Metadata"}');

      final watch = Stopwatch()..start();
      await ws.forceClose().timeout(_deadline);
      watch.stop();

      expect(ws.state, WsConnectionState.closed);
      expect(watch.elapsed < const Duration(seconds: 1), isTrue);
      // No CloseStream control message was sent and the socket itself was
      // closed by the teardown.
      expect(socket.sent, isEmpty);
      await socket.closedByConsumer.timeout(_deadline);
      expect(ws.connectedAt, isNull);

      // A second forceClose on an already-closed session returns immediately.
      await ws.forceClose().timeout(_deadline);
    });

    test('close() gives up draining after drainTimeout', () async {
      final factory = FakeWsFactory();
      final socket = factory.enqueueSocket();
      final ws = _makeWs(factory);

      unawaited(ws.connect());
      await _becomes(ws, WsConnectionState.open);

      // The server never finishes: no serverClose() is ever called.
      final watch = Stopwatch()..start();
      await ws
          .close(
            closeMessage: '{"type":"CloseStream"}',
            drainTimeout: const Duration(milliseconds: 30),
          )
          .timeout(_deadline);
      watch.stop();

      expect(ws.state, WsConnectionState.closed);
      expect(socket.sent, contains('{"type":"CloseStream"}'));
      expect(watch.elapsed >= const Duration(milliseconds: 25), isTrue);
      expect(watch.elapsed < const Duration(seconds: 2), isTrue);
      // The teardown still closed the silent socket.
      await socket.closedByConsumer.timeout(_deadline);
    });

    test('dispose closes the session and its streams', () async {
      final factory = FakeWsFactory();
      factory.enqueueSocket();
      final ws = _makeWs(factory);
      final states = <WsConnectionState>[];
      final sub = ws.states.listen(states.add);

      unawaited(ws.connect());
      await _becomes(ws, WsConnectionState.open);

      await ws.dispose();
      await _flush();

      expect(ws.state, WsConnectionState.closed);
      expect(states.last, WsConnectionState.closed);

      // Listeners attached after dispose are immediately done (the
      // controllers are closed).
      var messageDone = false;
      var stateDone = false;
      ws.messages.listen((WsMessage _) {}, onDone: () => messageDone = true);
      ws.states.listen(
        (WsConnectionState _) {},
        onDone: () => stateDone = true,
      );
      await Future<void>.delayed(_tick);
      expect(messageDone, isTrue);
      expect(stateDone, isTrue);

      // Sends after dispose are inert.
      ws.send('nope');
      await sub.cancel();
    });

    test('connecting a disposed session throws a StateError', () async {
      final factory = FakeWsFactory();
      factory.enqueueSocket();
      final ws = _makeWs(factory);

      await ws.dispose();

      // A disposed session is terminal: connect() must refuse loudly instead
      // of silently resurrecting against closed controllers.
      expect(ws.connect, throwsStateError);
      expect(ws.state, WsConnectionState.closed);
      expect(factory.connectCalls, 0);
    });

    test('send failures on a broken sink are logged and swallowed', () async {
      final factory = FakeWsFactory();
      final socket = factory.enqueueSocket();
      final logger = RecordingLogger();
      final ws = _makeWs(factory, logger: logger);

      unawaited(ws.connect());
      await _becomes(ws, WsConnectionState.open);

      socket.addError = StateError('sink closed');
      ws.send('this will fail');
      ws.sendBytes(<int>[1, 2]);
      expect(socket.sent, isEmpty);
      expect(
        logger.warns.any((String m) => m.contains('Failed to send text frame')),
        isTrue,
      );
      expect(
        logger.warns.any(
          (String m) => m.contains('Failed to send binary frame'),
        ),
        isTrue,
      );

      // A failing close-message send is swallowed too; the close still
      // completes after the drain window.
      await ws
          .close(
            closeMessage: '{"type":"CloseStream"}',
            drainTimeout: const Duration(milliseconds: 30),
          )
          .timeout(_deadline);
      expect(ws.state, WsConnectionState.closed);
    });

    test('teardown swallows a failing socket close', () async {
      final socket = _FlakyWsSocket()..throwOnClose = true;
      final factory = _ScriptedWsFactory(script: <Object>[socket]);
      final ws = _makeWs(factory);

      unawaited(ws.connect());
      await _becomes(ws, WsConnectionState.open);

      await ws.forceClose().timeout(_deadline);
      expect(ws.state, WsConnectionState.closed);
    });
  });
}
