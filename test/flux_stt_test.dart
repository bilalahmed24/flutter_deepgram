/// Unit tests for the turn-based Flux speech-to-text stack (`/v2/listen`).
///
/// Coverage targets:
/// * `lib/src/listen/flux/flux_stt_options.dart` — `FluxSttOptions.toQuery`
///   wire rendering (exact query param names, repeated list keys, boundary
///   doubles) and `FluxConfigure.toJson` (nested `thresholds`, clearing
///   semantics for empty lists).
/// * `lib/src/listen/flux/flux_stt_models.dart` — defensive `fromJson`
///   parsing of every server message type, happy path and hostile frames.
/// * `lib/src/listen/flux/flux_stt_client.dart` — `start()` wiring (URI,
///   auth header, states), every event stream, every client-to-server
///   message, binary audio frames, malformed-frame tolerance, the
///   close/forceClose lifecycle, and reconnect behavior.
///
/// `FluxSttClient` builds its own `ResilientWebSocket` with the default
/// platform factory (there is no wsFactory injection point on the client —
/// the task brief's guess does not match the source), so these tests drive
/// the real socket stack against a scriptable WebSocket server bound to
/// `127.0.0.1` on an ephemeral port with `useTls: false`. Everything stays
/// on loopback — no external network is touched. `HttpEngine` is wired with
/// a queued client to match the facade even though Flux never issues HTTP
/// requests (gap recovery is a `/v1/listen` feature).
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

/// Socket options whose backoff is a fixed, generous window. Tests that
/// observe the session mid-backoff need a delay far larger than the
/// microtask latency of the state waits.
const ResilientWebSocketOptions _slowReconnectWsOptions =
    ResilientWebSocketOptions(
      minReconnectDelay: Duration(milliseconds: 300),
      maxReconnectDelay: Duration(milliseconds: 300),
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

/// Policy that retries exactly once, then gives up.
bool _retryOnceThenGiveUp(WsCloseContext context) => context.attempt < 2;

// ---------------------------------------------------------------------------
// Host routing: point the fake Deepgram host at the loopback server
// ---------------------------------------------------------------------------

/// The fake Deepgram hostname used by every test config. It lives in the
/// reserved `.test` TLD, so even without routing it could never resolve
/// outside the machine.
const String _deepgramTestHost = 'flux.test';

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
/// `FluxSttClient` builds its own `ResilientWebSocket` with the default
/// `IoWsFactory` (the client exposes no factory injection point), and
/// `WebSocket.connect` caches one static `HttpClient` on first use — so the
/// override must be installed before the first connection. All traffic stays
/// on loopback; nothing ever leaves the machine.
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

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected HttpClient member used by the flux client tests: '
    '${invocation.memberName}',
  );
}

// ---------------------------------------------------------------------------
// Loopback /v2/listen server harness
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
      onTimeout: () => throw TimeoutException(
        'No connection within '
        '$_waitTimeout.',
      ),
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
    return waiter.future.timeout(
      _waitTimeout,
      onTimeout: () => throw TimeoutException(
        'No event within '
        '$_waitTimeout. Recorded: $values',
      ),
    );
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

/// An [http.Client] that forwards to a [QueueHttpClient] through
/// [http.BaseClient], so binary bodies would be captured exactly. Flux never
/// issues HTTP requests, but the engine is wired like the facade does.
class _ForwardingClient extends http.BaseClient {
  _ForwardingClient(this._queue);

  final QueueHttpClient _queue;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _queue.send(request);
}

/// Wires a config, auth, HTTP engine, and logger against [server].
class _Harness {
  _Harness(this.server, {http.Client? httpClient})
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
    final http.Client client = httpClient ?? _ForwardingClient(queue);
    httpEngine = HttpEngine(config: config, auth: auth, client: client);
  }

  /// The loopback server.
  final _LoopbackFluxServer server;

  /// Config pointing at the loopback server over plain ws/http.
  final DeepgramConfig config;

  /// Credential manager (Token auth).
  late final DeepgramAuth auth;

  /// HTTP engine (unused by Flux; wired to mirror the facade).
  late final HttpEngine httpEngine;

  /// Queued HTTP responses (never drained by Flux).
  final QueueHttpClient queue = QueueHttpClient();

  /// Records every log line the client emits.
  final RecordingLogger logger = RecordingLogger();

  /// Builds a Flux client wired exactly like the facade does.
  FluxSttClient client({
    FluxSttOptions? options,
    ResilientWebSocketOptions? wsOptions,
  }) {
    return FluxSttClient(
      config: config,
      auth: auth,
      http: httpEngine,
      options: options,
      wsOptions: wsOptions,
      logger: logger,
    );
  }
}

/// A short, bounded quiet period for negative ("nothing else happens")
/// assertions.
Future<void> _quiet([int milliseconds = 80]) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

// ---------------------------------------------------------------------------
// Server frame builders
// ---------------------------------------------------------------------------

/// A `Connected` frame for the current session.
Map<String, Object> _connectedFrame({String requestId = 'req-flux-1'}) =>
    <String, Object>{
      'type': 'Connected',
      'request_id': requestId,
      'sequence_id': 1,
    };

/// A `TurnInfo` frame. Floats the spec serializes as strings are sent in the
/// string form; [endOfTurnConfidence] accepts either form.
Map<String, Object> _turnInfoFrame({
  required String event,
  String transcript = '',
  Object? endOfTurnConfidence,
  String? trigger,
  List<String>? languages,
  List<String>? languagesHinted,
}) => <String, Object>{
  'type': 'TurnInfo',
  'request_id': 'req-flux-1',
  'sequence_id': 7,
  'event': event,
  'turn_index': 2,
  'audio_window_start': '1.25',
  'audio_window_end': 4.5,
  'transcript': transcript,
  'words': <Object>[
    <String, Object>{
      'word': 'Hello',
      'confidence': '0.95',
      'start': '1.3',
      'end': 1.5,
    },
    <String, Object>{'word': 'there.'},
  ],
  'end_of_turn_confidence': ?endOfTurnConfidence,
  'trigger': ?trigger,
  'languages': ?languages,
  'languages_hinted': ?languagesHinted,
};

