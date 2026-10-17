/// Unit tests for `lib/src/speak/flux_speak_client.dart` — the turn-based
/// Flux text-to-speech client over `WSS /v2/speak`.
///
/// `FluxTtsClient` builds its own `ResilientWebSocket` with the default
/// platform factory (there is no wsFactory injection point on the client),
/// so these tests drive the real socket stack against a scriptable WebSocket
/// server bound to `127.0.0.1` on an ephemeral port with `useTls: false` and
/// a reserved `.test` hostname. Everything stays on loopback — no external
/// network is touched.
///
/// Coverage: the connection wire (path, FluxTtsOptions query, Token auth),
/// every client message's exact JSON (Speak/Flush/Interrupt with and without
/// a playback offset/Configure/Close/KeepAlive), every server event parsed
/// into its typed stream (Connected/SpeechStarted/SpeechMetadata/
/// SpeechInterrupted/Flushed/SessionMetadata/ConfigureSuccess/
/// ConfigureFailure/Warning/Error), audio byte frames, the barge-in
/// interrupt flow, malformed-frame handling, the defensive model parsers,
/// and the lifecycle (start, double-start, graceful close with a final
/// SessionMetadata, forceClose, refused upgrades, and
/// DeepgramStateException after close).
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
/// `FluxTtsClient` builds its own `ResilientWebSocket` with the default
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
    'Unexpected HttpClient member used by the flux speak tests: '
    '${invocation.memberName}',
  );
}

