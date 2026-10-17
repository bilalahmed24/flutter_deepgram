/// Unit tests for `lib/src/speak/speak_stream_client.dart` — the continuous
/// text-to-speech client over `WSS /v1/speak`.
///
/// `TtsStreamClient` builds its own `ResilientWebSocket` with the default
/// platform factory (there is no wsFactory injection point on the client), so
/// these tests drive the real socket stack against a scriptable WebSocket
/// server bound to `127.0.0.1` on an ephemeral port with `useTls: false` and
/// a reserved `.test` hostname. Everything stays on loopback — no external
/// network is touched.
///
/// Coverage: the connection wire (path, options query, Token auth), audio
/// binary frames, Metadata/Flushed/Cleared/Warning JSON events, exact client
/// message JSON (Speak/Flush/Clear/Close/KeepAlive), malformed-frame
/// handling, the defensive model parsers, and the full lifecycle (start,
/// double-start, graceful close with drain, forceClose, refused upgrades,
/// reconnect after a server drop, and DeepgramStateException after close).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';

const Duration _waitTimeout = Duration(seconds: 3);

/// Socket options that reconnect almost instantly.
const ResilientWebSocketOptions _fastWsOptions = ResilientWebSocketOptions(
  minReconnectDelay: Duration(milliseconds: 1),
  maxReconnectDelay: Duration(milliseconds: 5),
  keepAliveInterval: Duration(minutes: 30),
);

/// Policy that always gives up after the first failed attempt.
const ResilientWebSocketOptions _giveUpWsOptions = ResilientWebSocketOptions(
  minReconnectDelay: Duration(milliseconds: 1),
  maxReconnectDelay: Duration(milliseconds: 5),
  keepAliveInterval: Duration(minutes: 30),
  shouldReconnect: _neverReconnect,
);

bool _neverReconnect(WsCloseContext context) => false;

// ---------------------------------------------------------------------------
// Host routing: point the fake Deepgram host at the loopback server
// ---------------------------------------------------------------------------

const String _deepgramTestHost = 'deepgram.test';

/// Routes [_deepgramTestHost] to the current loopback server port.
class _Router {
  /// Loopback port to route to; `0` routes nowhere.
  int port = 0;

  /// Rewrites Deepgram test URLs to the loopback server.
  Uri rewrite(Uri url) {
    if (url.host == _deepgramTestHost && port != 0) {
      return url.replace(host: '127.0.0.1', port: port);
    }
    return url;
  }
}

final _Router _router = _Router();

/// Installs [_router] for every `dart:io` HttpClient created in this isolate.
///
/// `TtsStreamClient` builds its own `ResilientWebSocket` with the default
/// `IoWsFactory`, and `WebSocket.connect` caches one static `HttpClient` on
/// first use — so the override must be installed before the first
/// connection. All traffic stays on loopback.
class _RoutingHttpOverrides extends HttpOverrides {
  _RoutingHttpOverrides(this._inner);

  final HttpClient _inner;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _RoutingHttpClient(_inner);
}

class _RoutingHttpClient implements HttpClient {
  _RoutingHttpClient(this._inner);

  final HttpClient _inner;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _inner.openUrl(method, _router.rewrite(url));

  // The top-level `http.head` used by the connectivity probe closes the
  // client it creates; keep the shared inner client alive instead.
  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected HttpClient member used by the speak stream tests: '
    '${invocation.memberName}',
  );
}

// ---------------------------------------------------------------------------
// Loopback /v1/speak server harness
// ---------------------------------------------------------------------------

/// One accepted server-side WebSocket connection.
class _ServerConn {
  _ServerConn(this.request, this.socket);

