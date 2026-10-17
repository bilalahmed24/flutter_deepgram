/// Unit tests for `lib/src/agent/agent_client.dart` — the
/// `DeepgramVoiceAgent` Voice Agent WebSocket client.
///
/// The client builds its own `ResilientWebSocket` with the default
/// `IoWsFactory` (there is no factory injection point), so — like the other
/// streaming-client suites — a real `dart:io` loopback server stands in for
/// `wss://agent.deepgram.com`: `HttpOverrides.global` (installed before the
/// first `WebSocket.connect`, which caches a static `HttpClient`) routes the
/// reserved-`.test` host `agent.deepgram.test` to a scriptable
/// `HttpServer` + `WebSocketTransformer` on `127.0.0.1:<ephemeral>`. All
/// traffic stays on loopback; no external network is ever touched.
///
/// Covered: the connect → Welcome → Settings → SettingsApplied handshake
/// (including every failure mode), every client message's exact wire JSON,
/// every server event stream, malformed-frame defensiveness, the agent
/// KeepAlive policy (8 s idle-only — verified indirectly here because the
/// client always overrides the user's keep-alive knobs), reconnection with
/// Settings re-send, and the close/forceClose lifecycle.
///
/// Known lib bug deliberately NOT exercised (see T8): an `Error` frame
/// arriving *before* `Welcome` orphan-completes the settings-applied
/// completer's error, surfacing as an unhandled async error in the host.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:test/test.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';

const Duration _waitTimeout = Duration(seconds: 3);

/// Settings used for the handshake in every socket test.
const VoiceAgentSettings _defaultSettings = VoiceAgentSettings(
  agent: AgentAgentSettings(
    listen: AgentListen(provider: AgentListenProvider.v1()),
    speak: AgentSpeak(provider: AgentSpeakProvider(model: 'aura-2-thalia-en')),
  ),
  audio: AgentAudioSettings(input: AgentAudioInput()),
);

// ---------------------------------------------------------------------------
// Host routing: point the fake agent host at the loopback server
// ---------------------------------------------------------------------------

/// The fake Voice Agent hostname used by every test config. It lives in the
/// reserved `.test` TLD, so even without routing it could never resolve
/// outside the machine.
const String _agentTestHost = 'agent.deepgram.test';

/// Routes [_agentTestHost] to the current loopback server port.
class _Router {
  /// Loopback port to route to; `0` routes nowhere.
  int port = 0;

  /// Rewrites agent test URLs to the loopback server.
  Uri rewrite(Uri url) {
    if (url.host == _agentTestHost && port != 0) {
      return url.replace(host: '127.0.0.1', port: port);
    }
    return url;
  }
}

final _Router _router = _Router();

/// Installs [_router] for every `dart:io` HttpClient created in this isolate.
class _RoutingHttpOverrides extends HttpOverrides {
  _RoutingHttpOverrides(this._inner);

  final HttpClient _inner;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _RoutingHttpClient(_inner);
}

/// Forwards `openUrl` through the router and answers everything else with
/// `noSuchMethod`.
///
/// `close()` must be implemented explicitly: `package:http`'s top-level
/// `head` (used by `ConnectivityProbe`) creates a client from these
/// overrides and closes it afterwards — a `noSuchMethod`-throwing wrapper
/// would make every probe report the internet as down.
class _RoutingHttpClient implements HttpClient {
  _RoutingHttpClient(this._inner);

  final HttpClient _inner;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _inner.openUrl(method, _router.rewrite(url));

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'Unexpected HttpClient member used by the agent tests: '
      '${invocation.memberName}');
}

// ---------------------------------------------------------------------------
// Loopback /v1/agent/converse server harness
// ---------------------------------------------------------------------------

/// One accepted server-side WebSocket connection.
class _AgentConn {
  _AgentConn(this.request, this.socket);

  /// The upgrade request (URI + headers exactly as sent by the SDK).
  final HttpRequest request;

  /// The upgraded socket.
  final WebSocket socket;

  /// Every frame received from the SDK, in order.
  final List<Object> frames = <Object>[];

  final List<Completer<Object>> _frameWaiters = <Completer<Object>>[];
  final List<Object> _pendingFrames = <Object>[];
  final List<Completer<void>> _doneWaiters = <Completer<void>>[];
  bool _done = false;

  /// Starts pumping inbound frames.
  void pump() {
    socket.cast<Object>().listen((Object frame) {
      frames.add(frame);
      if (_frameWaiters.isNotEmpty) {
        _frameWaiters.removeAt(0).complete(frame);
      } else {
        _pendingFrames.add(frame);
      }
    }, onDone: _markDone, onError: (Object _) => _markDone());
  }

  /// Resolves with the next frame the SDK sends (already-received frames are
  /// replayed in order).
  Future<Object> nextFrame({Duration timeout = _waitTimeout}) {
    if (_pendingFrames.isNotEmpty) {
      return Future<Object>.value(_pendingFrames.removeAt(0));
    }
    final waiter = Completer<Object>();
    _frameWaiters.add(waiter);
    return waiter.future.timeout(timeout, onTimeout: () {
      throw TimeoutException(
          'No frame within $timeout. Frames so far: $frames');
    });
  }

  /// Resolves once the socket is closed from either side.
  Future<void> get done {
    if (_done) return Future<void>.value();
    final waiter = Completer<void>();
    _doneWaiters.add(waiter);
    return waiter.future.timeout(_waitTimeout,
        onTimeout: () => throw TimeoutException('Socket stayed open.'));
  }

  /// Sends a text frame.
  void sendText(String text) => socket.add(text);

  /// Sends a binary frame.
  void sendBytes(List<int> bytes) => socket.add(bytes);

  /// Sends a JSON object as a text frame.
  void sendJson(Map<String, dynamic> json) => socket.add(jsonEncode(json));

  /// Simulates an unexpected server-side disconnect.
  Future<void> drop() => socket.close(1011, 'unexpected drop');

  /// Ends the session cleanly, like the real agent server at session end.
  Future<void> hangUp() => socket.close(1000, 'session complete');

  void _markDone() {
    if (_done) return;
    _done = true;
    for (final waiter in _doneWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _doneWaiters.clear();
  }
}

/// A scriptable WebSocket server standing in for `wss://agent.deepgram.com`.
class _LoopbackAgentServer {
  _LoopbackAgentServer._();