// ---------------------------------------------------------------------------
// Loopback /v2/speak server harness
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
class _LoopbackFluxServer {
  _LoopbackFluxServer._();

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
  static Future<_LoopbackFluxServer> start() async {
    final instance = _LoopbackFluxServer._();
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
  final List<_IndexWait<T>> _indexWaiters = <_IndexWait<T>>[];
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
  final _LoopbackFluxServer server;

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

  /// Builds a Flux TTS client wired exactly like the facade does.
  FluxTtsClient client({
    FluxTtsOptions? options,
    ResilientWebSocketOptions? wsOptions,
  }) {
    return FluxTtsClient(
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

  group('Flux event models (defensive parsing)', () {
    test('FluxSpeakConnected parses a full handshake frame', () {
      final FluxSpeakConnected connected = FluxSpeakConnected.fromJson(
        <String, dynamic>{
          'type': 'Connected',
          'request_id': 'req-2',
          'model_name': 'flux-alexis-en',
          'model_version': '1.0.0',
          'model_uuids': <String>['uuid-a', 'uuid-b'],
        },
      );
      expect(connected.requestId, 'req-2');
      expect(connected.modelName, 'flux-alexis-en');
      expect(connected.modelVersion, '1.0.0');
      expect(connected.modelUuids, <String>['uuid-a', 'uuid-b']);
    });

    test(
      'FluxSpeakConnected falls back on missing or wrongly-typed fields',
      () {
        final FluxSpeakConnected connected = FluxSpeakConnected.fromJson(
          <String, dynamic>{
            'request_id': 7,
            'model_name': null,
            'model_version': <String>['1'],
            'model_uuids': 'nope',
          },
        );
        expect(connected.requestId, '');
        expect(connected.modelName, '');
        expect(connected.modelVersion, '');
        expect(connected.modelUuids, isEmpty);
        final FluxSpeakConnected empty = FluxSpeakConnected.fromJson(
          <String, dynamic>{},
        );
        expect(empty.modelUuids, isEmpty);
      },
    );

    test('FluxSpeakConnected skips non-string model uuids', () {
      final FluxSpeakConnected connected = FluxSpeakConnected.fromJson(
        <String, dynamic>{
          'model_uuids': <dynamic>['uuid-a', 1, null, 'uuid-c'],
        },
      );
      expect(connected.modelUuids, <String>['uuid-a', 'uuid-c']);
    });

    test('FluxSpeechStarted reads the speech id (or falls back)', () {
      expect(
        FluxSpeechStarted.fromJson(<String, dynamic>{
          'speech_id': 'dg_sp_abcdef123456',
        }).speechId,
        'dg_sp_abcdef123456',
      );
      expect(FluxSpeechStarted.fromJson(<String, dynamic>{}).speechId, '');
      expect(
        FluxSpeechStarted.fromJson(<String, dynamic>{'speech_id': 42}).speechId,
        '',
      );
    });

    test('FluxControlsApplied parses counts and defaults to zero', () {
      final FluxControlsApplied applied =
          FluxControlsApplied.fromJson(<String, dynamic>{
            'pronunciations_applied': 2,
            'breaks_applied': 0,
            'pronunciation_warnings': 1,
          });
      expect(applied.pronunciationsApplied, 2);
      expect(applied.breaksApplied, 0);
      expect(applied.pronunciationWarnings, 1);

      final FluxControlsApplied missing = FluxControlsApplied.fromJson(
        <String, dynamic>{},
      );
      expect(missing.pronunciationsApplied, 0);
      expect(missing.breaksApplied, 0);
      expect(missing.pronunciationWarnings, 0);

      final FluxControlsApplied wrongTypes = FluxControlsApplied.fromJson(
        <String, dynamic>{
          'pronunciations_applied': 'x',
          'breaks_applied': true,
        },
      );
      expect(wrongTypes.pronunciationsApplied, 0);
      expect(wrongTypes.breaksApplied, 0);
    });

    test('FluxSpeechMetadata parses int, double, and string counts', () {
      final FluxSpeechMetadata metadata = FluxSpeechMetadata.fromJson(
        <String, dynamic>{
          'speech_id': 'dg_sp_000000000001',
          'audio_duration_ms': 2500,
          'input_character_count': 12.7,
          'billable_character_count': '10',
          'controls_applied': <String, dynamic>{
            'pronunciations_applied': 1,
            'breaks_applied': 0,
            'pronunciation_warnings': 0,
          },
        },
      );
      expect(metadata.speechId, 'dg_sp_000000000001');
      expect(metadata.audioDurationMs, 2500);
      expect(metadata.inputCharacterCount, 12);
      expect(metadata.billableCharacterCount, 10);
      expect(metadata.controlsApplied.pronunciationsApplied, 1);
    });

    test('FluxSpeechMetadata defaults to zeros and empty ids', () {
      final FluxSpeechMetadata metadata = FluxSpeechMetadata.fromJson(
        <String, dynamic>{},
      );
      expect(metadata.speechId, '');
      expect(metadata.audioDurationMs, 0);
      expect(metadata.inputCharacterCount, 0);
      expect(metadata.billableCharacterCount, 0);
      expect(metadata.controlsApplied.pronunciationsApplied, 0);
    });

    test('FluxSpeechInterrupted parses the full barge-in payload', () {
      final FluxSpeechInterrupted interrupted = FluxSpeechInterrupted.fromJson(
        <String, dynamic>{
          'type': 'SpeechInterrupted',
          'audio_played_ms': 1500,
          'text_spoken': 'Hello! How can I',
          'text_remaining': ' help you today?',
          'metadata': <String, dynamic>{
            'speech_id': 'dg_sp_000000000002',
            'audio_duration_ms': 3200,
            'input_character_count': 30,
            'billable_character_count': 28,
            'controls_applied': <String, dynamic>{},
          },
        },
      );
      expect(interrupted.audioPlayedMs, 1500);
      expect(interrupted.textSpoken, 'Hello! How can I');
      expect(interrupted.textRemaining, ' help you today?');
      expect(interrupted.metadata, isNotNull);
      expect(interrupted.metadata!.speechId, 'dg_sp_000000000002');
      expect(interrupted.metadata!.audioDurationMs, 3200);
      expect(interrupted.metadata!.billableCharacterCount, 28);
    });

    test('FluxSpeechInterrupted nulls out non-string text and malformed '
        'metadata', () {
      final FluxSpeechInterrupted interrupted = FluxSpeechInterrupted.fromJson(
        <String, dynamic>{
          'audio_played_ms': '750',
          'text_spoken': 42,
          'text_remaining': <String>['x'],
          'metadata': 'not-a-map',
        },
      );
      expect(interrupted.audioPlayedMs, 750);
      expect(interrupted.textSpoken, isNull);
      expect(interrupted.textRemaining, isNull);
      expect(interrupted.metadata, isNull);

      final FluxSpeechInterrupted empty = FluxSpeechInterrupted.fromJson(
        <String, dynamic>{},
      );
      expect(empty.audioPlayedMs, 0);
      expect(empty.metadata, isNull);
    });

    test('FluxFlushed and FluxSessionMetadata parse (and default)', () {
      expect(
        FluxFlushed.fromJson(<String, dynamic>{
          'speech_id': 'dg_sp_000000000003',
        }).speechId,
        'dg_sp_000000000003',
      );
      expect(FluxFlushed.fromJson(<String, dynamic>{}).speechId, '');

      final FluxSessionMetadata session =
          FluxSessionMetadata.fromJson(<String, dynamic>{
            'total_audio_duration_ms': 9000,
            'total_input_character_count': 120.9,
            'total_billable_character_count': '110',
          });
      expect(session.totalAudioDurationMs, 9000);
      expect(session.totalInputCharacterCount, 120);
      expect(session.totalBillableCharacterCount, 110);

      final FluxSessionMetadata empty = FluxSessionMetadata.fromJson(
        <String, dynamic>{},
      );
      expect(empty.totalAudioDurationMs, 0);
      expect(empty.totalInputCharacterCount, 0);
      expect(empty.totalBillableCharacterCount, 0);
    });

    test('FluxAppliedConfig parses speed as double, int, and numeric '
        'string', () {
      expect(
        FluxAppliedConfig.fromJson(<String, dynamic>{'speed': 1.25}).speed,
        1.25,
      );
      expect(
        FluxAppliedConfig.fromJson(<String, dynamic>{'speed': 2}).speed,
        2.0,
      );
      expect(
        FluxAppliedConfig.fromJson(<String, dynamic>{'speed': '0.75'}).speed,
        0.75,
      );
      expect(
        FluxAppliedConfig.fromJson(<String, dynamic>{'speed': 'fast'}).speed,
        isNull,
      );
      expect(
        FluxAppliedConfig.fromJson(<String, dynamic>{'speed': true}).speed,
        isNull,
      );
      expect(FluxAppliedConfig.fromJson(<String, dynamic>{}).speed, isNull);
    });

    test('FluxSpeakConfigureSuccess parses applied (or nulls it)', () {
      final FluxSpeakConfigureSuccess success =
          FluxSpeakConfigureSuccess.fromJson(<String, dynamic>{
            'type': 'ConfigureSuccess',
            'applied': <String, dynamic>{'speed': 1.1},
          });
      expect(success.applied, isNotNull);
      expect(success.applied!.speed, 1.1);

      expect(
        FluxSpeakConfigureSuccess.fromJson(<String, dynamic>{}).applied,
        isNull,
      );
      expect(
        FluxSpeakConfigureSuccess.fromJson(<String, dynamic>{
          'applied': 'broken',
        }).applied,
        isNull,
      );
    });

    test('FluxSpeakConfigureFailure parses code/field/value/description', () {
      final FluxSpeakConfigureFailure failure =
          FluxSpeakConfigureFailure.fromJson(<String, dynamic>{
            'type': 'ConfigureFailure',
            'code': 'SPEED_OUT_OF_RANGE',
            'field': 'speed',
            'value': 9.5,
            'description': 'Speed must be between 0.5 and 1.5.',
          });
      expect(failure.code, 'SPEED_OUT_OF_RANGE');
      expect(failure.field, 'speed');
      expect(failure.value, 9.5);
      expect(failure.description, 'Speed must be between 0.5 and 1.5.');

      final FluxSpeakConfigureFailure partial =
          FluxSpeakConfigureFailure.fromJson(<String, dynamic>{
            'code': 'SPEED_INCREMENT_INVALID',
            'value': '1.2',
          });
      expect(partial.code, 'SPEED_INCREMENT_INVALID');
      expect(partial.field, isNull);
      expect(partial.value, 1.2);
      expect(partial.description, isNull);

      final FluxSpeakConfigureFailure empty =
          FluxSpeakConfigureFailure.fromJson(<String, dynamic>{});
      expect(empty.code, '');
      expect(empty.value, isNull);
    });

    test('FluxSpeakError parses code and description (and defaults)', () {
      final FluxSpeakError error = FluxSpeakError.fromJson(<String, dynamic>{
        'type': 'Error',
        'code': 'DATA-0002',
        'description': 'Invalid inline pronunciation control.',
      });
      expect(error.code, 'DATA-0002');
      expect(error.description, 'Invalid inline pronunciation control.');

      final FluxSpeakError empty = FluxSpeakError.fromJson(<String, dynamic>{});
      expect(empty.code, '');
      expect(empty.description, '');
    });
  });

  group(
    'FluxTtsClient (loopback /v2/speak server)',
    timeout: const Timeout(Duration(seconds: 5)),
    () {
      test('start() opens ws://host/v2/speak with the option query and Token '
          'authorization header', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(
          options: const FluxTtsOptions(
            model: DeepgramVoices.fluxAlexisEn,
            encoding: TtsEncoding.mulaw,
            sampleRate: 8000,
            expressivity: 1,
            tag: <String>['agent:demo'],
            mipOptOut: true,
          ),
          wsOptions: _fastWsOptions,
        );
        addTearDown(client.forceClose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        expect(client.isConnected, isTrue);
        expect(conn.request.uri.path, '/v2/speak');
        final Map<String, List<String>> query =
            conn.request.uri.queryParametersAll;
        expect(query['model'], <String>['flux-alexis-en']);
        expect(query['encoding'], <String>['mulaw']);
        expect(query['sample_rate'], <String>['8000']);
        expect(query['expressivity'], <String>['1']);
        expect(query['tag'], <String>['agent:demo']);
        expect(query['mip_opt_out'], <String>['true']);
        expect(
          conn.request.headers.value('Authorization'),
          'Token test-api-key',
        );
      });

      test('start() without options sends a bare path', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        expect(conn.request.uri.path, '/v2/speak');
        expect(conn.request.uri.queryParameters, isEmpty);
      });

      test(
        'speak/flush/interrupt/configureSpeed emit their exact JSON',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          addTearDown(client.forceClose);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;

          client.speak('Hello! How can I help you today?');
          client.speak(
            ' More text with a {"word":"tomato",'
            '"pronounce":"tuh-MAH-toe"} control.',
          );
          client.flush();
          client.interrupt();
          client.interrupt(playbackOffsetMs: 1200);
          client.configureSpeed(1.25);

          expect(
            await conn.nextFrame(),
            '{"type":"Speak","text":"Hello! How can I help you today?"}',
          );
          expect(
            await conn.nextFrame(),
            '{"type":"Speak","text":" More text with a {\\"word\\":\\"tomato\\",'
            '\\"pronounce\\":\\"tuh-MAH-toe\\"} control."}',
          );
          expect(await conn.nextFrame(), '{"type":"Flush"}');
          expect(await conn.nextFrame(), '{"type":"Interrupt"}');
          expect(
            await conn.nextFrame(),
            '{"type":"Interrupt","playback_offset":{"type":"time_ms",'
            '"value":1200}}',
          );
          expect(await conn.nextFrame(), '{"type":"Configure","speed":1.25}');
        },
      );

      test('every server event lands on its typed stream', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(
          options: const FluxTtsOptions(model: DeepgramVoices.fluxBreeEn),
          wsOptions: _fastWsOptions,
        );
        addTearDown(client.forceClose);
        final connected = _Recorder<FluxSpeakConnected>(client.connected);
        addTearDown(connected.dispose);
        final speechStarted = _Recorder<FluxSpeechStarted>(
          client.speechStarted,
        );
        addTearDown(speechStarted.dispose);
        final flushed = _Recorder<FluxFlushed>(client.flushed);
        addTearDown(flushed.dispose);
        final configureSuccess = _Recorder<FluxSpeakConfigureSuccess>(
          client.configureSuccess,
        );
        addTearDown(configureSuccess.dispose);
        final configureFailure = _Recorder<FluxSpeakConfigureFailure>(
          client.configureFailure,
        );
        addTearDown(configureFailure.dispose);
        final warnings = _Recorder<TtsWarning>(client.warnings);
        addTearDown(warnings.dispose);
        final errors = _Recorder<FluxSpeakError>(client.errors);
        addTearDown(errors.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        conn.sendText(
          jsonEncode(<String, Object>{
            'type': 'Connected',
            'request_id': 'req-events',
            'model_name': 'flux-bree-en',
            'model_version': '1.0.0',
            'model_uuids': <String>['uuid-1', 'uuid-2'],
          }),
        );
        conn.sendText(
          '{"type":"SpeechStarted","speech_id":"dg_sp_00000000000a"}',
        );
        conn.sendText(
          jsonEncode(<String, Object>{
            'type': 'Flushed',
            'speech_id': 'dg_sp_00000000000a',
          }),
        );
        conn.sendText(
          jsonEncode(<String, Object>{
            'type': 'ConfigureSuccess',
            'applied': <String, Object>{'speed': 0.9},
          }),
        );
        conn.sendText(
          jsonEncode(<String, Object>{
            'type': 'ConfigureFailure',
            'code': 'SPEED_INCREMENT_INVALID',
            'field': 'speed',
            'value': 0.93,
            'description': 'Speed must change in 0.05 increments.',
          }),
        );
        conn.sendText(
          jsonEncode(<String, Object>{
            'type': 'Warning',
            'code': 'NO_ACTIVE_SPEECH',
            'description': 'No active speech to flush.',
          }),
        );
        conn.sendText(
          jsonEncode(<String, Object>{
            'type': 'Error',
            'code': 'DATA-0002',
            'description': 'Invalid data.',
          }),
        );

        final FluxSpeakConnected connectedEvent = await connected.next;
        expect(connectedEvent.requestId, 'req-events');
        expect(connectedEvent.modelName, 'flux-bree-en');
        expect(connectedEvent.modelUuids, <String>['uuid-1', 'uuid-2']);

        final FluxSpeechStarted startedEvent = await speechStarted.next;
        expect(startedEvent.speechId, 'dg_sp_00000000000a');

        final FluxFlushed flushedEvent = await flushed.next;
        expect(flushedEvent.speechId, 'dg_sp_00000000000a');

        final FluxSpeakConfigureSuccess successEvent =
            await configureSuccess.next;
        expect(successEvent.applied!.speed, 0.9);

        final FluxSpeakConfigureFailure failureEvent =
            await configureFailure.next;
        expect(failureEvent.code, 'SPEED_INCREMENT_INVALID');
        expect(failureEvent.value, 0.93);

        final TtsWarning warningEvent = await warnings.next;
        expect(warningEvent.code, 'NO_ACTIVE_SPEECH');

        final FluxSpeakError errorEvent = await errors.next;
        expect(errorEvent.code, 'DATA-0002');
        expect(errorEvent.description, 'Invalid data.');
      });

      test(
        'SpeechMetadata lands on speechMetadata with controls applied',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          addTearDown(client.forceClose);
          final speechMetadata = _Recorder<FluxSpeechMetadata>(
            client.speechMetadata,
          );
          addTearDown(speechMetadata.dispose);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;

          conn.sendText(
            jsonEncode(<String, Object>{
              'type': 'SpeechMetadata',
              'speech_id': 'dg_sp_00000000000b',
              'audio_duration_ms': 4200,
              'input_character_count': 64,
              'billable_character_count': 61,
              'controls_applied': <String, Object>{
                'pronunciations_applied': 2,
                'breaks_applied': 0,
                'pronunciation_warnings': 1,
              },
            }),
          );

          final FluxSpeechMetadata event = await speechMetadata.next;
          expect(event.speechId, 'dg_sp_00000000000b');
          expect(event.audioDurationMs, 4200);
          expect(event.inputCharacterCount, 64);
          expect(event.billableCharacterCount, 61);
          expect(event.controlsApplied.pronunciationsApplied, 2);
          expect(event.controlsApplied.pronunciationWarnings, 1);
        },
      );

      test('audio binary frames surface on the audio stream', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);
        final audio = _Recorder<List<int>>(client.audio);
        addTearDown(audio.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        conn.sendBytes(<int>[10, 20, 30]);
        conn.sendBytes(<int>[40]);

        expect(await audio.next, <int>[10, 20, 30]);
        expect(await audio.next, <int>[40]);
      });

      test('barge-in: interrupt(playbackOffsetMs) yields a typed '
          'SpeechInterrupted with the text split', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);
        final speechStarted = _Recorder<FluxSpeechStarted>(
          client.speechStarted,
        );
        addTearDown(speechStarted.dispose);
        final speechInterrupted = _Recorder<FluxSpeechInterrupted>(
          client.speechInterrupted,
        );
        addTearDown(speechInterrupted.dispose);
        final audio = _Recorder<List<int>>(client.audio);
        addTearDown(audio.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        // The agent speaks a turn; the user barges in after 1500 ms.
        client.speak('Hello! How can I help you today?');
        expect(
          await conn.nextFrame(),
          '{"type":"Speak","text":"Hello! How can I help you today?"}',
        );
        conn.sendText(
          '{"type":"SpeechStarted","speech_id":"dg_sp_00000000000c"}',
        );
        expect((await speechStarted.next).speechId, 'dg_sp_00000000000c');
        conn.sendBytes(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
        expect(await audio.next, <int>[1, 2, 3, 4, 5, 6, 7, 8]);

        client.interrupt(playbackOffsetMs: 1500);
        expect(
          await conn.nextFrame(),
          '{"type":"Interrupt","playback_offset":{"type":"time_ms",'
          '"value":1500}}',
        );

        conn.sendText(
          jsonEncode(<String, Object>{
            'type': 'SpeechInterrupted',
            'audio_played_ms': 1500,
            'text_spoken': 'Hello! How can I',
            'text_remaining': ' help you today?',
            'metadata': <String, Object>{
              'speech_id': 'dg_sp_00000000000c',
              'audio_duration_ms': 3100,
              'input_character_count': 30,
              'billable_character_count': 30,
              'controls_applied': <String, Object>{},
            },
          }),
        );

        final FluxSpeechInterrupted event = await speechInterrupted.next;
        expect(event.audioPlayedMs, 1500);
        expect(event.textSpoken, 'Hello! How can I');
        expect(event.textRemaining, ' help you today?');
        expect(event.metadata!.speechId, 'dg_sp_00000000000c');
        expect(event.metadata!.audioDurationMs, 3100);
      });

      test('malformed frames never crash the pump and surface '
          'MALFORMED_FRAME warnings', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);
        final warnings = _Recorder<TtsWarning>(client.warnings);
        addTearDown(warnings.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        conn.sendText('definitely not json');
        conn.sendText('"just a string"');
        conn.sendText('{"payload":"no type"}');
        conn.sendText('{"type":[]}');

        await warnings.seen(4, (TtsWarning w) => w.code == 'MALFORMED_FRAME');
        final List<String> descriptions = warnings.values
            .map((TtsWarning w) => w.description)
            .toList();
        expect(descriptions[0], contains('frame is not a JSON object'));
        expect(descriptions[1], contains('frame is not a JSON object'));
        expect(descriptions[2], contains('frame has no "type" field'));
        expect(descriptions[3], contains('frame has no "type" field'));
        expect(
          harness.logger.warns,
          contains(contains('Malformed /v2/speak frame')),
        );

        // The session keeps working.
        final audio = _Recorder<List<int>>(client.audio);
        addTearDown(audio.dispose);
        conn.sendBytes(<int>[11]);
        expect(await audio.next, <int>[11]);
      });