// ---------------------------------------------------------------------------
// flux_stt_options.dart
// ---------------------------------------------------------------------------

void main() {
  // Install host routing before anything in this isolate creates a
  // dart:io HttpClient — dart:io's WebSocket.connect caches its static
  // HttpClient on first use, and every test session must be routed to the
  // loopback server from the very first frame.
  final HttpClient routingInnerClient = HttpClient();
  HttpOverrides.global = _RoutingHttpOverrides(routingInnerClient);

  group('FluxSttOptions.toQuery', () {
    test('defaults render only the model', () {
      expect(const FluxSttOptions().toQuery(), <String, dynamic>{
        'model': 'flux-general-en',
      });
    });

    test('renders every option with its exact wire name', () {
      final Map<String, dynamic> query = const FluxSttOptions(
        model: 'flux-general-multi',
        languageHints: <String>['en', 'fr'],
        encoding: LiveEncoding.linear16,
        sampleRate: 16000,
        eotThreshold: 0.7,
        eagerEotThreshold: 0.62,
        eotTimeoutMs: 5000,
        keyterms: <String>['Deepgram', 'flux'],
        numerals: true,
        tag: <String>['env:test'],
        mipOptOut: true,
        extra: <String, String>{'custom_key': 'custom-value'},
      ).toQuery();
      expect(query, <String, dynamic>{
        'model': 'flux-general-multi',
        'language_hint': <String>['en', 'fr'],
        'encoding': 'linear16',
        'sample_rate': '16000',
        'eot_threshold': '0.7',
        'eager_eot_threshold': '0.62',
        'eot_timeout_ms': '5000',
        'keyterm': <String>['Deepgram', 'flux'],
        'numerals': 'true',
        'tag': <String>['env:test'],
        'mip_opt_out': 'true',
        'custom_key': 'custom-value',
      });
    });

    test('booleans and boundary doubles render in their textual forms', () {
      final Map<String, dynamic> query = const FluxSttOptions(
        numerals: false,
        mipOptOut: false,
        eotThreshold: 1.0,
        eagerEotThreshold: 0.5,
        eotTimeoutMs: 3000,
      ).toQuery();
      expect(query, <String, dynamic>{
        'model': 'flux-general-en',
        'eot_threshold': '1.0',
        'eager_eot_threshold': '0.5',
        'eot_timeout_ms': '3000',
        'numerals': 'false',
        'mip_opt_out': 'false',
      });
    });

    test('empty lists are omitted entirely', () {
      expect(
        const FluxSttOptions(
          languageHints: <String>[],
          keyterms: <String>[],
          tag: <String>[],
        ).toQuery(),
        <String, dynamic>{'model': 'flux-general-en'},
      );
    });

    test('every Flux-supported encoding maps to its wire value', () {
      for (final LiveEncoding enc in const <LiveEncoding>[
        LiveEncoding.linear16,
        LiveEncoding.linear32,
        LiveEncoding.mulaw,
        LiveEncoding.alaw,
        LiveEncoding.opus,
        LiveEncoding.oggOpus,
      ]) {
        final Map<String, dynamic> query = FluxSttOptions(
          encoding: enc,
          sampleRate: 16000,
        ).toQuery();
        expect(query['encoding'], enc.wireName, reason: '$enc');
      }
    });

    test('the /v2 surface carries no /v1-only parameters', () {
      final Map<String, dynamic> query = const FluxSttOptions(
        model: 'flux-general-multi',
        languageHints: <String>['en'],
        encoding: LiveEncoding.linear16,
        sampleRate: 16000,
        eotThreshold: 0.7,
        eagerEotThreshold: 0.6,
        eotTimeoutMs: 5000,
        keyterms: <String>['x'],
        numerals: true,
        tag: <String>['t'],
        mipOptOut: true,
      ).toQuery();
      for (final String absent in const <String>[
        'interim_results',
        'vad_events',
        'channels',
        'endpointing',
        'utterance_end_ms',
        'smart_format',
        'language_hints', // the query key is the singular language_hint
      ]) {
        expect(
          query.containsKey(absent),
          isFalse,
          reason: '$absent is not a /v2/listen parameter',
        );
      }
      expect(query.containsKey('language_hint'), isTrue);
    });
  });

  group('FluxConfigure.toJson', () {
    test('an empty configure sends only the type', () {
      expect(const FluxConfigure().toJson(), <String, dynamic>{
        'type': 'Configure',
      });
    });

    test('thresholds are nested and only present when a threshold is set', () {
      expect(const FluxConfigure(eotThreshold: 0.8).toJson(), <String, dynamic>{
        'type': 'Configure',
        'thresholds': <String, dynamic>{'eot_threshold': 0.8},
      });
      expect(
        const FluxConfigure(eagerEotThreshold: 0.55).toJson(),
        <String, dynamic>{
          'type': 'Configure',
          'thresholds': <String, dynamic>{'eager_eot_threshold': 0.55},
        },
      );
      expect(
        const FluxConfigure(eotTimeoutMs: 4000).toJson(),
        <String, dynamic>{
          'type': 'Configure',
          'thresholds': <String, dynamic>{'eot_timeout_ms': 4000},
        },
      );
    });

    test('a full configure renders the complete payload', () {
      expect(
        const FluxConfigure(
          eotThreshold: 0.9,
          eagerEotThreshold: 0.6,
          eotTimeoutMs: 4500,
          keyterms: <String>['alpha', 'beta'],
          languageHints: <String>['en'],
          numerals: true,
        ).toJson(),
        <String, dynamic>{
          'type': 'Configure',
          'thresholds': <String, dynamic>{
            'eot_threshold': 0.9,
            'eager_eot_threshold': 0.6,
            'eot_timeout_ms': 4500,
          },
          'keyterms': <String>['alpha', 'beta'],
          'language_hints': <String>['en'],
          'numerals': true,
        },
      );
    });

    test(
      'empty lists are sent explicitly (clearing) and false stays false',
      () {
        expect(
          const FluxConfigure(
            keyterms: <String>[],
            languageHints: <String>[],
            numerals: false,
          ).toJson(),
          <String, dynamic>{
            'type': 'Configure',
            'keyterms': <String>[],
            'language_hints': <String>[],
            'numerals': false,
          },
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // flux_stt_models.dart
  // -------------------------------------------------------------------------

  group('flux_stt_models defensive parsing', () {
    test('FluxTurnInfo parses a full EndOfTurn frame with string floats', () {
      final FluxTurnInfo info = FluxTurnInfo.fromJson(<String, dynamic>{
        'type': 'TurnInfo',
        'request_id': 'req-9',
        'sequence_id': 42,
        'event': 'EndOfTurn',
        'turn_index': 3,
        'audio_window_start': '1.25',
        'audio_window_end': 4.5,
        'transcript': 'Hello there.',
        'words': <Object>[
          <String, dynamic>{
            'word': 'Hello',
            'confidence': '0.95',
            'start': '1.3',
            'end': 1.5,
          },
          <String, dynamic>{'word': 'there.'},
        ],
        'end_of_turn_confidence': '0.9',
        'trigger': 'manual',
        'languages': <String>['en', 'fr'],
        'languages_hinted': <String>['en'],
      });
      expect(info.requestId, 'req-9');
      expect(info.sequenceId, 42);
      expect(info.event, 'EndOfTurn');
      expect(info.turnIndex, 3);
      expect(info.audioWindowStart, 1.25);
      expect(info.audioWindowEnd, 4.5);
      expect(info.transcript, 'Hello there.');
      expect(info.words, hasLength(2));
      expect(info.words.first.word, 'Hello');
      expect(info.words.first.confidence, 0.95);
      expect(info.words.first.start, 1.3);
      expect(info.words.first.end, 1.5);
      expect(info.words.last.word, 'there.');
      expect(info.words.last.confidence, 0);
      expect(info.words.last.start, isNull);
      expect(info.words.last.end, isNull);
      expect(info.endOfTurnConfidence, 0.9);
      expect(info.trigger, 'manual');
      expect(info.languages, <String>['en', 'fr']);
      expect(info.languagesHinted, <String>['en']);
    });

    test('FluxTurnInfo falls back to neutral defaults for hostile frames', () {
      final FluxTurnInfo empty = FluxTurnInfo.fromJson(
        const <String, dynamic>{},
      );
      expect(empty.requestId, '');
      expect(empty.sequenceId, 0);
      expect(empty.event, '');
      expect(empty.turnIndex, 0);
      expect(empty.audioWindowStart, 0);
      expect(empty.audioWindowEnd, 0);
      expect(empty.transcript, '');
      expect(empty.words, isEmpty);
      expect(empty.endOfTurnConfidence, isNull);
      expect(empty.trigger, isNull);
      expect(empty.languages, isNull);
      expect(empty.languagesHinted, isNull);

      // Malformed entries are skipped, never fatal.
      final FluxTurnInfo mangled = FluxTurnInfo.fromJson(<String, dynamic>{
        'sequence_id': '9',
        'audio_window_start': 3,
        'audio_window_end': 'not-a-number',
        'words': <Object>[
          'not-a-map',
          42,
          <String, dynamic>{'word': 'kept', 'confidence': 'high'},
        ],
        'end_of_turn_confidence': 'also-not-a-number',
        'languages': <Object>['en', 42, true],
        'languages_hinted': 'not-a-list',
        'trigger': 7,
      });
      expect(mangled.sequenceId, 9);
      expect(mangled.audioWindowStart, 3);
      expect(mangled.audioWindowEnd, 0);
      expect(mangled.words, hasLength(1));
      expect(mangled.words.single.word, 'kept');
      expect(mangled.words.single.confidence, 0);
      expect(mangled.endOfTurnConfidence, isNull);
      expect(mangled.languages, <String>['en']);
      expect(mangled.languagesHinted, isNull);
      expect(mangled.trigger, isNull);
    });

    test(
      'FluxWord parses confidence, start, and end in every documented form',
      () {
        FluxWord word = FluxWord.fromJson(<String, dynamic>{
          'word': 'a',
          'confidence': 0.9,
          'start': 0.1,
          'end': 0.2,
        });
        expect(word.word, 'a');
        expect(word.confidence, 0.9);
        expect(word.start, 0.1);
        expect(word.end, 0.2);

        word = FluxWord.fromJson(<String, dynamic>{
          'word': 'b',
          'confidence': '0.8',
          'start': '1.1',
          'end': '1.2',
        });
        expect(word.confidence, 0.8);
        expect(word.start, 1.1);
        expect(word.end, 1.2);

        word = FluxWord.fromJson(<String, dynamic>{
          'word': 'c',
          'confidence': <dynamic>['x'],
          'start': <dynamic>['x'],
          'end': 5,
        });
        expect(word.confidence, 0);
        expect(word.start, isNull);
        expect(word.end, 5.0);
      },
    );

    test('FluxConnected parses and defaults', () {
      FluxConnected event = FluxConnected.fromJson(<String, dynamic>{
        'type': 'Connected',
        'request_id': 'req-1',
        'sequence_id': '5',
      });
      expect(event.requestId, 'req-1');
      expect(event.sequenceId, 5);

      event = FluxConnected.fromJson(const <String, dynamic>{});
      expect(event.requestId, '');
      expect(event.sequenceId, 0);
    });

    test('FluxConfigureSuccess normalizes every keyterm shape', () {
      // A single string.
      FluxConfigureSuccess event =
          FluxConfigureSuccess.fromJson(<String, dynamic>{
            'type': 'ConfigureSuccess',
            'request_id': 'req-1',
            'sequence_id': 2,
            'keyterms': 'Deepgram',
          });
      expect(event.requestId, 'req-1');
      expect(event.sequenceId, 2);
      expect(event.keyterms, <String>['Deepgram']);
      expect(event.thresholds, isEmpty);
      expect(event.languageHints, isNull);
      expect(event.numerals, isNull);

      // An array of strings mixed with objects and junk.
      event = FluxConfigureSuccess.fromJson(<String, dynamic>{
        'keyterms': <Object>[
          'alpha',
          <String, dynamic>{'keyterm': 'beta'},
          <String, dynamic>{'keyterm': 42},
          7,
          <String, dynamic>{'other': 'x'},
        ],
        'thresholds': <String, dynamic>{
          'eot_threshold': 0.8,
          'eot_timeout_ms': 5000,
        },
        'language_hints': <Object>['en', 9],
        'numerals': true,
      });
      expect(event.keyterms, <String>['alpha', 'beta', '42', '7']);
      expect(event.thresholds, <String, dynamic>{
        'eot_threshold': 0.8,
        'eot_timeout_ms': 5000,
      });
      expect(event.languageHints, <String>['en']);
      expect(event.numerals, true);

      // Absent or unusable values fall back to null/empty.
      event = FluxConfigureSuccess.fromJson(<String, dynamic>{
        'keyterms': 42,
        'thresholds': 'oops',
        'numerals': 'yes',
      });
      expect(event.keyterms, isNull);
      expect(event.thresholds, isEmpty);
      expect(event.numerals, isNull);

      // An explicitly empty list clears.
      event = FluxConfigureSuccess.fromJson(<String, dynamic>{
        'keyterms': <String>[],
      });
      expect(event.keyterms, isEmpty);

      // A map with non-String keys is coerced key-by-key.
      event = FluxConfigureSuccess.fromJson(<String, dynamic>{
        'thresholds': <dynamic, dynamic>{'eot_threshold': 0.8, 42: 'junk'},
      });
      expect(event.thresholds, <String, dynamic>{
        'eot_threshold': 0.8,
        '42': 'junk',
      });
    });

    test('FluxConfigureFailure parses and defaults', () {
      FluxConfigureFailure event =
          FluxConfigureFailure.fromJson(<String, dynamic>{
            'type': 'ConfigureFailure',
            'request_id': 'req-1',
            'sequence_id': 6,
            'code': 'EOT_THRESHOLD_OUT_OF_RANGE',
            'description': 'eot_threshold must be between 0.5 and 1.0',
          });
      expect(event.requestId, 'req-1');
      expect(event.sequenceId, 6);
      expect(event.code, 'EOT_THRESHOLD_OUT_OF_RANGE');
      expect(event.description, 'eot_threshold must be between 0.5 and 1.0');

      event = FluxConfigureFailure.fromJson(const <String, dynamic>{});
      expect(event.requestId, '');
      expect(event.sequenceId, 0);
      expect(event.code, isNull);
      expect(event.description, isNull);

      // Non-string code/description fall back to null.
      event = FluxConfigureFailure.fromJson(<String, dynamic>{
        'code': 7,
        'description': false,
      });
      expect(event.code, isNull);
      expect(event.description, isNull);
    });

    test('FluxWarning parses and defaults to empty strings', () {
      FluxWarning event = FluxWarning.fromJson(<String, dynamic>{
        'type': 'Warning',
        'request_id': 'req-1',
        'sequence_id': 8,
        'code': 'SOME_WARNING',
        'description': 'careful',
      });
      expect(event.requestId, 'req-1');
      expect(event.sequenceId, 8);
      expect(event.code, 'SOME_WARNING');
      expect(event.description, 'careful');

      event = FluxWarning.fromJson(<String, dynamic>{
        'code': 42,
        'description': <dynamic>['x'],
      });
      expect(event.requestId, '');
      expect(event.sequenceId, 0);
      expect(event.code, '');
      expect(event.description, '');
    });

    test('FluxFatalError keeps request_id/sequence_id nullable', () {
      FluxFatalError event = FluxFatalError.fromJson(<String, dynamic>{
        'type': 'Error',
        'request_id': 'req-1',
        'sequence_id': 9,
        'code': 'INTERNAL_SERVER_ERROR',
        'description': 'boom',
      });
      expect(event.requestId, 'req-1');
      expect(event.sequenceId, 9);
      expect(event.code, 'INTERNAL_SERVER_ERROR');
      expect(event.description, 'boom');

      // Doubles truncate; strings parse.
      event = FluxFatalError.fromJson(<String, dynamic>{'sequence_id': 7.9});
      expect(event.sequenceId, 7);
      event = FluxFatalError.fromJson(<String, dynamic>{'sequence_id': '5'});
      expect(event.sequenceId, 5);

      // Everything missing → nulls / empty strings.
      event = FluxFatalError.fromJson(const <String, dynamic>{});
      expect(event.requestId, isNull);
      expect(event.sequenceId, isNull);
      expect(event.code, '');
      expect(event.description, '');
    });
  });

  // -------------------------------------------------------------------------
  // flux_stt_client.dart
  // -------------------------------------------------------------------------

  group(
    'FluxSttClient (loopback /v2/listen server)',
    timeout: const Timeout(Duration(seconds: 5)),
    () {
      test(
        'start() opens /v2/listen with the option query and Token auth',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(
            options: const FluxSttOptions(
              model: 'flux-general-multi',
              languageHints: <String>['en', 'fr'],
              encoding: LiveEncoding.linear16,
              sampleRate: 16000,
              eotThreshold: 0.7,
              eagerEotThreshold: 0.62,
              eotTimeoutMs: 5000,
              keyterms: <String>['Deepgram', 'flux'],
              numerals: true,
              tag: <String>['env:test'],
              mipOptOut: true,
            ),
            wsOptions: _fastWsOptions,
          );
          addTearDown(client.forceClose);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;

          expect(client.isConnected, isTrue);
          expect(conn.request.uri.path, '/v2/listen');
          expect(conn.request.uri.queryParametersAll, <String, List<String>>{
            'model': <String>['flux-general-multi'],
            'language_hint': <String>['en', 'fr'],
            'encoding': <String>['linear16'],
            'sample_rate': <String>['16000'],
            'eot_threshold': <String>['0.7'],
            'eager_eot_threshold': <String>['0.62'],
            'eot_timeout_ms': <String>['5000'],
            'keyterm': <String>['Deepgram', 'flux'],
            'numerals': <String>['true'],
            'tag': <String>['env:test'],
            'mip_opt_out': <String>['true'],
          });
          expect(
            conn.request.headers.value('Authorization'),
            'Token test-api-key',
          );
        },
      );

      test('Bearer credentials from a JWT config are honored', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final jwtConfig = DeepgramConfig(
          jwt: 'test-jwt',
          baseUrl: _deepgramTestHost,
          useTls: false,
        );
        final client = FluxSttClient(
          config: jwtConfig,
          auth: DeepgramAuth(jwtConfig),
          http: harness.httpEngine,
          wsOptions: _fastWsOptions,
          logger: harness.logger,
        );
        addTearDown(client.forceClose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;
        expect(conn.request.headers.value('Authorization'), 'Bearer test-jwt');
        expect(conn.request.uri.path, '/v2/listen');
      });

      test(
        'start() without options sends a bare /v2/listen with no query',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          addTearDown(client.forceClose);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;

          // `options: null` skips toQuery() entirely: the server default
          // turn-detection settings apply.
          expect(conn.request.uri.path, '/v2/listen');
          expect(conn.request.uri.queryParameters, isEmpty);
        },
      );

      test(
        'start() is idempotent and concurrent starts share one connection',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          addTearDown(client.forceClose);

          final connFuture = server.nextConnection();
          final Future<void> first = client.start();
          final Future<void> second = client.start();
          await first;
          await second;
          await client.start(); // Already open: resolves immediately.
          final conn = await connFuture;

          expect(server.connections, hasLength(1));
          expect(client.isConnected, isTrue);
          expect(conn.request.uri.path, '/v2/listen');
        },
      );

      test('the connected stream emits the typed Connected event', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);
        final connected = _Recorder<FluxConnected>(client.connected);
        addTearDown(connected.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        conn.sendText(jsonEncode(_connectedFrame()));
        final FluxConnected event = await connected.next;
        expect(event.requestId, 'req-flux-1');
        expect(event.sequenceId, 1);
      });

      test(
        'the turnInfo stream emits every turn event with typed fields',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          addTearDown(client.forceClose);
          final turns = _Recorder<FluxTurnInfo>(client.turnInfo);
          addTearDown(turns.dispose);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;

          conn.sendText(jsonEncode(_turnInfoFrame(event: 'StartOfTurn')));
          final FluxTurnInfo startOfTurn = await turns.next;
          expect(startOfTurn.event, 'StartOfTurn');
          expect(startOfTurn.transcript, '');
          expect(startOfTurn.sequenceId, 7);
          expect(startOfTurn.words, hasLength(2));
          expect(startOfTurn.requestId, 'req-flux-1');

          conn.sendText(
            jsonEncode(
              _turnInfoFrame(
                event: 'Update',
                transcript: 'Hello',
                endOfTurnConfidence: '0.55',
              ),
            ),
          );
          final FluxTurnInfo update = await turns.next;
          expect(update.event, 'Update');
          expect(update.transcript, 'Hello');
          expect(update.endOfTurnConfidence, 0.55);

          conn.sendText(
            jsonEncode(
              _turnInfoFrame(event: 'EagerEndOfTurn', transcript: 'Hi'),
            ),
          );
          final FluxTurnInfo eager = await turns.next;
          expect(eager.event, 'EagerEndOfTurn');

          conn.sendText(
            jsonEncode(
              _turnInfoFrame(event: 'TurnResumed', transcript: 'Hello there'),
            ),
          );
          final FluxTurnInfo resumed = await turns.next;
          expect(resumed.event, 'TurnResumed');
          expect(resumed.transcript, 'Hello there');

          conn.sendText(
            jsonEncode(
              _turnInfoFrame(
                event: 'EndOfTurn',
                transcript: 'Hello there.',
                trigger: 'manual',
                endOfTurnConfidence: 0.97,
                languages: <String>['en'],
                languagesHinted: <String>['en'],
              ),
            ),
          );
          final FluxTurnInfo end = await turns.next;
          expect(end.event, 'EndOfTurn');
          expect(end.trigger, 'manual');
          expect(end.endOfTurnConfidence, 0.97);
          expect(end.turnIndex, 2);
          expect(end.audioWindowStart, 1.25);
          expect(end.audioWindowEnd, 4.5);
          expect(end.words, hasLength(2));
          expect(end.words.first.word, 'Hello');
          expect(end.words.first.confidence, 0.95);
          expect(end.words.first.start, 1.3);
          expect(end.words.first.end, 1.5);
          expect(end.languages, <String>['en']);
          expect(end.languagesHinted, <String>['en']);
        },
      );

      test(
        'the configureSuccess stream emits normalized ConfigureSuccess',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          addTearDown(client.forceClose);
          final successes = _Recorder<FluxConfigureSuccess>(
            client.configureSuccess,
          );
          addTearDown(successes.dispose);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;

          conn.sendText(
            jsonEncode(<String, Object>{
              'type': 'ConfigureSuccess',
              'request_id': 'req-flux-1',
              'sequence_id': 10,
              'thresholds': <String, Object>{
                'eot_threshold': 0.8,
                'eot_timeout_ms': 5000,
              },
              'keyterms': <Object>[
                'alpha',
                <String, Object>{'keyterm': 'beta'},
              ],
              'language_hints': <String>['en'],
              'numerals': true,
            }),
          );
          final FluxConfigureSuccess event = await successes.next;
          expect(event.requestId, 'req-flux-1');
          expect(event.sequenceId, 10);
          expect(event.thresholds, <String, dynamic>{
            'eot_threshold': 0.8,
            'eot_timeout_ms': 5000,
          });
          expect(event.keyterms, <String>['alpha', 'beta']);
          expect(event.languageHints, <String>['en']);
          expect(event.numerals, true);
        },
      );

      test(
        'the configureFailure stream emits typed ConfigureFailure',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          addTearDown(client.forceClose);
          final failures = _Recorder<FluxConfigureFailure>(
            client.configureFailure,
          );
          addTearDown(failures.dispose);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;

          conn.sendText(
            jsonEncode(<String, Object>{
              'type': 'ConfigureFailure',
              'request_id': 'req-flux-1',
              'sequence_id': 11,
              'code': 'EOT_THRESHOLD_OUT_OF_RANGE',
              'description': 'eot_threshold must be between 0.5 and 1.0',
            }),
          );
          final FluxConfigureFailure event = await failures.next;
          expect(event.requestId, 'req-flux-1');
          expect(event.sequenceId, 11);
          expect(event.code, 'EOT_THRESHOLD_OUT_OF_RANGE');
          expect(
            event.description,
            'eot_threshold must be between 0.5 and 1.0',
          );
        },
      );

      test('the warnings stream emits typed server Warning frames', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);
        final warnings = _Recorder<FluxWarning>(client.warnings);
        addTearDown(warnings.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        conn.sendText(
          jsonEncode(<String, Object>{
            'type': 'Warning',
            'request_id': 'req-flux-1',
            'sequence_id': 12,
            'code': 'SESSION_NEAR_LIMIT',
            'description': 'The session is nearing its limit.',
          }),
        );
        final FluxWarning event = await warnings.next;
        expect(event.requestId, 'req-flux-1');
        expect(event.sequenceId, 12);
        expect(event.code, 'SESSION_NEAR_LIMIT');
        expect(event.description, 'The session is nearing its limit.');
      });

      test('the fatalErrors stream emits typed Error frames without killing '
          'the pump', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);
        final fatals = _Recorder<FluxFatalError>(client.fatalErrors);
        addTearDown(fatals.dispose);
        final turns = _Recorder<FluxTurnInfo>(client.turnInfo);
        addTearDown(turns.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        conn.sendText(
          jsonEncode(<String, Object>{
            'type': 'Error',
            'request_id': 'req-flux-1',
            'sequence_id': 99,
            'code': 'INTERNAL_SERVER_ERROR',
            'description': 'boom',
          }),
        );
        final FluxFatalError error = await fatals.next;
        expect(error.requestId, 'req-flux-1');
        expect(error.sequenceId, 99);
        expect(error.code, 'INTERNAL_SERVER_ERROR');
        expect(error.description, 'boom');

        // The client keeps pumping; the server decides whether to close.
        conn.sendText(
          jsonEncode(
            _turnInfoFrame(event: 'Update', transcript: 'still alive'),
          ),
        );
        final FluxTurnInfo update = await turns.next;
        expect(update.transcript, 'still alive');
        expect(client.isConnected, isTrue);
      });

      test(
        'malformed frames produce PARSE_ERROR warnings and never crash',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          addTearDown(client.forceClose);
          final warnings = _Recorder<FluxWarning>(client.warnings);
          addTearDown(warnings.dispose);
          final turns = _Recorder<FluxTurnInfo>(client.turnInfo);
          addTearDown(turns.dispose);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;

          conn.sendText('this is not json');
          FluxWarning warning = await warnings.next;
          expect(warning.code, 'PARSE_ERROR');
          expect(
            warning.description,
            'Received a frame that is not valid JSON. (frame: this is not json)',
          );

          conn.sendText('[1,2,3]');
          warning = await warnings.next;
          expect(
            warning.description,
            'Received a frame that is not a JSON object. (frame: [1,2,3])',
          );

          conn.sendText('{"payload": true}');
          warning = await warnings.next;
          expect(
            warning.description,
            'Received a frame without a message type. (frame: {"payload": true})',
          );

          conn.sendText('{"type": 42}');
          warning = await warnings.next;
          expect(
            warning.description,
            'Received a frame without a message type. (frame: {"type": 42})',
          );

          // A huge invalid frame has its embedded summary truncated at 512 chars.
          final String huge = 'x' * 600;
          conn.sendText(huge);
          warning = await warnings.next;
          expect(warning.code, 'PARSE_ERROR');
          expect(
            warning.description,
            startsWith('Received a frame that is not valid JSON. (frame: '),
          );
          expect(warning.description, endsWith('...)'));
          expect(warning.description, contains('x' * 512));
          expect(warning.description, isNot(contains('x' * 513)));

          // Binary frames, empty text frames, and unknown types are ignored
          // defensively (no PARSE_ERROR, no crash).
          conn.sendBytes(<int>[1, 2, 3]);
          conn.sendText('');
          conn.sendText(jsonEncode(<String, Object>{'type': 'MysteryFrame'}));
          await _quiet();
          expect(warnings.values, hasLength(5));
          expect(
            harness.logger.debugs,
            anyElement(
              contains(
                'Ignoring unknown message type from /v2/listen: '
                'MysteryFrame',
              ),
            ),
          );

          // The session survived all of it.
          conn.sendText(
            jsonEncode(
              _turnInfoFrame(event: 'Update', transcript: 'still alive'),
            ),
          );
          final FluxTurnInfo update = await turns.next;
          expect(update.transcript, 'still alive');
          expect(client.isConnected, isTrue);
        },
      );

      test('sendAudio streams binary frames and skips empty chunks', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        client.sendAudio(<int>[1, 2, 3]);
        client.sendAudio(<int>[4, 5]);
        client.sendAudio(<int>[]);

        final Object first = await conn.nextFrame();
        expect(first, <int>[1, 2, 3]);
        final Object second = await conn.nextFrame();
        expect(second, <int>[4, 5]);
        await _quiet();
        expect(conn.frames, hasLength(2));
      });

      test('forceEndTurn() sends the exact ForceEndTurn message', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        client.forceEndTurn();
        expect(await conn.nextFrame(), '{"type":"ForceEndTurn"}');
        expect(client.isConnected, isTrue);
      });

      test('configure() sends the Configure JSON on the socket', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        addTearDown(client.forceClose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        client.configure(
          const FluxConfigure(
            eotThreshold: 0.9,
            eagerEotThreshold: 0.6,
            eotTimeoutMs: 4500,
            keyterms: <String>['alpha'],
            languageHints: <String>['en'],
            numerals: false,
          ),
        );
        expect(jsonDecode(await conn.nextFrame() as String), <String, Object>{
          'type': 'Configure',
          'thresholds': <String, Object>{
            'eot_threshold': 0.9,
            'eager_eot_threshold': 0.6,
            'eot_timeout_ms': 4500,
          },
          'keyterms': <String>['alpha'],
          'language_hints': <String>['en'],
          'numerals': false,
        });
      });

      test(
        'close() sends CloseStream, drains final events, and is terminal',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _fastWsOptions);
          final states = _Recorder<WsConnectionState>(client.connectionStates);
          addTearDown(states.dispose);
          final turns = _Recorder<FluxTurnInfo>(client.turnInfo);
          addTearDown(turns.dispose);
          final warnings = _Recorder<FluxWarning>(client.warnings);
          addTearDown(warnings.dispose);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;

          final Future<void> closing = client.close();
          expect(await conn.nextFrame(), '{"type":"CloseStream"}');

          // Graceful drain: the final EndOfTurn + Warning still arrive.
          conn.sendText(
            jsonEncode(
              _turnInfoFrame(
                event: 'EndOfTurn',
                transcript: 'flushed on close',
                trigger: 'manual',
              ),
            ),
          );
          conn.sendText(
            jsonEncode(<String, Object>{
              'type': 'Warning',
              'code': 'LAST_WARNING',
              'description': 'bye',
            }),
          );
          await conn.closeNormally();
          await closing;

          expect(turns.values, hasLength(1));
          expect(turns.values.single.event, 'EndOfTurn');
          expect(turns.values.single.transcript, 'flushed on close');
          expect(turns.values.single.trigger, 'manual');
          expect(warnings.values, hasLength(1));
          expect(warnings.values.single.code, 'LAST_WARNING');
          await states.waitFor(
            (WsConnectionState s) => s == WsConnectionState.closed,
          );
          expect(client.isConnected, isFalse);
          expect(client.reconnectAttempts, 0);

          // Terminal: start() throws, everything else is a silent no-op, and a
          // second close() resolves without error.
          await expectLater(
            client.start(),
            throwsA(isA<DeepgramStateException>()),
          );
          client.sendAudio(<int>[1]);
          client.forceEndTurn();
          client.configure(const FluxConfigure(eotThreshold: 0.9));
          await client.close();
          await _quiet();
          expect(conn.frames, hasLength(1)); // Only the CloseStream frame.
        },
      );

      test('close() before start() terminalizes without a socket', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);

        await client.close();
        expect(client.isConnected, isFalse);
        await expectLater(
          client.start(),
          throwsA(isA<DeepgramStateException>()),
        );
        client.sendAudio(<int>[1]);
        client.forceEndTurn();
        client.configure(const FluxConfigure(eotThreshold: 0.5));
        await client.forceClose();
        expect(server.connections, isEmpty);
      });

      test('forceClose() drops the socket without CloseStream', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final client = harness.client(wsOptions: _fastWsOptions);
        final states = _Recorder<WsConnectionState>(client.connectionStates);
        addTearDown(states.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;

        final Future<void> gone = conn.done;
        await client.forceClose();
        await gone;
        await states.waitFor(
          (WsConnectionState s) => s == WsConnectionState.closed,
        );
        expect(conn.frames, isEmpty);
        await client.forceClose(); // Idempotent.
        await _quiet();
        expect(server.connections, hasLength(1));
      });

      test('start() throws DeepgramWebSocketException when the upgrade is '
          'refused, then recovers', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        server.refuseUpgradesRemaining = 10;
        final client = harness.client(
          wsOptions: const ResilientWebSocketOptions(
            minReconnectDelay: Duration(milliseconds: 1),
            maxReconnectDelay: Duration(milliseconds: 5),
            keepAliveInterval: Duration(minutes: 30),
            shouldReconnect: _retryOnceThenGiveUp,
          ),
        );
        addTearDown(client.forceClose);
        final states = _Recorder<WsConnectionState>(client.connectionStates);
        addTearDown(states.dispose);

        await expectLater(
          client.start(),
          throwsA(isA<DeepgramWebSocketException>()),
        );
        await states.waitFor(
          (WsConnectionState s) => s == WsConnectionState.failed,
        );
        expect(server.refusedUpgrades, 2);
        // Every failed attempt was corroborated by a probe against our server.
        expect(server.plainRequests, hasLength(2));
        expect(states.values, contains(WsConnectionState.reconnecting));

        // A failed session can be started again once the endpoint recovers.
        server.refuseUpgradesRemaining = 0;
        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;
        expect(client.isConnected, isTrue);
        expect(conn.request.uri.path, '/v2/listen');
        expect(server.connections, hasLength(1));
      });

      test(
        'start() fails fast against a closed port with a give-up policy',
        () async {
          // Reserve a loopback port, free it again, and route the fake host
          // there: every connect is refused instantly, on loopback only.
          final deadServer = await _LoopbackFluxServer.start();
          final int deadPort = deadServer.port;
          await deadServer.shutdown();
          _router.port = deadPort;

          final config = DeepgramConfig(
            apiKey: 'test-api-key',
            baseUrl: _deepgramTestHost,
            useTls: false,
            requestTimeout: const Duration(seconds: 2),
            connectTimeout: const Duration(seconds: 2),
          );
          final auth = DeepgramAuth(config);
          final client = FluxSttClient(
            config: config,
            auth: auth,
            http: HttpEngine(
              config: config,
              auth: auth,
              client: _ForwardingClient(QueueHttpClient()),
            ),
            wsOptions: _giveUpWsOptions,
            logger: RecordingLogger(),
          );
          addTearDown(client.forceClose);
          final states = _Recorder<WsConnectionState>(client.connectionStates);
          addTearDown(states.dispose);

          await expectLater(
            client.start(),
            throwsA(isA<DeepgramWebSocketException>()),
          );
          await states.waitFor(
            (WsConnectionState s) => s == WsConnectionState.failed,
          );
        },
      );

      test(
        'constructs with the default socket options and no logger',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = FluxSttClient(
            config: harness.config,
            auth: harness.auth,
            http: harness.httpEngine,
          );
          addTearDown(client.forceClose);
          final turns = _Recorder<FluxTurnInfo>(client.turnInfo);
          addTearDown(turns.dispose);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;
          expect(conn.request.uri.path, '/v2/listen');
          expect(conn.request.uri.queryParameters, isEmpty);

          conn.sendText(
            jsonEncode(
              _turnInfoFrame(event: 'Update', transcript: 'default wiring'),
            ),
          );
          final FluxTurnInfo update = await turns.next;
          expect(update.transcript, 'default wiring');
        },
      );

      test('user wsOptions are forwarded and a reconnect starts a brand-new '
          'session', () async {
        final server = await _LoopbackFluxServer.start();
        addTearDown(server.shutdown);
        final harness = _Harness(server);
        final List<WsReconnectContext> reconnectingContexts =
            <WsReconnectContext>[];
        var userReconnectedCalls = 0;
        final client = harness.client(
          wsOptions: ResilientWebSocketOptions(
            minReconnectDelay: const Duration(milliseconds: 300),
            maxReconnectDelay: const Duration(milliseconds: 300),
            keepAliveInterval: const Duration(minutes: 30),
            onReconnecting: reconnectingContexts.add,
            onReconnected: () => userReconnectedCalls++,
          ),
        );
        addTearDown(client.forceClose);
        final states = _Recorder<WsConnectionState>(client.connectionStates);
        addTearDown(states.dispose);
        final connected = _Recorder<FluxConnected>(client.connected);
        addTearDown(connected.dispose);

        final connFuture = server.nextConnection();
        await client.start();
        final conn = await connFuture;
        conn.sendText(jsonEncode(_connectedFrame()));
        await connected.next; // First session established.

        await conn.drop();
        await states.seen(
          1,
          (WsConnectionState s) => s == WsConnectionState.reconnecting,
        );
        expect(client.isConnected, isFalse);
        expect(client.reconnectAttempts, 1);

        // Flux has no disconnect buffering: audio sent while disconnected is
        // dropped at the call site, never replayed on the new session.
        client.sendAudio(<int>[1, 2]);

        await states.seen(
          2,
          (WsConnectionState s) => s == WsConnectionState.open,
        );
        final conn2 = await server.nextConnection();

        // The user hooks fired once, with the reconnect context exposed...
        expect(userReconnectedCalls, 1);
        expect(reconnectingContexts, hasLength(1));
        expect(reconnectingContexts.single.attempt, 1);
        expect(
          reconnectingContexts.single.nextDelay,
          allOf(
            greaterThanOrEqualTo(const Duration(milliseconds: 200)),
            lessThanOrEqualTo(const Duration(milliseconds: 450)),
          ),
        );
        // ...and the attempts counter reset after the successful reconnect.
        expect(client.reconnectAttempts, 0);
        await _quiet();
        expect(conn2.frames, isEmpty);

        // The reconnected socket is a brand-new session: it delivers its own
        // Connected event through the same streams.
        conn2.sendText(jsonEncode(_connectedFrame(requestId: 'req-flux-2')));
        await connected.seen(2, (FluxConnected _) => true);
        expect(connected.values.last.requestId, 'req-flux-2');
      });

      test(
        'start() during a reconnect backoff adopts the in-flight chain',
        () async {
          final server = await _LoopbackFluxServer.start();
          addTearDown(server.shutdown);
          final harness = _Harness(server);
          final client = harness.client(wsOptions: _slowReconnectWsOptions);
          addTearDown(client.forceClose);
          final states = _Recorder<WsConnectionState>(client.connectionStates);
          addTearDown(states.dispose);

          final connFuture = server.nextConnection();
          await client.start();
          final conn = await connFuture;

          await conn.drop();
          await states.seen(
            1,
            (WsConnectionState s) => s == WsConnectionState.reconnecting,
          );

          // Called while the session is mid-backoff: start() must NOT dial a
          // second socket; it adopts the in-flight reconnect chain.
          await client.start();
          await states.seen(
            2,
            (WsConnectionState s) => s == WsConnectionState.open,
          );
          await server.nextConnection();
          expect(server.connections, hasLength(2));
          expect(client.isConnected, isTrue);
        },
      );
    },
  );
}