  late final HttpServer _server;
  late final StreamSubscription<HttpRequest> _serverSub;

  /// Accepted connections, in order.
  final List<_AgentConn> connections = <_AgentConn>[];

  /// When positive, the next N upgrade requests are refused with a 401
  /// (standing in for rejected credentials).
  int refuseUpgradesRemaining = 0;

  /// When true, upgrade requests are never answered (connect hangs until the
  /// client's connect timeout fires).
  bool hangUpgrades = false;

  final List<Completer<_AgentConn>> _connWaiters = <Completer<_AgentConn>>[];
  final List<_AgentConn> _readyConns = <_AgentConn>[];

  /// Binds the server to loopback on an ephemeral port.
  static Future<_LoopbackAgentServer> start() async {
    final instance = _LoopbackAgentServer._();
    await instance._bind();
    return instance;
  }

  Future<void> _bind() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _serverSub = _server.listen((HttpRequest request) {
      unawaited(_handle(request));
    });
  }

  /// The bound port.
  int get port => _server.port;

  /// Resolves with the next accepted connection (in order).
  Future<_AgentConn> nextConnection() {
    if (_readyConns.isNotEmpty) {
      return Future<_AgentConn>.value(_readyConns.removeAt(0));
    }
    final waiter = Completer<_AgentConn>();
    _connWaiters.add(waiter);
    return waiter.future.timeout(_waitTimeout,
        onTimeout: () =>
            throw TimeoutException('No connection within $_waitTimeout.'));
  }

  /// Shuts the server down.
  Future<void> shutdown() async {
    try {
      await _server.close(force: true);
    } catch (_) {}
    await _serverSub.cancel();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        if (hangUpgrades) {
          // Never answer: the client's connect attempt times out.
          return;
        }
        if (refuseUpgradesRemaining > 0) {
          refuseUpgradesRemaining--;
          request.response.statusCode = 401;
          request.response.write('unauthorized');
          await request.response.close();
          return;
        }
        final conn =
            _AgentConn(request, await WebSocketTransformer.upgrade(request));
        connections.add(conn);
        conn.pump();
        if (_connWaiters.isNotEmpty) {
          _connWaiters.removeAt(0).complete(conn);
        } else {
          _readyConns.add(conn);
        }
        return;
      }
      // Plain HTTP requests (connectivity probes) get a green answer.
      request.response.statusCode = 200;
      await request.response.close();
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }
}

// ---------------------------------------------------------------------------
// Small test utilities
// ---------------------------------------------------------------------------

/// Records every event of a broadcast stream and offers event-driven waits.
class _Recorder<T> {
  _Recorder(Stream<T> stream) {
    _sub = stream.listen(_add, onError: _addError);
  }

  late final StreamSubscription<T> _sub;

  /// Every event seen so far, in order.
  final List<T> values = <T>[];

  /// Errors seen on the stream, if any.
  final List<Object> errors = <Object>[];

  final List<Completer<T>> _nextWaiters = <Completer<T>>[];
  final List<_PredicateWait<T>> _predicateWaiters = <_PredicateWait<T>>[];
  final List<_CountWait<T>> _countWaiters = <_CountWait<T>>[];

  /// Resolves with the next event emitted after this call.
  Future<T> get next {
    final waiter = Completer<T>();
    _nextWaiters.add(waiter);
    return waiter.future.timeout(_waitTimeout,
        onTimeout: () =>
            throw TimeoutException('No event within $_waitTimeout. '
                'Recorded: $values'));
  }

  /// Resolves with the first recorded (or next) event matching [predicate].
  Future<T> waitFor(bool Function(T) predicate) {
    for (final T value in values) {
      if (predicate(value)) return Future<T>.value(value);
    }
    final wait = _PredicateWait<T>(predicate);
    _predicateWaiters.add(wait);
    return wait.completer.future.timeout(_waitTimeout, onTimeout: () {
      _predicateWaiters.remove(wait);
      throw TimeoutException('No matching event within $_waitTimeout. '
          'Recorded: $values');
    });
  }

  /// Resolves once [n] matching events have been recorded.
  Future<void> seen(int n, bool Function(T) predicate) {
    if (_countOf(predicate) >= n) return Future<void>.value();
    final wait = _CountWait<T>(n, predicate);
    _countWaiters.add(wait);
    return wait.completer.future.timeout(_waitTimeout, onTimeout: () {
      _countWaiters.remove(wait);
      throw TimeoutException('Only ${_countOf(predicate)} of $n matching '
          'events within $_waitTimeout. Recorded: $values');
    });
  }

  /// Stops recording.
  Future<void> dispose() => _sub.cancel();

  int _countOf(bool Function(T) predicate) => values.where(predicate).length;

  void _add(T value) {
    values.add(value);
    if (_nextWaiters.isNotEmpty) {
      _nextWaiters.removeAt(0).complete(value);
    }
    _predicateWaiters.removeWhere((_PredicateWait<T> wait) {
      if (wait.predicate(value) && !wait.completer.isCompleted) {
        wait.completer.complete(value);
        return true;
      }
      return false;
    });
    _countWaiters.removeWhere((_CountWait<T> wait) {
      if (_countOf(wait.predicate) >= wait.n && !wait.completer.isCompleted) {
        wait.completer.complete();
        return true;
      }
      return false;
    });
  }

  void _addError(Object error) {
    errors.add(error);
  }
}

class _PredicateWait<T> {
  _PredicateWait(this.predicate);

  final bool Function(T) predicate;
  final Completer<T> completer = Completer<T>();
}

class _CountWait<T> {
  _CountWait(this.n, this.predicate);

  final int n;
  final bool Function(T) predicate;
  final Completer<void> completer = Completer<void>();
}

/// Wires a config, auth, and HTTP engine against [server] exactly like the
/// `DeepgramClient.createVoiceAgent` facade does.
class _Harness {
  _Harness(this.server) : config = _agentConfig() {
    _router.port = server.port;
    auth = DeepgramAuth(config);
    final queue = QueueHttpClient();
    addTearDown(queue.close);
    httpEngine = HttpEngine(config: config, auth: auth, client: queue);
  }