  /// The upgrade request (URI + headers as sent by the SDK).
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
    socket.cast<Object>().listen(
      (Object frame) {
        frames.add(frame);
        if (_frameWaiters.isNotEmpty) {
          _frameWaiters.removeAt(0).complete(frame);
        } else {
          _pendingFrames.add(frame);
        }
      },
      onDone: _markDone,
      onError: (Object _) => _markDone(),
    );
  }

  /// Resolves with the next frame the SDK sends (already-received frames are
  /// replayed in order).
  Future<Object> nextFrame() {
    if (_pendingFrames.isNotEmpty) {
      return Future<Object>.value(_pendingFrames.removeAt(0));
    }
    final waiter = Completer<Object>();
    _frameWaiters.add(waiter);
    return waiter.future.timeout(
      _waitTimeout,
      onTimeout: () {
        throw TimeoutException(
          'No frame within $_waitTimeout. '
          'Frames so far: $frames',
        );
      },
    );
  }

  /// Resolves once the socket is closed from either side.
  Future<void> get done {
    if (_done) return Future<void>.value();
    final waiter = Completer<void>();
    _doneWaiters.add(waiter);
    return waiter.future.timeout(
      _waitTimeout,
      onTimeout: () => throw TimeoutException('Socket stayed open.'),
    );
  }

  /// Sends a text frame.
  void sendText(String text) => socket.add(text);

  /// Sends a binary frame.
  void sendBytes(List<int> bytes) => socket.add(bytes);

  /// Simulates an unexpected server-side disconnect.
  Future<void> drop() => socket.close(1011, 'unexpected drop');

  /// Closes the connection cleanly from the server side.
  Future<void> closeNormally() => socket.close(1000, 'bye');

  void _markDone() {
    if (_done) return;
    _done = true;
    for (final waiter in _doneWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _doneWaiters.clear();
  }
}

/// A scriptable WebSocket server standing in for `wss://api.deepgram.com`.
class _LoopbackSpeakServer {
  _LoopbackSpeakServer._();

  late final HttpServer _server;
  late final StreamSubscription<HttpRequest> _serverSub;

  /// Accepted connections, in order.
  final List<_ServerConn> connections = <_ServerConn>[];

  /// Non-upgrade requests received (connectivity-probe HEADs).
  final List<HttpRequest> plainRequests = <HttpRequest>[];

  final List<Completer<_ServerConn>> _connWaiters = <Completer<_ServerConn>>[];
  final List<_ServerConn> _readyConns = <_ServerConn>[];

  /// How many upcoming upgrade attempts to refuse with HTTP 401.
  int refuseUpgradesRemaining = 0;

  /// Number of upgrades refused so far.
  int refusedUpgrades = 0;

  /// Status code answered to plain (probe) requests.
  int probeStatus = 200;