      test(
        'unknown frame types are ignored with a debug log (no warning)',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          addTearDown(client.forceClose);
          final warnings = _Recorder<TtsWarning>(client.warnings);
          addTearDown(warnings.dispose);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;

          conn.sendText('{"type":"FutureEvent","n":1}');

          await _pumpEventLoop();
          expect(warnings.values, isEmpty);
          expect(
            harness.logger.debugs,
            contains('Ignoring unknown /v2/speak frame type: FutureEvent'),
          );
        },
      );

      test(
        'outbound messages are dropped with a warning after close()',
        () async {
          final server = await _LoopbackFluxServer.start();
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

          client.speak('too late');
          client.flush();
          client.interrupt();
          client.configureSpeed(1.5);
          await _pumpEventLoop();

          expect(
            harness.logger.warns,
            everyElement(
              'Dropping outbound Flux TTS message: the session is closed.',
            ),
          );
          expect(harness.logger.warns, hasLength(4));
          expect(conn.frames, <String>['{"type":"Close"}']);
        },
      );

      test('close() sends Close, delivers the final SessionMetadata, and '
          'releases the streams', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        final sessionMetadata = _Recorder<FluxSessionMetadata>(
          client.sessionMetadata,
        );
        addTearDown(sessionMetadata.dispose);
        final audio = _Recorder<List<int>>(client.audio);
        addTearDown(audio.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        final Future<void> closing = client.close();
        expect(await conn.nextFrame(), '{"type":"Close"}');
        // The server drains the remaining audio and reports session totals,
        // then closes the socket.
        conn.sendBytes(<int>[5, 6]);
        conn.sendText(
          jsonEncode(<String, Object>{
            'type': 'SessionMetadata',
            'total_audio_duration_ms': 12000,
            'total_input_character_count': 200,
            'total_billable_character_count': 190,
          }),
        );
        await conn.closeNormally();
        await closing;

        final FluxSessionMetadata totals = await sessionMetadata.next;
        expect(totals.totalAudioDurationMs, 12000);
        expect(totals.totalInputCharacterCount, 200);
        expect(totals.totalBillableCharacterCount, 190);
        await sessionMetadata.onDone;
        expect(client.isConnected, isFalse);
      });

      test('after close(): start() throws DeepgramStateException and close() '
          'is idempotent', () async {
        final server = await _LoopbackFluxServer.start();
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
          'This Flux TTS session was closed.',
        );
        await client.close(); // Second close must not throw or hang.
      });

      test('forceClose() drops the socket immediately without a Close '
          'message and is idempotent', () async {
        final server = await _LoopbackFluxServer.start();
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
        final server = await _LoopbackFluxServer.start();
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

      test(
        'start() throws DeepgramWebSocketException when the upgrade is '
        'refused twice (corroborated failures) and restarts after recovery',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          final states = _Recorder<WsConnectionState>(client.connectionStates);
          addTearDown(states.dispose);

          server.refuseUpgradesRemaining = 2;
          final Object? error = await _failureOf(() => client.start());
          expect(error, isA<DeepgramWebSocketException>());
          expect(
            (error! as DeepgramWebSocketException).message,
            contains('did not open'),
          );
          expect(server.refusedUpgrades, 2);
          expect(
            server.plainRequests,
            isNotEmpty,
            reason: 'each definitive failure is corroborated with a probe',
          );

          // Once the endpoint recovers, the failed session restarts.
          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;
          expect(client.isConnected, isTrue);
          client.speak('reborn');
          expect(await conn.nextFrame(), '{"type":"Speak","text":"reborn"}');
        },
      );

      test('start() throws DeepgramWebSocketException when the endpoint is '
          'unreachable and the policy gives up', () async {
        // Bind a server, route the harness at it, then close it so the port
        // refuses connections — fast and deterministic on loopback.
        final deadServer = await _LoopbackFluxServer.start();
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

      test('constructs without an injected logger (falls back to '
          'config.logger, then a fresh DeepgramLogger)', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);

        // No logger anywhere: the constructor takes the DeepgramLogger()
        // fallback without connecting.
        final bare = FluxTtsClient(
          config: harness.config,
          auth: harness.auth,
          http: harness.httpEngine,
          wsOptions: _fastWsOptions,
        );
        addTearDown(bare.forceClose);
        expect(bare.isConnected, isFalse);

        // A config-level logger is picked up when no client logger is given.
        final configLogger = RecordingLogger();
        final client = FluxTtsClient(
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
        'speak before start() is silently dropped (nothing is sent)',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          addTearDown(client.forceClose);

          client.speak('never started');
          client.flush();
          client.interrupt(playbackOffsetMs: 10);

          await _pumpEventLoop();
          expect(server.connections, isEmpty);
        },
      );
    },
  );
}