  static DeepgramConfig _agentConfig() => DeepgramConfig(
        apiKey: 'test-api-key',
        baseUrl: _agentTestHost,
        agentBaseUrl: _agentTestHost,
        useTls: false,
        requestTimeout: const Duration(seconds: 2),
        connectTimeout: const Duration(seconds: 2),
        maxRetries: 2,
        retryBaseDelay: const Duration(milliseconds: 1),
        retryMaxDelay: const Duration(milliseconds: 5),
      );

  /// The loopback server.
  final _LoopbackAgentServer server;

  /// Config pointing at the loopback server over plain ws/http.
  final DeepgramConfig config;

  /// Credential manager (Token auth).
  late final DeepgramAuth auth;

  /// HTTP engine (unused on the wire by these tests, but required by the
  /// agent constructor).
  late final HttpEngine httpEngine;

  /// Creates a raw agent without starting it.
  DeepgramVoiceAgent createAgent({
    ResilientWebSocketOptions? wsOptions,
    DeepgramLogger? logger,
  }) {
    final agent = DeepgramVoiceAgent(
      config: config,
      auth: auth,
      http: httpEngine,
      wsOptions: wsOptions,
      logger: logger,
    );
    addTearDown(agent.forceClose);
    return agent;
  }

  /// Runs the full handshake: connect → Welcome → Settings →
  /// SettingsApplied, and resolves with the connection and the agent.
  Future<(_AgentConn, DeepgramVoiceAgent)> startSession({
    VoiceAgentSettings settings = _defaultSettings,
    ResilientWebSocketOptions? wsOptions,
    DeepgramLogger? logger,
    void Function(DeepgramVoiceAgent agent)? onCreated,
    String requestId = 'req-handshake',
  }) async {
    final connFuture = server.nextConnection();
    final agent = DeepgramVoiceAgent(
      config: config,
      auth: auth,
      http: httpEngine,
      wsOptions: wsOptions,
      logger: logger,
    );
    addTearDown(agent.forceClose);
    onCreated?.call(agent);
    final startFuture = agent.start(settings);
    final conn = await connFuture;
    conn.sendJson(<String, dynamic>{
      'type': 'Welcome',
      'request_id': requestId,
    });
    // The Settings frame the SDK must send right after the Welcome.
    await conn.nextFrame();
    conn.sendJson(<String, dynamic>{'type': 'SettingsApplied'});
    await startFuture;
    return (conn, agent);
  }
}

/// A short, bounded quiet period for negative ("nothing else happens")
/// assertions.
Future<void> _quiet([int milliseconds = 120]) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

/// Decodes a captured text frame into a JSON object.
Map<String, dynamic> _decode(Object frame) =>
    jsonDecode(frame as String) as Map<String, dynamic>;