  /// Binds the server to loopback on an ephemeral port.
  static Future<_LoopbackSpeakServer> start() async {
    final instance = _LoopbackSpeakServer._();
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
  Future<_ServerConn> nextConnection() {
    if (_readyConns.isNotEmpty) {
      return Future<_ServerConn>.value(_readyConns.removeAt(0));
    }
    final waiter = Completer<_ServerConn>();
    _connWaiters.add(waiter);
    return waiter.future.timeout(
      _waitTimeout,
      onTimeout: () =>
          throw TimeoutException('No connection within $_waitTimeout.'),
    );
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
        if (refuseUpgradesRemaining > 0) {
          refuseUpgradesRemaining--;
          refusedUpgrades++;
          request.response.statusCode = 401;
          await request.response.close();
          return;
        }
        final conn = _ServerConn(
          request,
          await WebSocketTransformer.upgrade(request),
        );
        connections.add(conn);
        conn.pump();
        if (_connWaiters.isNotEmpty) {
          _connWaiters.removeAt(0).complete(conn);
        } else {
          _readyConns.add(conn);
        }
        return;
      }
      plainRequests.add(request);
      request.response.statusCode = probeStatus;
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
///
/// [next] uses a cursor over [values], so it is deterministic even when the
/// event was already recorded before the call.
class _Recorder<T> {
  _Recorder(Stream<T> stream) {
    _sub = stream.listen(_add, onError: _addError, onDone: _markDone);
  }

  late final StreamSubscription<T> _sub;

  /// Every event seen so far, in order.
  final List<T> values = <T>[];

  /// Errors seen on the stream, if any.
  final List<Object> errors = <Object>[];

  final Completer<void> _doneCompleter = Completer<void>();
  int _cursor = 0;
  final List<_PredicateWait<T>> _predicateWaiters = <_PredicateWait<T>>[];
  final List<_CountWait<T>> _countWaiters = <_CountWait<T>>[];
  bool _done = false;

  /// Resolves once the stream is done (bounded).
  Future<void> get onDone => _doneCompleter.future.timeout(
    _waitTimeout,
    onTimeout: () => throw TimeoutException('Stream was not done in time.'),
  );

  /// Resolves with the next unconsumed event, in order.
  ///
  /// A dedicated cursor (advanced only by [next]) means an event that was
  /// recorded before the call is still returned rather than skipped.
  Future<T> get next {
    final int index = _cursor;
    _cursor++;
    return _atIndex(index);
  }

  /// Resolves with the first recorded (or next) event matching [predicate].
  Future<T> waitFor(bool Function(T) predicate) {
    for (final T value in values) {
      if (predicate(value)) return Future<T>.value(value);
    }
    final wait = _PredicateWait<T>(predicate);
    _predicateWaiters.add(wait);
    return wait.completer.future.timeout(
      _waitTimeout,
      onTimeout: () {
        _predicateWaiters.remove(wait);
        throw TimeoutException(
          'No matching event within $_waitTimeout. '
          'Recorded: $values',
        );
      },
    );
  }

  /// Resolves once [n] matching events have been recorded.
  Future<void> seen(int n, bool Function(T) predicate) {
    if (_countOf(predicate) >= n) return Future<void>.value();
    final wait = _CountWait<T>(n, predicate);
    _countWaiters.add(wait);
    return wait.completer.future.timeout(
      _waitTimeout,
      onTimeout: () {
        _countWaiters.remove(wait);
        throw TimeoutException(
          'Only ${_countOf(predicate)} of $n matching '
          'events within $_waitTimeout. Recorded: $values',
        );
      },
    );
  }

  /// Stops recording.
  Future<void> dispose() => _sub.cancel();

  Future<T> _atIndex(int index) {
    if (index < values.length) {
      return Future<T>.value(values[index]);
    }
    final waiter = Completer<T>();
    _indexWaiters.add(_IndexWait<T>(index, waiter));
    return waiter.future.timeout(
      _waitTimeout,
      onTimeout: () {
        _indexWaiters.removeWhere(
          (_IndexWait<T> wait) => wait.completer == waiter,
        );
        throw TimeoutException(
          'No event at position $index within '
          '$_waitTimeout. Recorded: $values',
        );
      },
    );
  }

  final List<_IndexWait<T>> _indexWaiters = <_IndexWait<T>>[];

  int _countOf(bool Function(T) predicate) => values.where(predicate).length;

  void _add(T value) {
    values.add(value);
    final int index = values.length - 1;
    _indexWaiters.removeWhere((_IndexWait<T> wait) {
      if (wait.index == index && !wait.completer.isCompleted) {
        wait.completer.complete(value);
        return true;
      }
      return false;
    });
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

  void _markDone() {
    if (_done) return;
    _done = true;
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }
}

class _IndexWait<T> {
  _IndexWait(this.index, this.completer);

  final int index;
  final Completer<T> completer;
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

/// Captures the error thrown by [action] (or `null` when it completes).
///
/// The action is deferred so synchronous throws (the speak methods validate
/// text before returning a future) are captured as well.
Future<Object?> _failureOf(FutureOr<Object?> Function() action) async {
  try {
    await action();
    return null;
  } catch (error) {
    return error;
  }
}

/// Pumps the event loop a couple of turns (broadcast controllers deliver
/// asynchronously).
Future<void> _pumpEventLoop() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

/// Compares two byte lists for equality.
bool listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// An [http.Client] that forwards to a [QueueHttpClient] through
/// [http.BaseClient].
class _ForwardingClient extends http.BaseClient {
  _ForwardingClient(this._queue);

  final QueueHttpClient _queue;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _queue.send(request);
}

/// Wires a config, auth, HTTP engine, and logger against [server].
class _Harness {
  _Harness(this.server)
    : config = DeepgramConfig(
        apiKey: 'test-api-key',
        baseUrl: _deepgramTestHost,
        useTls: false,
        requestTimeout: const Duration(seconds: 2),
        connectTimeout: const Duration(seconds: 2),
        maxRetries: 2,
        retryBaseDelay: const Duration(milliseconds: 1),
        retryMaxDelay: const Duration(milliseconds: 5),
      ) {
    _router.port = server.port;
    auth = DeepgramAuth(config);
    httpEngine = HttpEngine(
      config: config,
      auth: auth,
      client: _ForwardingClient(queue),
    );
  }

  /// The loopback server.
  final _LoopbackSpeakServer server;

  /// Config pointing at the loopback server over plain ws/http.
  final DeepgramConfig config;

  /// Credential manager (Token auth).
  late final DeepgramAuth auth;

  /// HTTP engine (required by the client constructor; this client never
  /// issues HTTP requests).
  late final HttpEngine httpEngine;

  /// Queued HTTP responses (unused on this client's path).
  final QueueHttpClient queue = QueueHttpClient();

  /// Records every log line the client emits.
  final RecordingLogger logger = RecordingLogger();

  /// Builds a TTS stream client wired exactly like the facade does.
  TtsStreamClient client({
    SpeakOptions? options,
    ResilientWebSocketOptions? wsOptions,
  }) {
    return TtsStreamClient(
      config: config,
      auth: auth,
      http: httpEngine,
      options: options,
      wsOptions: wsOptions,
      logger: logger,
    );
  }
}

void main() {
  // Install host routing before anything in this isolate creates a
  // dart:io HttpClient — dart:io's WebSocket.connect caches its static
  // HttpClient on first use.
  final HttpClient routingInnerClient = HttpClient();
  HttpOverrides.global = _RoutingHttpOverrides(routingInnerClient);

  group('TtsMetadataMessage.fromJson (defensive parsing)', () {
    test('parses a full Metadata frame', () {
      final TtsMetadataMessage metadata = TtsMetadataMessage.fromJson(
        <String, dynamic>{
          'type': 'Metadata',
          'request_id': 'req-1',
          'model_name': 'aura-2-thalia-en',
          'model_version': '1.0.2',
          'model_uuid': 'uuid-1',
          'additional_model_uuids': <String>['uuid-2', 'uuid-3'],
        },
      );
      expect(metadata.requestId, 'req-1');
      expect(metadata.modelName, 'aura-2-thalia-en');
      expect(metadata.modelVersion, '1.0.2');
      expect(metadata.modelUuid, 'uuid-1');
      expect(metadata.additionalModelUuids, <String>['uuid-2', 'uuid-3']);
    });

    test('missing fields fall back to empty values', () {
      final TtsMetadataMessage metadata = TtsMetadataMessage.fromJson(
        <String, dynamic>{},
      );
      expect(metadata.requestId, '');
      expect(metadata.modelName, '');
      expect(metadata.modelVersion, '');
      expect(metadata.modelUuid, '');
      expect(metadata.additionalModelUuids, isEmpty);
    });

    test('wrongly-typed fields fall back defensively', () {
      final TtsMetadataMessage metadata = TtsMetadataMessage.fromJson(
        <String, dynamic>{
          'request_id': 42,
          'model_name': null,
          'model_version': <String>['1.0'],
          'model_uuid': true,
          'additional_model_uuids': 'not-a-list',
        },
      );
      expect(metadata.requestId, '');
      expect(metadata.modelName, '');
      expect(metadata.modelVersion, '');
      expect(metadata.modelUuid, '');
      expect(metadata.additionalModelUuids, isEmpty);
    });

    test('non-string entries in additional_model_uuids are skipped', () {
      final TtsMetadataMessage metadata = TtsMetadataMessage.fromJson(
        <String, dynamic>{
          'additional_model_uuids': <dynamic>['uuid-2', 42, null, 'uuid-3'],
        },
      );
      expect(metadata.additionalModelUuids, <String>['uuid-2', 'uuid-3']);
    });
  });

  group('TtsWarning.fromJson (defensive parsing)', () {
    test('parses code and description', () {
      final TtsWarning warning = TtsWarning.fromJson(<String, dynamic>{
        'type': 'Warning',
        'code': 'NO_SYNTHESIZABLE_TEXT',
        'description': 'No text was synthesizable.',
      });
      expect(warning.code, 'NO_SYNTHESIZABLE_TEXT');
      expect(warning.description, 'No text was synthesizable.');
    });

    test('missing or wrongly-typed fields fall back to empty strings', () {
      final TtsWarning warning = TtsWarning.fromJson(<String, dynamic>{
        'code': 7,
        'description': <String>['x'],
      });
      expect(warning.code, '');
      expect(warning.description, '');
    });
  });

  group(
    'TtsStreamClient (loopback /v1/speak server)',
    timeout: const Timeout(Duration(seconds: 5)),
    () {
      test('start() opens ws://host/v1/speak with the option query and Token '
          'authorization header', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(
          options: const SpeakOptions(
            model: DeepgramVoices.aura2ThaliaEn,
            encoding: TtsEncoding.linear16,
            sampleRate: 16000,
            speed: 1.2,
            tag: <String>['env:test', 'run:7'],
            mipOptOut: true,
          ),
          wsOptions: _fastWsOptions,
        );
        addTearDown(client.forceClose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        expect(client.isConnected, isTrue);
        expect(conn.request.uri.path, '/v1/speak');
        final Map<String, List<String>> query =
            conn.request.uri.queryParametersAll;
        expect(query['model'], <String>['aura-2-thalia-en']);
        expect(query['encoding'], <String>['linear16']);
        expect(query['sample_rate'], <String>['16000']);
        expect(query['speed'], <String>['1.2']);
        expect(query['tag'], <String>['env:test', 'run:7']);
        expect(query['mip_opt_out'], <String>['true']);
        expect(
          conn.request.headers.value('Authorization'),
          'Token test-api-key',
        );
      });

      test('start() without options sends a bare path', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        expect(conn.request.uri.path, '/v1/speak');
        expect(conn.request.uri.queryParameters, isEmpty);
      });

      test('binary audio frames surface on the audio stream', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);
        final audio = _Recorder<List<int>>(client.audio);
        addTearDown(audio.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        conn.sendBytes(<int>[1, 2, 3]);
        conn.sendBytes(<int>[255, 0, 128]);

        expect(await audio.next, <int>[1, 2, 3]);
        expect(await audio.next, <int>[255, 0, 128]);
        expect(audio.values, hasLength(2));
      });

      test('Metadata frames surface as typed TtsMetadataMessage', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);
        final metadata = _Recorder<TtsMetadataMessage>(client.metadata);
        addTearDown(metadata.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        conn.sendText(
          jsonEncode(<String, Object>{
            'type': 'Metadata',
            'request_id': 'req-meta',
            'model_name': 'aura-2-thalia-en',
            'model_version': '1.0.2',
            'model_uuid': 'uuid-1',
            'additional_model_uuids': <String>['uuid-2'],
          }),
        );

        final TtsMetadataMessage event = await metadata.next;
        expect(event.requestId, 'req-meta');
        expect(event.modelName, 'aura-2-thalia-en');
        expect(event.modelVersion, '1.0.2');
        expect(event.modelUuid, 'uuid-1');
        expect(event.additionalModelUuids, <String>['uuid-2']);
      });

      test(
        'Flushed sequence ids parse as int, numeric string, and double',
        () async {
          final server = await _LoopbackSpeakServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          addTearDown(client.forceClose);
          final flushed = _Recorder<int>(client.flushed);
          addTearDown(flushed.dispose);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;

          conn.sendText('{"type":"Flushed","sequence_id":7}');
          conn.sendText('{"type":"Flushed","sequence_id":"42"}');
          conn.sendText('{"type":"Flushed","sequence_id":9.5}');

          expect(await flushed.next, 7);
          expect(await flushed.next, 42);
          expect(await flushed.next, 9);
        },
      );

      test('Cleared frames surface on the cleared stream', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);
        final cleared = _Recorder<int>(client.cleared);
        addTearDown(cleared.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        conn.sendText('{"type":"Cleared","sequence_id":3}');
        expect(await cleared.next, 3);
      });

      test('Warning frames surface as typed TtsWarning', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);
        final warnings = _Recorder<TtsWarning>(client.warnings);
        addTearDown(warnings.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        conn.sendText(
          jsonEncode(<String, Object>{
            'type': 'Warning',
            'code': 'SYNTHESIS_RETRYING',
            'description': 'Retrying synthesis.',
          }),
        );

        final TtsWarning warning = await warnings.next;
        expect(warning.code, 'SYNTHESIS_RETRYING');
        expect(warning.description, 'Retrying synthesis.');
      });

      test('Flushed/Cleared frames without a valid sequence_id are dropped '
          'with a MALFORMED_FRAME warning', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);
        final flushed = _Recorder<int>(client.flushed);
        addTearDown(flushed.dispose);
        final cleared = _Recorder<int>(client.cleared);
        addTearDown(cleared.dispose);
        final warnings = _Recorder<TtsWarning>(client.warnings);
        addTearDown(warnings.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        conn.sendText('{"type":"Flushed"}');
        conn.sendText('{"type":"Flushed","sequence_id":"not-a-number"}');
        conn.sendText('{"type":"Flushed","sequence_id":true}');
        conn.sendText('{"type":"Cleared","sequence_id":null}');

        await warnings.seen(4, (TtsWarning w) => w.code == 'MALFORMED_FRAME');
        expect(flushed.values, isEmpty);
        expect(cleared.values, isEmpty);
        expect(
          harness.logger.warns,
          containsAll(<Matcher>[
            contains('Malformed /v1/speak frame'),
            contains('Flushed frame has no valid sequence_id'),
            contains('Cleared frame has no valid sequence_id'),
          ]),
        );
        expect(
          warnings.values.map((TtsWarning w) => w.description),
          everyElement(contains('sequence_id')),
        );
      });

      test('malformed frames (invalid JSON, non-object, missing or non-string '
          'type) never crash the pump', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);
        final warnings = _Recorder<TtsWarning>(client.warnings);
        addTearDown(warnings.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        conn.sendText('this is not json');
        conn.sendText('[1, 2, 3]');
        conn.sendText('{"data":1}');
        conn.sendText('{"type":42}');
        conn.sendText('');

        await warnings.seen(5, (TtsWarning w) => w.code == 'MALFORMED_FRAME');
        final List<String> descriptions = warnings.values
            .map((TtsWarning w) => w.description)
            .toList();
        expect(descriptions[0], contains('frame is not a JSON object'));
        expect(descriptions[1], contains('frame is not a JSON object'));
        expect(descriptions[2], contains('frame has no "type" field'));
        expect(descriptions[3], contains('frame has no "type" field'));
        expect(descriptions[4], contains('frame is not a JSON object'));

        // The connection stays usable afterwards.
        final audio = _Recorder<List<int>>(client.audio);
        addTearDown(audio.dispose);
        conn.sendBytes(<int>[7, 7, 7]);
        expect(await audio.next, <int>[7, 7, 7]);
      });

      test(
        'unknown frame types are ignored with a debug log (no warning)',
        () async {
          final server = await _LoopbackSpeakServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          addTearDown(client.forceClose);
          final warnings = _Recorder<TtsWarning>(client.warnings);
          addTearDown(warnings.dispose);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;

          conn.sendText('{"type":"SomethingNew","data":"x"}');

          await _pumpEventLoop();
          expect(warnings.values, isEmpty);
          expect(
            harness.logger.debugs,
            contains('Ignoring unknown /v1/speak frame type: SomethingNew'),
          );
        },
      );

      test('sendText/flush/clear emit their exact JSON messages', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        client.sendText('Hello, ');
        client.sendText('world!');
        client.flush();
        client.clear();

        expect(await conn.nextFrame(), '{"type":"Speak","text":"Hello, "}');
        expect(await conn.nextFrame(), '{"type":"Speak","text":"world!"}');
        expect(await conn.nextFrame(), '{"type":"Flush"}');
        expect(await conn.nextFrame(), '{"type":"Clear"}');
      });

      test('user wsOptions are forwarded (KeepAlive heartbeats reach the '
          'server)', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(
          wsOptions: const ResilientWebSocketOptions(
            keepAliveInterval: Duration(milliseconds: 20),
            minReconnectDelay: Duration(milliseconds: 1),
            maxReconnectDelay: Duration(milliseconds: 5),
          ),
        );
        addTearDown(client.forceClose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        expect(await conn.nextFrame(), '{"type":"KeepAlive"}');
        expect(await conn.nextFrame(), '{"type":"KeepAlive"}');
      });

      test(
        'outbound messages are dropped with a warning after close()',
        () async {
          final server = await _LoopbackSpeakServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;

          final Future<void> closing = client.close();
          expect(await conn.nextFrame(), '{"type":"Close"}');
          await conn.closeNormally();
          await closing;

          client.sendText('too late');
          client.flush();
          client.clear();
          await _pumpEventLoop();

          expect(
            harness.logger.warns,
            everyElement(
              'Dropping outbound TTS message: the session is closed.',
            ),
          );
          expect(harness.logger.warns, hasLength(3));
          // Only the Close message ever reached the server.
          expect(conn.frames, <String>['{"type":"Close"}']);
        },
      );

      test('close() sends the Close message, drains final audio, and releases '
          'the streams', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        final audio = _Recorder<List<int>>(client.audio);
        addTearDown(audio.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        final Future<void> closing = client.close();
        expect(await conn.nextFrame(), '{"type":"Close"}');
        // The server flushes the final audio, then closes the socket.
        conn.sendBytes(<int>[9, 9, 9]);
        await conn.closeNormally();
        await closing;

        expect(
          await audio.waitFor(
            (List<int> chunk) => listEquals(chunk, <int>[9, 9, 9]),
          ),
          isNotNull,
        );
        await audio.onDone;
        expect(client.isConnected, isFalse);
      });

      test('after close(): start() throws DeepgramStateException and close() '
          'is idempotent', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        final Future<void> closing = client.close();
        expect(await conn.nextFrame(), '{"type":"Close"}');
        await conn.closeNormally();
        await closing;

        final Object? error = await _failureOf(() => client.start());
        expect(error, isA<DeepgramStateException>());
        expect(
          (error! as DeepgramStateException).message,
          'This TTS session was closed.',
        );
        await client.close(); // Second close must not throw or hang.
      });

      test('forceClose() drops the socket immediately without a Close '
          'message and is idempotent', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        final states = _Recorder<WsConnectionState>(client.connectionStates);
        addTearDown(states.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        await client.forceClose();
        await conn.done;
        await _pumpEventLoop();

        expect(
          conn.frames,
          isEmpty,
          reason: 'forceClose must not send {"type":"Close"}',
        );
        expect(client.isConnected, isFalse);
        expect(states.values, contains(WsConnectionState.closed));
        await client.forceClose(); // Idempotent.
      });

      test('calling start() twice throws DeepgramStateException', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);

        final connFuture = server.nextConnection();
        final Future<void> first = client.start();
        final Object? error = await _failureOf(() => client.start());
        await first;
        await connFuture;

        expect(error, isA<DeepgramStateException>());
        expect(
          (error! as DeepgramStateException).message,
          'start() was already called.',
        );
      });

      test('start() after a terminal failed state reconnects and opens a new '
          'session', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        final states = _Recorder<WsConnectionState>(client.connectionStates);
        addTearDown(states.dispose);

        // Two corroborated 401 refusals (probe is up) exhaust the default
        // failure threshold and surface DeepgramWebSocketException.
        server.refuseUpgradesRemaining = 2;
        final Object? error = await _failureOf(() => client.start());
        expect(error, isA<DeepgramWebSocketException>());
        final DeepgramWebSocketException wsError =
            error! as DeepgramWebSocketException;
        expect(wsError.message, contains('did not open'));
        expect(wsError.message, contains('failed'));
        expect(server.refusedUpgrades, 2);
        expect(
          states.values,
          containsAllInOrder(<WsConnectionState>[
            WsConnectionState.connecting,
            WsConnectionState.reconnecting,
            WsConnectionState.failed,
          ]),
        );
        expect(
          server.plainRequests,
          isNotEmpty,
          reason: 'each definitive failure is corroborated with a probe',
        );

        // The failed session can be restarted.
        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;
        expect(client.isConnected, isTrue);
        client.sendText('reborn');
        expect(await conn.nextFrame(), '{"type":"Speak","text":"reborn"}');
      });

      test('start() throws DeepgramWebSocketException when the endpoint is '
          'unreachable and the policy gives up', () async {
        // Bind a server, route the harness at it, then close it so the port
        // refuses connections — fast and deterministic on loopback.
        final deadServer = await _LoopbackSpeakServer.start();
        final harness = _Harness(deadServer);
        await deadServer.shutdown();

        final client = harness.client(wsOptions: _giveUpWsOptions);

        final Object? error = await _failureOf(() => client.start());
        expect(error, isA<DeepgramWebSocketException>());
        expect(
          (error! as DeepgramWebSocketException).message,
          contains('did not open'),
        );
        await client.forceClose();
      });

      test('an unexpected server drop reconnects and the new session carries '
          'subsequent sends', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        final states = _Recorder<WsConnectionState>(client.connectionStates);
        addTearDown(states.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;
        expect(
          states.values,
          containsAllInOrder(<WsConnectionState>[
            WsConnectionState.connecting,
            WsConnectionState.open,
          ]),
        );

        final conn2Future = server.nextConnection();
        await conn.drop();
        final conn2 = await conn2Future;
        // The server-side upgrade completes slightly before the client
        // processes the handshake response — wait for the second open.
        await states.seen(
          2,
          (WsConnectionState s) => s == WsConnectionState.open,
        );

        expect(client.isConnected, isTrue);
        expect(
          states.values,
          containsAllInOrder(<WsConnectionState>[
            WsConnectionState.reconnecting,
            WsConnectionState.open,
          ]),
        );

        client.sendText('after reconnect');
        expect(
          await conn2.nextFrame(),
          '{"type":"Speak","text":"after reconnect"}',
        );
      });

      test('constructs without an injected logger (falls back to '
          'config.logger, then a fresh DeepgramLogger)', () async {
        final server = await _LoopbackSpeakServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);

        // No logger anywhere: the constructor takes the DeepgramLogger()
        // fallback without connecting.
        final bare = TtsStreamClient(
          config: harness.config,
          auth: harness.auth,
          http: harness.httpEngine,
          wsOptions: _fastWsOptions,
        );
        addTearDown(bare.forceClose);
        expect(bare.isConnected, isFalse);

        // A config-level logger is picked up when no client logger is given.
        final configLogger = RecordingLogger();
        final client = TtsStreamClient(
          config: DeepgramConfig(
            apiKey: 'test-api-key',
            baseUrl: _deepgramTestHost,
            useTls: false,
            logger: configLogger,
          ),
          auth: DeepgramAuth(harness.config),
          http: harness.httpEngine,
          wsOptions: _fastWsOptions,
        );
        addTearDown(client.forceClose);
        expect(client.isConnected, isFalse);
        expect(configLogger.debugs, isEmpty);
      });

      test(
        'sendText before start() is silently dropped (nothing is sent)',
        () async {
          final server = await _LoopbackSpeakServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          addTearDown(client.forceClose);

          client.sendText('never started');
          client.flush();

          await _pumpEventLoop();
          expect(server.connections, isEmpty);
        },
      );
    },
  );
}