void main() {
  // Install host routing before anything in this isolate creates a
  // dart:io HttpClient — dart:io's WebSocket.connect caches its static
  // HttpClient on first use, and every test session must be routed to the
  // loopback server from the very first frame.
  final HttpClient routingInnerClient = HttpClient();
  HttpOverrides.global = _RoutingHttpOverrides(routingInnerClient);

  // -------------------------------------------------------------------------
  // Construction and endpoint wiring
  // -------------------------------------------------------------------------

  group('construction and wiring', () {
    test('exposes the injected http engine', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      final agent = harness.createAgent();
      expect(agent.http, same(harness.httpEngine));
      expect(agent.isConnected, isFalse);
      expect(agent.reconnectAttempts, 0);
    });

    test('connects to /v1/agent/converse on the agent host with Token auth',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      final (conn, agent) = await harness.startSession();

      // The upgrade request hit the documented path with the documented
      // credential header (the host itself was rewritten to loopback).
      expect(conn.request.uri.path, '/v1/agent/converse');
      expect(
        conn.request.headers.value('authorization'),
        'Token test-api-key',
      );
      expect(agent.isConnected, isTrue);
    });

    test('falls back to a default logger when none is supplied', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      final (_, agent) = await harness.startSession();
      expect(agent.isConnected, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // Handshake: connect → Welcome → Settings → SettingsApplied
  // -------------------------------------------------------------------------

  group('handshake', () {
    test('sends nothing before Welcome, then the exact Settings frame',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      late final _Recorder<AgentWelcome> welcome;
      late final _Recorder<void> applied;
      final connFuture = server.nextConnection();
      final agent = harness.createAgent();
      welcome = _Recorder<AgentWelcome>(agent.welcome);
      addTearDown(welcome.dispose);
      applied = _Recorder<void>(agent.settingsApplied);
      addTearDown(applied.dispose);

      final startFuture = agent.start(_defaultSettings);
      final conn = await connFuture;

      // The client stays silent until the server speaks first.
      await _quiet();
      expect(conn.frames, isEmpty);

      conn.sendJson(<String, dynamic>{
        'type': 'Welcome',
        'request_id': 'req-wire',
      });
      final settingsFrame = _decode(await conn.nextFrame());
      expect(settingsFrame, _defaultSettings.toJson());
      conn.sendJson(<String, dynamic>{'type': 'SettingsApplied'});
      await startFuture;

      expect(welcome.values, hasLength(1));
      expect(welcome.values.first.requestId, 'req-wire');
      expect(applied.values, hasLength(1));
      // Only the Settings frame was ever sent.
      expect(conn.frames, hasLength(1));
    });

    test('announces connecting → open on connectionStates', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      late final _Recorder<WsConnectionState> states;
      final (_, _) = await harness.startSession(
        onCreated: (DeepgramVoiceAgent agent) {
          states = _Recorder<WsConnectionState>(agent.connectionStates);
        },
      );
      addTearDown(states.dispose);

      expect(states.values, contains(WsConnectionState.connecting));
      expect(states.values, contains(WsConnectionState.open));
      expect(
        states.values.indexOf(WsConnectionState.connecting) <
            states.values.indexOf(WsConnectionState.open),
        isTrue,
      );
    });

    test('times out when the connection never opens', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      server.hangUpgrades = true;
      final harness = _Harness(server);

      final agent = harness.createAgent(
        wsOptions: ResilientWebSocketOptions(
          connectTimeout: const Duration(milliseconds: 200),
          minReconnectDelay: const Duration(milliseconds: 10),
          maxReconnectDelay: const Duration(milliseconds: 10),
        ),
      );

      await expectLater(
        agent.start(_defaultSettings,
            handshakeTimeout: const Duration(milliseconds: 600)),
        throwsA(isA<DeepgramTimeoutException>().having(
          (DeepgramTimeoutException error) => error.message,
          'message',
          'Timed out waiting for the voice agent connection to open.',
        )),
      );
    });

    test('times out when Welcome never arrives', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      final connFuture = server.nextConnection();
      final agent = harness.createAgent();

      await expectLater(
        agent.start(_defaultSettings,
            handshakeTimeout: const Duration(milliseconds: 250)),
        throwsA(isA<DeepgramTimeoutException>().having(
          (DeepgramTimeoutException error) => error.message,
          'message',
          'Timed out waiting for the Welcome message.',
        )),
      );
      // The connection was accepted; the server simply stayed silent.
      await connFuture;
    });

    test('times out when SettingsApplied never arrives', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      final connFuture = server.nextConnection();
      final agent = harness.createAgent();

      final startFuture = agent.start(_defaultSettings,
          handshakeTimeout: const Duration(milliseconds: 250));
      final conn = await connFuture;
      conn.sendJson(<String, dynamic>{
        'type': 'Welcome',
        'request_id': 'req-slow',
      });
      // The Settings frame is sent, but no confirmation follows.
      await conn.nextFrame();
      await expectLater(
        startFuture,
        throwsA(isA<DeepgramTimeoutException>().having(
          (DeepgramTimeoutException error) => error.message,
          'message',
          'Timed out waiting for the SettingsApplied confirmation.',
        )),
      );
    });

    test(
        'fails with DeepgramWebSocketException when the upgrade is refused '
        'twice, then restarts cleanly', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      server.refuseUpgradesRemaining = 2;
      final harness = _Harness(server);

      final agent = harness.createAgent(
        wsOptions: ResilientWebSocketOptions(
          // Fast retry between the two corroborated refusals.
          minReconnectDelay: const Duration(milliseconds: 10),
          maxReconnectDelay: const Duration(milliseconds: 10),
        ),
      );

      await expectLater(
        agent.start(_defaultSettings),
        throwsA(isA<DeepgramWebSocketException>().having(
          (DeepgramWebSocketException error) => error.message,
          'message',
          'Could not open the voice agent connection.',
        )),
      );
      expect(agent.isConnected, isFalse);

      // A later start() on the same client works once the server is healthy.
      server.refuseUpgradesRemaining = 0;
      final connFuture = server.nextConnection();
      final restartFuture = agent.start(_defaultSettings);
      final conn = await connFuture;
      conn.sendJson(<String, dynamic>{
        'type': 'Welcome',
        'request_id': 'req-restart',
      });
      await conn.nextFrame();
      conn.sendJson(<String, dynamic>{'type': 'SettingsApplied'});
      await restartFuture;
      expect(agent.isConnected, isTrue);
    });

    test(
        'an Error frame after Welcome fails the handshake with the server '
        'description and code', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      late final _Recorder<AgentErrorEvent> errors;
      final connFuture = server.nextConnection();
      final agent = harness.createAgent();
      errors = _Recorder<AgentErrorEvent>(agent.errors);
      addTearDown(errors.dispose);

      final startFuture = agent.start(_defaultSettings);
      final conn = await connFuture;
      conn.sendJson(<String, dynamic>{
        'type': 'Welcome',
        'request_id': 'req-err',
      });
      await conn.nextFrame(); // Settings
      conn.sendJson(<String, dynamic>{
        'type': 'Error',
        'description': 'Invalid speak provider.',
        'code': 'SETTINGS_INVALID',
      });
      await expectLater(
        startFuture,
        throwsA(isA<DeepgramWebSocketException>()
            .having(
              (DeepgramWebSocketException error) => error.message,
              'message',
              'Invalid speak provider.',
            )
            .having(
              (DeepgramWebSocketException error) => error.code,
              'code',
              'SETTINGS_INVALID',
            )),
      );
      // The frame was also surfaced on the errors stream.
      expect(errors.values, hasLength(1));
      expect(errors.values.first.description, 'Invalid speak provider.');
    });

    test('a second start() while a session is active is refused', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (_, agent) = await harness.startSession();

      await expectLater(
        agent.start(_defaultSettings),
        throwsA(isA<DeepgramStateException>().having(
          (DeepgramStateException error) => error.message,
          'message',
          contains('already active'),
        )),
      );
    });

    test('a second start() while still connecting is refused', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      server.hangUpgrades = true;
      final harness = _Harness(server);

      final agent = harness.createAgent(
        wsOptions: ResilientWebSocketOptions(
          connectTimeout: const Duration(milliseconds: 200),
        ),
      );

      final firstStart = agent.start(_defaultSettings,
          handshakeTimeout: const Duration(milliseconds: 500));
      // The first attempt is still mid-connect: the socket state is
      // `connecting`, so a concurrent start() is rejected immediately.
      await expectLater(
        agent.start(_defaultSettings),
        throwsA(isA<DeepgramStateException>().having(
          (DeepgramStateException error) => error.message,
          'message',
          contains('already active'),
        )),
      );
      await expectLater(firstStart, throwsA(isA<DeepgramTimeoutException>()));
    });
  });

  // -------------------------------------------------------------------------
  // Client messages: exact wire payloads
  // -------------------------------------------------------------------------

  group('client messages', () {
    test('updateListen wraps the listen block under `listen`', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      agent.updateListen(const AgentListen(
        provider: AgentListenProvider.v1(
          keyterms: <String>['Deepgram', 'voice agent'],
          smartFormat: true,
        ),
      ));
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'UpdateListen',
        'listen': <String, dynamic>{
          'provider': <String, dynamic>{
            'type': 'deepgram',
            'version': 'v1',
            'model': 'nova-3',
            'language': 'en-US',
            'keyterms': <String>['Deepgram', 'voice agent'],
            'smart_format': true,
          },
        },
      });
    });

    test('updateThink wraps the think block under `think`', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      agent.updateThink(AgentThink(
        provider: AgentThinkProvider.anthropic(
          model: 'claude-sonnet-4-20250514',
          temperature: 0.3,
        ),
        prompt: 'You are now a travel agent.',
        functions: const <AgentFunctionDefinition>[
          AgentFunctionDefinition.client(
            name: 'book_hotel',
            description: 'Book a hotel room.',
          ),
        ],
      ));
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'UpdateThink',
        'think': <String, dynamic>{
          'provider': <String, dynamic>{
            'type': 'anthropic',
            'model': 'claude-sonnet-4-20250514',
            'temperature': 0.3,
          },
          'prompt': 'You are now a travel agent.',
          'functions': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'book_hotel',
              'description': 'Book a hotel room.',
              'defer_until_eot': false,
            },
          ],
        },
      });
    });

    test('updateSpeak wraps the speak block under `speak`', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      agent.updateSpeak(const AgentSpeak(
        provider: AgentSpeakProvider(
          model: 'aura-2-andromeda-en',
          speed: 1.1,
        ),
      ));
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'UpdateSpeak',
        'speak': <String, dynamic>{
          'provider': <String, dynamic>{
            'type': 'deepgram',
            'version': 'v1',
            'model': 'aura-2-andromeda-en',
            'speed': 1.1,
          },
        },
      });
    });

    test('updatePrompt replaces the system prompt', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      agent.updatePrompt('You are now a pirate.');
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'UpdatePrompt',
        'prompt': 'You are now a pirate.',
      });
    });

    test('injectUserMessage carries the content', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      agent.injectUserMessage('The user said this out of band.');
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'InjectUserMessage',
        'content': 'The user said this out of band.',
      });
    });

    test('injectAgentMessage carries every behavior value', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      agent.injectAgentMessage('Please hold.');
      agent.injectAgentMessage('You are caller number 2.', behavior: 'queue');
      agent.injectAgentMessage('Stop! A table opened up.',
          behavior: 'interrupt');

      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'InjectAgentMessage',
        'message': 'Please hold.',
        'behavior': 'default',
      });
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'InjectAgentMessage',
        'message': 'You are caller number 2.',
        'behavior': 'queue',
      });
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'InjectAgentMessage',
        'message': 'Stop! A table opened up.',
        'behavior': 'interrupt',
      });
    });

    test('sendFunctionCallResponse echoes id, name, and content', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      agent.sendFunctionCallResponse(
        id: 'call-9',
        name: 'lookup_order',
        content: '{"status":"shipped"}',
      );
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'FunctionCallResponse',
        'id': 'call-9',
        'name': 'lookup_order',
        'content': '{"status":"shipped"}',
      });
    });

    test('forceEndTurn is a single-key message', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      agent.forceEndTurn();
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'ForceEndTurn',
      });
    });

    test('sendCustomToThinkProvider forwards arbitrary JSON content', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      agent.sendCustomToThinkProvider(<String, dynamic>{
        'messages': <String, dynamic>{
          'role': 'user',
          'content': 'unvalidated blob',
        },
      });
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': '__customToThinkProvider',
        'content': <String, dynamic>{
          'messages': <String, dynamic>{
            'role': 'user',
            'content': 'unvalidated blob',
          },
        },
      });

      agent.sendCustomToThinkProvider(42);
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': '__customToThinkProvider',
        'content': 42,
      });
    });

    test('sendAudio streams binary Media frames byte-exact', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      agent.sendAudio(<int>[1, 2, 3, 4]);
      agent.sendAudio(<int>[255, 0, 128]);

      final first = await conn.nextFrame();
      expect(first, isA<List<int>>());
      expect(first as List<int>, <int>[1, 2, 3, 4]);
      final second = await conn.nextFrame();
      expect(second as List<int>, <int>[255, 0, 128]);
    });

    test('outbound sends before start() are silently dropped', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      final agent = harness.createAgent();
      agent.sendAudio(<int>[9, 9]);
      agent.updatePrompt('never dialed');
      agent.forceEndTurn();

      await _quiet();
      // Nothing was ever connected and nothing crashed.
      expect(server.connections, isEmpty);
      expect(agent.isConnected, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // KeepAlive policy: 8 s idle-only, user knobs overridden
  // -------------------------------------------------------------------------

  group('KeepAlive policy', () {
    test(
        'user keep-alive knobs are overridden by the agent policy '
        '(8 s idle-only, no heartbeat within the window)', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      // If the socket honored these options it would emit ~20 heartbeats
      // over the observation window (and unconditional ones at that). The
      // agent client always composes its own policy — one
      // `{"type":"KeepAlive"}` every 8 s, only while idle — so not a single
      // frame may arrive here. (The exact 8 s frame itself is pinned by the
      // agent-messages suite, which tolerates the real-time wait.)
      final (conn, agent) = await harness.startSession(
        wsOptions: ResilientWebSocketOptions(
          keepAliveInterval: const Duration(milliseconds: 80),
          keepAliveMessage: '{"type":"UserHeartbeat"}',
          sendKeepAliveOnlyWhenIdle: false,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(conn.frames, hasLength(1)); // only the handshake Settings

      // The session is still alive and dispatching.
      final conversation =
          _Recorder<AgentConversationText>(agent.conversationText);
      addTearDown(conversation.dispose);
      conn.sendJson(<String, dynamic>{
        'type': 'ConversationText',
        'role': 'assistant',
        'content': 'Still here.',
      });
      expect((await conversation.next).content, 'Still here.');
    }, timeout: const Timeout(Duration(seconds: 5)));
  });

  // -------------------------------------------------------------------------
  // Server events: dispatch by `type`
  // -------------------------------------------------------------------------

  group('server event dispatch', () {
    test('ConversationText merges user and assistant turns on one stream',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final events = _Recorder<AgentConversationText>(agent.conversationText);
      addTearDown(events.dispose);

      conn.sendJson(<String, dynamic>{
        'type': 'ConversationText',
        'role': 'user',
        'content': 'Book me a table for two.',
        'languages_hinted': <String>['en', 'es'],
        'languages': <String>['es'],
      });
      conn.sendJson(<String, dynamic>{
        'type': 'ConversationText',
        'role': 'assistant',
        'content': 'Done — 7 pm, terrace seat.',
      });

      final user = await events.next;
      expect(user.role, 'user');
      expect(user.content, 'Book me a table for two.');
      expect(user.languagesHinted, <String>['en', 'es']);
      expect(user.languages, <String>['es']);

      final assistant = await events.next;
      expect(assistant.role, 'assistant');
      expect(assistant.content, 'Done — 7 pm, terrace seat.');
      expect(assistant.languagesHinted, isNull);
      expect(events.values, hasLength(2));
    });

    test('UserStartedSpeaking and AgentAudioDone fire their void streams',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final userStarted = _Recorder<void>(agent.userStartedSpeaking);
      addTearDown(userStarted.dispose);
      final audioDone = _Recorder<void>(agent.agentAudioDone);
      addTearDown(audioDone.dispose);

      conn.sendJson(<String, dynamic>{'type': 'UserStartedSpeaking'});
      await userStarted.next;
      conn.sendJson(<String, dynamic>{'type': 'AgentAudioDone'});
      await audioDone.next;
      expect(userStarted.values, hasLength(1));
      expect(audioDone.values, hasLength(1));
    });

    test('AgentThinking carries the thought content', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final events = _Recorder<AgentAgentThinking>(agent.agentThinking);
      addTearDown(events.dispose);

      conn.sendJson(<String, dynamic>{
        'type': 'AgentThinking',
        'content': 'Considering Italian restaurants nearby.',
      });
      expect((await events.next).content,
          'Considering Italian restaurants nearby.');
    });

    test('AgentStartedSpeaking carries the per-stage latencies', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final events =
          _Recorder<AgentAgentStartedSpeaking>(agent.agentStartedSpeaking);
      addTearDown(events.dispose);

      conn.sendJson(<String, dynamic>{
        'type': 'AgentStartedSpeaking',
        'total_latency': '0.55',
        'tts_latency': '0.2',
        'ttt_latency': '0.35',
      });
      final event = await events.next;
      expect(event.totalLatency, '0.55');
      expect(event.ttsLatency, '0.2');
      expect(event.tttLatency, '0.35');
    });

    test('LatencyReport exposes every stage figure', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final reports = _Recorder<AgentLatencyReport>(agent.latencyReports);
      addTearDown(reports.dispose);

      conn.sendJson(<String, dynamic>{
        'type': 'LatencyReport',
        'stt_latency': '0.31',
        'ttt_token_latency': '0.22',
        'ttt_text_latency': '0.24',
        'ttt_tool_latency': '0.28',
        'ttt_thinking_latency': '0.26',
        'tts_latency': '0.18',
        'total_latency': '0.73',
      });
      final report = await reports.next;
      expect(report.sttLatency, '0.31');
      expect(report.tttTokenLatency, '0.22');
      expect(report.tttTextLatency, '0.24');
      expect(report.tttToolLatency, '0.28');
      expect(report.tttThinkingLatency, '0.26');
      expect(report.ttsLatency, '0.18');
      expect(report.totalLatency, '0.73');
    });

    test('FunctionCallRequest is answered with an exact wire response',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final requests =
          _Recorder<AgentFunctionCallRequest>(agent.functionCallRequests);
      addTearDown(requests.dispose);

      conn.sendJson(<String, dynamic>{
        'type': 'FunctionCallRequest',
        'functions': <dynamic>[
          <String, dynamic>{
            'id': 'call-1',
            'name': 'get_weather',
            'arguments': '{"city":"SF"}',
            'client_side': true,
            'thought_signature': 'sig-1',
          },
          <String, dynamic>{
            'id': 'call-2',
            'name': 'check_order',
            'arguments': '{"id":7}',
            'client_side': false,
          },
        ],
      });

      final event = await requests.next;
      expect(event.functions, hasLength(2));
      final first = event.functions.first;
      expect(first.id, 'call-1');
      expect(first.name, 'get_weather');
      expect(first.arguments, '{"city":"SF"}');
      expect(first.clientSide, isTrue);
      expect(first.thoughtSignature, 'sig-1');
      expect(event.functions[1].clientSide, isFalse);

      // The documented reply: id, name, and the result content.
      agent.sendFunctionCallResponse(
        id: first.id,
        name: first.name,
        content: '{"temp_f":62}',
      );
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'FunctionCallResponse',
        'id': 'call-1',
        'name': 'get_weather',
        'content': '{"temp_f":62}',
      });
    });

    test('FunctionCallCancelled exposes the cancelled ids', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final cancelled =
          _Recorder<AgentFunctionCallCancelled>(agent.functionCallCancelled);
      addTearDown(cancelled.dispose);

      conn.sendJson(<String, dynamic>{
        'type': 'FunctionCallCancelled',
        'functions': <dynamic>[
          <String, dynamic>{'id': 'call-1', 'name': 'get_weather'},
          <String, dynamic>{'id': 'call-2', 'name': 'check_order'},
        ],
      });
      final event = await cancelled.next;
      expect(event.functions, hasLength(2));
      expect(event.functions.map((AgentCancelledFunction f) => f.id),
          <String>['call-1', 'call-2']);
    });

    test('InjectionRefused, Error, and Warning reach their streams', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final refusals = _Recorder<AgentInjectionRefused>(agent.injectionRefused);
      addTearDown(refusals.dispose);
      final errors = _Recorder<AgentErrorEvent>(agent.errors);
      addTearDown(errors.dispose);
      final warnings = _Recorder<AgentWarningEvent>(agent.warnings);
      addTearDown(warnings.dispose);

      conn.sendJson(<String, dynamic>{
        'type': 'InjectionRefused',
        'message': 'Injection refused mid-turn.',
      });
      expect((await refusals.next).message, 'Injection refused mid-turn.');

      // A post-handshake Error frame is surfaced, not fatal to the client.
      conn.sendJson(<String, dynamic>{
        'type': 'Error',
        'description': 'Upstream LLM unavailable.',
        'code': 'THINK_PROVIDER_ERROR',
      });
      final error = await errors.next;
      expect(error.description, 'Upstream LLM unavailable.');
      expect(error.code, 'THINK_PROVIDER_ERROR');

      conn.sendJson(<String, dynamic>{
        'type': 'Warning',
        'description': 'Buffering audio while disconnected.',
        'code': 'NET_WARNING',
      });
      final warning = await warnings.next;
      expect(warning.description, 'Buffering audio while disconnected.');
      expect(warning.code, 'NET_WARNING');
      expect(agent.isConnected, isTrue);
    });

    test('History events reach the history stream (text + function calls)',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final events = _Recorder<AgentHistoryEvent>(agent.history);
      addTearDown(events.dispose);

      conn.sendJson(<String, dynamic>{
        'type': 'History',
        'role': 'assistant',
        'content': 'Your table is ready.',
      });
      final text = await events.next;
      expect(text.role, 'assistant');
      expect(text.content, 'Your table is ready.');
      expect(text.functionCalls, isNull);

      conn.sendJson(<String, dynamic>{
        'type': 'History',
        'function_calls': <dynamic>[
          <String, dynamic>{
            'id': 'call-5',
            'name': 'reserve',
            'arguments': '{"party":2}',
            'response': '{"ok":true}',
            'client_side': true,
          },
        ],
      });
      final calls = await events.next;
      expect(calls.role, isNull);
      expect(calls.content, isNull);
      expect(calls.functionCalls, hasLength(1));
      expect(calls.functionCalls!.first.name, 'reserve');
      expect(calls.functionCalls!.first.response, '{"ok":true}');
      expect(calls.functionCalls!.first.clientSide, isTrue);
    });

    test('provider updates surface on providerUpdates', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      // Subscribe before the handshake: the SettingsApplied emitted while
      // `start()` completes is broadcast and never replayed.
      late final _Recorder<String> updates;
      final (conn, agent) = await harness.startSession(
        onCreated: (DeepgramVoiceAgent created) {
          updates = _Recorder<String>(created.providerUpdates);
        },
      );
      addTearDown(updates.dispose);

      // SettingsApplied during the handshake already arrived.
      expect(updates.values, <String>['SettingsApplied']);

      conn.sendJson(<String, dynamic>{'type': 'ListenUpdated'});
      conn.sendJson(<String, dynamic>{'type': 'ThinkUpdated'});
      conn.sendJson(<String, dynamic>{'type': 'SpeakUpdated'});
      conn.sendJson(<String, dynamic>{'type': 'PromptUpdated'});

      await updates.seen(5, (String kind) => true);
      expect(updates.values, <String>[
        'SettingsApplied',
        'ListenUpdated',
        'ThinkUpdated',
        'SpeakUpdated',
        'PromptUpdated',
      ]);
    });

    test('__customFromThinkProvider payloads pass through unchanged', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final payloads =
          _Recorder<AgentCustomThinkPayload>(agent.customThinkProviderMessages);
      addTearDown(payloads.dispose);

      conn.sendJson(<String, dynamic>{
        'type': '__customFromThinkProvider',
        'content': <String, dynamic>{'provider': 'says', 'n': 3},
      });
      final payload = await payloads.next;
      expect(payload.content, <String, dynamic>{'provider': 'says', 'n': 3});
    });

    test('binary frames feed the audio stream; empty ones are dropped',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final audio = _Recorder<List<int>>(agent.audio);
      addTearDown(audio.dispose);

      conn.sendBytes(<int>[10, 20, 30]);
      expect(await audio.next, <int>[10, 20, 30]);

      conn.sendBytes(<int>[]);
      await _quiet();
      expect(audio.values, hasLength(1));
    });

    test('unknown and untyped frames are ignored without breaking the pump',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final logger = RecordingLogger();
      final (conn, agent) = await harness.startSession(logger: logger);

      final conversation =
          _Recorder<AgentConversationText>(agent.conversationText);
      addTearDown(conversation.dispose);

      conn.sendJson(<String, dynamic>{'type': 'SpaceAliens', 'beam': 'up'});
      conn.sendJson(<String, dynamic>{'type': 42});
      conn.sendJson(<String, dynamic>{'nonsense': true});
      await _quiet();

      expect(conversation.values, isEmpty);
      expect(agent.isConnected, isTrue);

      // The pump is still alive: a known type keeps flowing.
      conn.sendJson(<String, dynamic>{
        'type': 'ConversationText',
        'role': 'assistant',
        'content': 'Still here.',
      });
      expect((await conversation.next).content, 'Still here.');
    });

    test('malformed frames surface as SchemaError warnings, never crash',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final warnings = _Recorder<AgentWarningEvent>(agent.warnings);
      addTearDown(warnings.dispose);
      final conversation =
          _Recorder<AgentConversationText>(agent.conversationText);
      addTearDown(conversation.dispose);

      // Undecodable JSON.
      conn.sendText('{not valid json');
      final first = await warnings.next;
      expect(first.code, 'SchemaError');
      expect(first.description, contains('Malformed JSON frame'));

      // Valid JSON that is not an object.
      conn.sendText('[1, 2, 3]');
      expect(
          (await warnings.next).description, 'Expected a JSON object frame.');
      conn.sendText('"a bare string"');
      expect(
          (await warnings.next).description, 'Expected a JSON object frame.');
      conn.sendText('null');
      expect(
          (await warnings.next).description, 'Expected a JSON object frame.');

      // A binary-only session keeps working after all of the above.
      expect(agent.isConnected, isTrue);
      conn.sendJson(<String, dynamic>{
        'type': 'ConversationText',
        'role': 'user',
        'content': 'Still audible.',
      });
      expect((await conversation.next).content, 'Still audible.');
      expect(warnings.values, hasLength(4));
    });
  });

  // -------------------------------------------------------------------------
  // Reconnection
  // -------------------------------------------------------------------------

  group('reconnection', () {
    test(
        'an unexpected drop reconnects, re-Welcomes, and re-sends Settings '
        'after the user callback', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      DeepgramVoiceAgent? agentSlot;
      final callbackOrder = <String>[];
      final reconnectingEvents = <WsReconnectContext>[];
      final wsOptions = ResilientWebSocketOptions(
        // Long enough to observe the in-flight reconnect attempt
        // deterministically before the redial lands.
        minReconnectDelay: const Duration(milliseconds: 150),
        maxReconnectDelay: const Duration(milliseconds: 150),
        onReconnecting: (WsReconnectContext context) {
          reconnectingEvents.add(context);
        },
        onReconnected: () {
          callbackOrder.add('user');
          agentSlot?.updatePrompt('user callback ran first');
        },
      );

      // Subscribe before the handshake so both Welcome frames are captured
      // (broadcast streams do not replay past events).
      late final _Recorder<AgentWelcome> welcomes;
      late final _Recorder<WsConnectionState> states;
      final (conn1, agent) = await harness.startSession(
        wsOptions: wsOptions,
        onCreated: (DeepgramVoiceAgent created) {
          agentSlot = created;
          welcomes = _Recorder<AgentWelcome>(created.welcome);
          states = _Recorder<WsConnectionState>(created.connectionStates);
        },
      );
      addTearDown(welcomes.dispose);
      addTearDown(states.dispose);

      // Drop the first connection; the socket reconnects after its backoff.
      final conn2Future = server.nextConnection();
      await conn1.drop();
      await states.waitFor(
          (WsConnectionState state) => state == WsConnectionState.reconnecting);
      // The reconnect attempt is observable while it is in flight.
      expect(agent.reconnectAttempts, 1);
      final conn2 = await conn2Future;
      conn2.sendJson(<String, dynamic>{
        'type': 'Welcome',
        'request_id': 'req-reconnect',
      });

      // The user callback runs BEFORE the Settings re-send.
      final promptFrame = _decode(await conn2.nextFrame());
      expect(promptFrame, <String, dynamic>{
        'type': 'UpdatePrompt',
        'prompt': 'user callback ran first',
      });
      expect(_decode(await conn2.nextFrame()), _defaultSettings.toJson());
      expect(callbackOrder, <String>['user']);

      // The reconnect context describes the first (and only) attempt; the
      // delay is the 150 ms bound plus the policy's ±25% jitter.
      expect(reconnectingEvents, hasLength(1));
      expect(reconnectingEvents.first.attempt, 1);
      expect(
        reconnectingEvents.first.nextDelay.inMilliseconds,
        inInclusiveRange(112, 188),
      );

      expect(welcomes.values, hasLength(2));
      expect(welcomes.values.last.requestId, 'req-reconnect');
      expect(agent.isConnected, isTrue);
      // The attempt counter reset after the successful reconnect.
      expect(agent.reconnectAttempts, 0);
    });

    test(
        'a reconnect before the handshake completed does not re-send '
        'Settings', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      final wsOptions = ResilientWebSocketOptions(
        minReconnectDelay: const Duration(milliseconds: 50),
        maxReconnectDelay: const Duration(milliseconds: 50),
      );

      // The handshake never completes: no Welcome on the first connection.
      final conn1Future = server.nextConnection();
      final agent = harness.createAgent(wsOptions: wsOptions);
      final startFuture = agent.start(_defaultSettings,
          handshakeTimeout: const Duration(milliseconds: 250));
      final conn1 = await conn1Future;
      await expectLater(startFuture, throwsA(isA<DeepgramTimeoutException>()));

      // The unexpected drop still triggers a redial...
      final conn2Future = server.nextConnection();
      await conn1.drop();
      final conn2 = await conn2Future;
      conn2.sendJson(<String, dynamic>{
        'type': 'Welcome',
        'request_id': 'req-no-resend',
      });

      // ...but no Settings may follow: the initial handshake never finished.
      await _quiet(400);
      expect(conn2.frames, isEmpty);
    });

    test('autoReconnect: false gives up after a drop without redialing',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      late final _Recorder<WsConnectionState> states;
      final (conn1, agent) = await harness.startSession(
        wsOptions: ResilientWebSocketOptions(autoReconnect: false),
        onCreated: (DeepgramVoiceAgent created) {
          states = _Recorder<WsConnectionState>(created.connectionStates);
        },
      );
      addTearDown(states.dispose);

      await conn1.drop();
      await states.waitFor(
          (WsConnectionState state) => state == WsConnectionState.failed);
      await _quiet(250);

      expect(agent.isConnected, isFalse);
      expect(server.connections, hasLength(1)); // no second dial
    });
  });

  // -------------------------------------------------------------------------
  // Close lifecycle
  // -------------------------------------------------------------------------

  group('close lifecycle', () {
    test(
        'close() releases every stream, is idempotent, and refuses a '
        'restart; later sends are no-ops', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      // The agent sends no close message of its own, so the drain window is
      // bounded by the server hanging up — hang up shortly after close()
      // begins, like the real agent server does at session end.
      final closing = agent.close();
      unawaited(Future<void>.delayed(const Duration(milliseconds: 100))
          .then((_) => conn.hangUp()));
      await closing;

      // Every stream controller is closed: late listeners see done.
      await expectLater(agent.welcome, emitsDone);
      await expectLater(agent.conversationText, emitsDone);
      await expectLater(agent.errors, emitsDone);
      await expectLater(agent.audio, emitsDone);
      await expectLater(agent.settingsApplied, emitsDone);
      await expectLater(conn.done, completes);
      expect(agent.isConnected, isFalse);

      // Idempotent.
      await agent.close();

      // A fresh session is refused after the close.
      await expectLater(
        agent.start(_defaultSettings),
        throwsA(isA<DeepgramStateException>().having(
          (DeepgramStateException error) => error.message,
          'message',
          'This voice agent has been closed.',
        )),
      );

      // Sends after the close are silent no-ops, never throws.
      final framesBefore = conn.frames.length;
      agent.sendAudio(<int>[9, 9]);
      agent.updatePrompt('ignored');
      agent.injectUserMessage('ignored');
      await _quiet();
      expect(conn.frames, hasLength(framesBefore));
    });

    test('close() before start() completes and blocks any later start()',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      final agent = harness.createAgent();
      await agent.close();

      expect(agent.isConnected, isFalse);
      await expectLater(
        agent.start(_defaultSettings),
        throwsA(isA<DeepgramStateException>().having(
          (DeepgramStateException error) => error.message,
          'message',
          'This voice agent has been closed.',
        )),
      );
      expect(server.connections, isEmpty);
    });

    test('forceClose() tears down immediately and swallows later sends',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      await agent.forceClose();
      expect(agent.isConnected, isFalse);
      await expectLater(agent.welcome, emitsDone);
      await expectLater(conn.done, completes);

      // Sends after the close are no-ops, never throws.
      agent.sendAudio(<int>[9, 9]);
      agent.updatePrompt('ignored');
      await _quiet();
      expect(conn.frames, hasLength(1)); // only the handshake Settings

      // Idempotent.
      await agent.forceClose();
    });
  });
}
