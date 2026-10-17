/// Unit tests for the live (`/v1/listen`) streaming STT client.
///
/// Coverage targets:
/// * `lib/src/listen/live/live_client.dart` — lifecycle, message pump, all
///   six event streams, graceful close, and the full disconnect gap-recovery
///   engine (socket flush, HTTPS pre-recorded recovery, buffer caps, the
///   serialized recovery chain, and anchor timestamps).
/// * `lib/src/listen/live/live_options.dart` — `toQuery` wire rendering and
///   `LiveGapRecoveryOptions` defaults.
/// * `lib/src/listen/live/live_models.dart` — defensive `fromJson` parsing.
///
/// `DeepgramLiveClient` builds its own `ResilientWebSocket` with the default
/// platform factory (there is no wsFactory injection point on the client), so
/// these tests drive the real socket stack against a scriptable WebSocket
/// server bound to `127.0.0.1` on an ephemeral port with `useTls: false`.
/// Everything stays on loopback — no external network is touched. The HTTPS
/// leg of gap recovery is captured through a `QueueHttpClient` injected into
/// the client's `HttpEngine`.
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

/// Socket options that reconnect almost instantly (non-gap tests).
const ResilientWebSocketOptions _fastWsOptions = ResilientWebSocketOptions(
  minReconnectDelay: Duration(milliseconds: 1),
  maxReconnectDelay: Duration(milliseconds: 5),
  keepAliveInterval: Duration(minutes: 30),
);

/// Socket options whose backoff is a fixed, generous window. Gap tests buffer
/// audio while disconnected, so they need a reconnect delay that is far larger
/// than the microtask latency of `await states.seen(...)`.
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

// ---------------------------------------------------------------------------
// Host routing: point the fake Deepgram host at the loopback server
// ---------------------------------------------------------------------------

/// The fake Deepgram hostname used by every test config. It lives in the
/// reserved `.test` TLD, so even without routing it could never resolve
/// outside the machine.
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
/// `DeepgramLiveClient` builds its own `ResilientWebSocket` with the default
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
      'Unexpected HttpClient member used by the live client tests: '
      '${invocation.memberName}');
}

// ---------------------------------------------------------------------------
// Loopback /v1/listen server harness
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
  Future<Object> nextFrame() {
    if (_pendingFrames.isNotEmpty) {
      return Future<Object>.value(_pendingFrames.removeAt(0));
    }
    final waiter = Completer<Object>();
    _frameWaiters.add(waiter);
    return waiter.future.timeout(_waitTimeout, onTimeout: () {
      throw TimeoutException('No frame within $_waitTimeout. '
          'Frames so far: $frames');
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
class _LoopbackLiveServer {
  _LoopbackLiveServer._();

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
  static Future<_LoopbackLiveServer> start() async {
    final instance = _LoopbackLiveServer._();
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
    return waiter.future.timeout(_waitTimeout,
        onTimeout: () => throw TimeoutException('No connection within '
            '$_waitTimeout.'));
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
        final conn =
            _ServerConn(request, await WebSocketTransformer.upgrade(request));
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
    return waiter.future.timeout(_waitTimeout,
        onTimeout: () => throw TimeoutException('No event within '
            '$_waitTimeout. Recorded: $values'));
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

/// An [http.Client] that forwards to a [QueueHttpClient] through
/// [http.BaseClient], so `postAudio` byte bodies are captured exactly (the
/// queue's own `post` would stringify binary bodies).
class _ForwardingClient extends http.BaseClient {
  _ForwardingClient(this._queue);

  final QueueHttpClient _queue;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _queue.send(request);
}

/// An [http.Client] whose responses complete only when the test says so —
/// used to keep HTTPS gap recoveries in flight.
class _ScriptableHttp extends http.BaseClient {
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  final List<_PendingResponse> _pending = <_PendingResponse>[];

  /// Queues one response the test completes manually.
  _PendingResponse enqueue() {
    final pending = _PendingResponse();
    _pending.add(pending);
    return pending;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    if (_pending.isEmpty) {
      throw StateError('No scripted response enqueued.');
    }
    return _pending.removeAt(0).future;
  }
}

class _PendingResponse {
  final Completer<http.StreamedResponse> _completer =
      Completer<http.StreamedResponse>();

  /// The response future the SDK is waiting on.
  Future<http.StreamedResponse> get future => _completer.future;

  /// Completes the pending request with a JSON body.
  void respondJson(Object body) {
    final List<int> bytes =
        utf8.encode(body is String ? body : jsonEncode(body));
    _completer.complete(
      http.StreamedResponse(Stream<List<int>>.value(bytes), 200),
    );
  }
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
  final _LoopbackLiveServer server;

  /// Config pointing at the loopback server over plain ws/http.
  final DeepgramConfig config;

  /// Credential manager (Token auth).
  late final DeepgramAuth auth;

  /// HTTP engine used by the client for HTTPS gap recovery.
  late final HttpEngine httpEngine;

  /// Queued HTTP responses for gap recovery.
  final QueueHttpClient queue = QueueHttpClient();

  /// Records every log line the client emits.
  final RecordingLogger logger = RecordingLogger();

  /// Builds a live client wired exactly like the facade does.
  DeepgramLiveClient client({
    LiveTranscriptionOptions? options,
    ResilientWebSocketOptions? wsOptions,
    LiveGapRecoveryOptions gapRecovery = const LiveGapRecoveryOptions(),
  }) {
    return DeepgramLiveClient(
      config: config,
      auth: auth,
      http: httpEngine,
      options: options,
      wsOptions: wsOptions,
      gapRecovery: gapRecovery,
      logger: logger,
    );
  }
}

/// A short, bounded quiet period for negative ("nothing else happens")
/// assertions.
Future<void> _quiet([int milliseconds = 80]) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

/// Pumps the event loop until [condition] holds (bounded).
Future<void> _until(
  bool Function() condition, {
  Duration timeout = _waitTimeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met within $timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Map<String, Object> _resultsFrame({
  required String transcript,
  required bool isFinal,
  bool speechFinal = false,
}) =>
    <String, Object>{
      'type': 'Results',
      'channel_index': <int>[0, 1],
      'duration': 1.25,
      'start': 0.5,
      'is_final': isFinal,
      'speech_final': speechFinal,
      'channel': <String, Object>{
        'alternatives': <Object>[
          <String, Object>{
            'transcript': transcript,
            'confidence': 0.9,
            'words': <Object>[
              <String, Object>{
                'word': 'hello',
                'start': 0.5,
                'end': 0.8,
                'confidence': 0.99,
                'punctuated_word': 'Hello,',
              },
            ],
          },
        ],
      },
      'metadata': <String, Object>{
        'request_id': 'req-live',
        'created': '2025-06-01T12:00:00Z',
        'duration': 9.5,
        'channels': 1,
      },
    };

Map<String, Object> _prerecordedBody(
  List<String> transcripts, {
  double duration = 4.5,
}) =>
    <String, Object>{
      'metadata': <String, Object>{
        'request_id': 'req-recovery',
        'transaction_key': 'tk-9',
        'sha256': 'cafebabe',
        'created': '2025-06-01T12:00:00Z',
        'duration': duration,
        'channels': transcripts.length,
        'model_info': <String, Object>{
          'name': 'nova3',
          'version': '2025-01',
          'arch': 'nova-3',
        },
      },
      'results': <String, Object>{
        'channels': <Object>[
          for (final String transcript in transcripts)
            <String, Object>{
              'alternatives': <Object>[
                <String, Object>{'transcript': transcript, 'confidence': 0.9},
              ],
            },
        ],
      },
    };

// ---------------------------------------------------------------------------
// live_options.dart
// ---------------------------------------------------------------------------

void main() {
  // Install host routing before anything in this isolate creates a
  // dart:io HttpClient — dart:io's WebSocket.connect caches its static
  // HttpClient on first use, and every test session must be routed to the
  // loopback server from the very first frame.
  final HttpClient routingInnerClient = HttpClient();
  HttpOverrides.global = _RoutingHttpOverrides(routingInnerClient);

  group('LiveTranscriptionOptions.toQuery', () {
    test('renders only the documented defaults', () {
      const options = LiveTranscriptionOptions();
      expect(options.toQuery(), <String, dynamic>{
        'model': 'nova-3',
        'language': 'en-US',
        'interim_results': 'true',
      });
    });

    test('renders every feature with its exact wire name', () {
      final Map<String, dynamic> query = const LiveTranscriptionOptions(
        version: '2024-01',
        encoding: LiveEncoding.linear16,
        sampleRate: 16000,
        channels: 2,
        multichannel: true,
        interimResults: false,
        utteranceEndMs: 1000,
        vadEvents: true,
        smartFormat: false,
        punctuate: true,
        numerals: false,
        profanityFilter: true,
        diarize: true,
        diarizeModel: 'v1',
        mipOptOut: true,
        detectEntities: true,
        dictation: true,
        extra: <String, String>{'custom_key': 'custom-value'},
      ).toQuery();
      expect(query, containsPair('version', '2024-01'));
      expect(query, containsPair('encoding', 'linear16'));
      expect(query, containsPair('sample_rate', '16000'));
      expect(query, containsPair('channels', '2'));
      expect(query, containsPair('multichannel', 'true'));
      expect(query, containsPair('interim_results', 'false'));
      expect(query, containsPair('utterance_end_ms', '1000'));
      expect(query, containsPair('vad_events', 'true'));
      expect(query, containsPair('smart_format', 'false'));
      expect(query, containsPair('punctuate', 'true'));
      expect(query, containsPair('numerals', 'false'));
      expect(query, containsPair('profanity_filter', 'true'));
      expect(query, containsPair('diarize', 'true'));
      expect(query, containsPair('diarize_model', 'v1'));
      expect(query, containsPair('mip_opt_out', 'true'));
      expect(query, containsPair('detect_entities', 'true'));
      expect(query, containsPair('dictation', 'true'));
      expect(query, containsPair('custom_key', 'custom-value'));
    });

    test('encodings map to their wire values', () {
      expect(
        const LiveTranscriptionOptions(encoding: LiveEncoding.oggOpus)
            .toQuery(),
        containsPair('encoding', 'ogg-opus'),
      );
      expect(
        const LiveTranscriptionOptions(encoding: LiveEncoding.amrNb).toQuery(),
        containsPair('encoding', 'amr-nb'),
      );
      expect(
        const LiveTranscriptionOptions(encoding: LiveEncoding.g729).toQuery(),
        containsPair('encoding', 'g729'),
      );
    });

    test('endpointing is tri-state', () {
      expect(
        const LiveTranscriptionOptions(endpointingMs: 500).toQuery(),
        containsPair('endpointing', '500'),
      );
      expect(
        const LiveTranscriptionOptions(endpointingMs: 0).toQuery(),
        containsPair('endpointing', 'false'),
      );
      expect(
        const LiveTranscriptionOptions(endpointingMs: -1).toQuery(),
        containsPair('endpointing', 'false'),
      );
      expect(
        const LiveTranscriptionOptions(
          endpointingEnabled: false,
          endpointingMs: 800,
        ).toQuery(),
        containsPair('endpointing', 'false'),
      );
      expect(
        const LiveTranscriptionOptions(endpointingEnabled: true).toQuery(),
        isNot(contains('endpointing')),
      );
      expect(
        const LiveTranscriptionOptions(
          endpointingEnabled: true,
          endpointingMs: 800,
        ).toQuery(),
        containsPair('endpointing', '800'),
      );
    });

    test('redact renders bool, policy string, and policy lists', () {
      expect(
        const LiveTranscriptionOptions(redact: true).toQuery(),
        containsPair('redact', 'true'),
      );
      expect(
        const LiveTranscriptionOptions(redact: false).toQuery(),
        isNot(contains('redact')),
      );
      expect(
        const LiveTranscriptionOptions(redact: 'pci').toQuery(),
        containsPair('redact', 'pci'),
      );
      expect(
        const LiveTranscriptionOptions(redact: '').toQuery(),
        isNot(contains('redact')),
      );
      expect(
        const LiveTranscriptionOptions(
          redact: <Object>['pci', 'ssn'],
        ).toQuery(),
        containsPair('redact', <String>['pci', 'ssn']),
      );
      expect(
        const LiveTranscriptionOptions(redact: <Object>[]).toQuery(),
        isNot(contains('redact')),
      );
      expect(
        const LiveTranscriptionOptions(
          redact: <Object?>[null, 'numbers'],
        ).toQuery(),
        containsPair('redact', <String>['numbers']),
      );
    });

    test('smart_format suppresses redundant punctuate', () {
      expect(
        const LiveTranscriptionOptions(smartFormat: true, punctuate: true)
            .toQuery(),
        isNot(contains('punctuate')),
      );
      expect(
        const LiveTranscriptionOptions(punctuate: true).toQuery(),
        containsPair('punctuate', 'true'),
      );
      expect(
        const LiveTranscriptionOptions(smartFormat: false, punctuate: true)
            .toQuery(),
        containsPair('punctuate', 'true'),
      );
    });

    test(
        'keywords/keyterm/replace/search/tag render as repeated keys '
        'and empty lists are omitted', () {
      final Map<String, dynamic> query = const LiveTranscriptionOptions(
        keywords: <String>['alpha', 'beta'],
        keyterm: <String>['Deepgram'],
        replace: <String>['gnarly:awesome'],
        search: <String>['needle'],
        tag: <String>['env:test', 'run:1'],
      ).toQuery();
      expect(query['keywords'], <String>['alpha', 'beta']);
      expect(query['keyterm'], <String>['Deepgram']);
      expect(query['replace'], <String>['gnarly:awesome']);
      expect(query['search'], <String>['needle']);
      expect(query['tag'], <String>['env:test', 'run:1']);

      final Map<String, dynamic> empty = const LiveTranscriptionOptions(
        keywords: <String>[],
        keyterm: <String>[],
        replace: <String>[],
        search: <String>[],
        tag: <String>[],
      ).toQuery();
      expect(empty.containsKey('keywords'), isFalse);
      expect(empty.containsKey('keyterm'), isFalse);
      expect(empty.containsKey('replace'), isFalse);
      expect(empty.containsKey('search'), isFalse);
      expect(empty.containsKey('tag'), isFalse);
    });
  });

  group('LiveGapRecoveryOptions', () {
    test('defaults match the documented production tuning', () {
      const options = LiveGapRecoveryOptions();
      expect(options.enabled, isTrue);
      expect(options.maxLiveFlushBytes, 320000);
      expect(options.maxBufferBytes, 5242880);
      expect(options.audioContentType, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // live_models.dart
  // -------------------------------------------------------------------------

  group('LiveTranscriptionResult.fromJson', () {
    test('parses a full Results frame', () {
      final result = LiveTranscriptionResult.fromJson(<String, dynamic>{
        'channel_index': <Object>[0, 1],
        'duration': '1.5',
        'start': 0.25,
        'is_final': true,
        'speech_final': true,
        'from_finalize': true,
        'channel': <String, dynamic>{
          'alternatives': <Object>[
            'not-a-map',
            <String, dynamic>{
              'transcript': 'hello there',
              'confidence': 0.9,
              'words': <Object>[
                <String, dynamic>{
                  'word': 'hello',
                  'start': 0,
                  'end': 0.4,
                  'confidence': 0.99,
                  'punctuated_word': 'Hello,',
                },
              ],
            },
          ],
        },
        'entities': <Object>[
          'broken',
          <String, dynamic>{
            'label': 'LOCATION',
            'value': 'Cleveland',
            'confidence': 0.8,
            'start_word': 0,
            'end_word': 1,
          },
        ],
        'metadata': <String, dynamic>{
          'request_id': 'r-1',
          'created': '2025-01-01T00:00:00Z',
          'duration': 7.5,
          'channels': 1,
          'model_info': <String, dynamic>{
            'name': 'nova3',
            'version': 'v1',
            'arch': 'nova-3',
          },
          'models': <String>['m'],
          'model_uuid': 'u',
          'extra': <String, dynamic>{'a': 'b'},
        },
      });
      expect(result.transcript, 'hello there');
      expect(result.isFinal, isTrue);
      expect(result.speechFinal, isTrue);
      expect(result.fromFinalize, isTrue);
      expect(result.duration, 1.5);
      expect(result.start, 0.25);
      expect(result.channelIndex, <int>[0, 1]);
      expect(result.alternatives, hasLength(1));
      expect(result.alternatives.first.confidence, 0.9);
      expect(result.alternatives.first.words.first.punctuatedWord, 'Hello,');
      expect(result.entities, hasLength(1));
      expect(result.entities.first.label, 'LOCATION');
      expect(result.metadata.requestId, 'r-1');
      expect(result.metadata.modelInfo?.name, 'nova3');
      expect(result.metadata.models, <String>['m']);
      expect(result.metadata.extra, <String, dynamic>{'a': 'b'});
      expect(result.recovered, isFalse);
      expect(result.recoveredAtUtc, isNull);
    });

    test('falls back to neutral defaults for hostile frames', () {
      final empty = LiveTranscriptionResult.fromJson(<String, dynamic>{});
      expect(empty.transcript, '');
      expect(empty.alternatives, isEmpty);
      expect(empty.channelIndex, isEmpty);
      expect(empty.entities, isEmpty);
      expect(empty.duration, 0);
      expect(empty.start, 0);
      expect(empty.isFinal, isFalse);
      expect(empty.speechFinal, isFalse);
      expect(empty.fromFinalize, isFalse);
      expect(empty.metadata, isNotNull);

      final coerced = LiveTranscriptionResult.fromJson(<String, dynamic>{
        'channel_index': <Object?>['0', 2.9, 'x', null, true],
        'duration': 'not-a-number',
        'start': 3,
        'channel': 'oops',
        'metadata': 7,
      });
      expect(coerced.channelIndex, <int>[0, 2]);
      expect(coerced.duration, 0);
      expect(coerced.start, 3);
      expect(coerced.alternatives, isEmpty);
      expect(coerced.metadata.requestId, isNull);
    });

    test('normalizes maps with non-String keys', () {
      final result = LiveTranscriptionResult.fromJson(<String, dynamic>{
        'channel': <dynamic, dynamic>{
          'alternatives': <dynamic>[
            <dynamic, dynamic>{'transcript': 'normalized'},
          ],
        },
        'metadata': <dynamic, dynamic>{'request_id': 'r-2'},
      });
      expect(result.transcript, 'normalized');
      expect(result.metadata.requestId, 'r-2');

      final message = LiveMetadataMessage.fromJson(<String, dynamic>{
        'request_id': 'r-3',
      });
      expect(message.requestId, 'r-3');
    });

    test('is constructible directly for recovered results', () {
      final anchor = DateTime.utc(2025, 6, 1, 12);
      final result = LiveTranscriptionResult(
        alternatives: const <SttAlternative>[
          SttAlternative(transcript: 'gap audio'),
        ],
        channelIndex: const <int>[3],
        duration: 2.5,
        isFinal: true,
        speechFinal: true,
        metadata: SttMetadata(requestId: 'gap'),
        recovered: true,
        recoveredAtUtc: anchor,
      );
      expect(result.transcript, 'gap audio');
      expect(result.recovered, isTrue);
      expect(result.recoveredAtUtc, anchor);
      expect(result.channelIndex, <int>[3]);

      final bare = LiveTranscriptionResult(metadata: SttMetadata());
      expect(bare.transcript, '');
      expect(bare.recovered, isFalse);
    });
  });

  group('LiveMetadataMessage / LiveUtteranceEnd / LiveSpeechStarted', () {
    test('LiveMetadataMessage.fromJson parses and coerces', () {
      final message = LiveMetadataMessage.fromJson(<String, dynamic>{
        'request_id': 'rid-1',
        'transaction_key': 'tk-1',
        'sha256': 'abc123',
        'created': '2025-06-01T12:00:00Z',
        'duration': '2.5',
        'channels': '3',
      });
      expect(message.requestId, 'rid-1');
      expect(message.transactionKey, 'tk-1');
      expect(message.sha256, 'abc123');
      expect(message.created, '2025-06-01T12:00:00Z');
      expect(message.duration, 2.5);
      expect(message.channels, 3);

      final empty = LiveMetadataMessage.fromJson(<String, dynamic>{});
      expect(empty.requestId, '');
      expect(empty.transactionKey, '');
      expect(empty.sha256, '');
      expect(empty.created, '');
      expect(empty.duration, 0);
      expect(empty.channels, 0);
    });

    test('LiveUtteranceEnd.fromJson parses and coerces', () {
      final event = LiveUtteranceEnd.fromJson(<String, dynamic>{
        'channel': <Object>[1, '2', 'x'],
        'last_word_end': '4.5',
      });
      expect(event.channel, <int>[1, 2]);
      expect(event.lastWordEnd, 4.5);

      final empty = LiveUtteranceEnd.fromJson(<String, dynamic>{});
      expect(empty.channel, isEmpty);
      expect(empty.lastWordEnd, 0);
    });

    test('LiveSpeechStarted.fromJson parses and coerces', () {
      final event = LiveSpeechStarted.fromJson(<String, dynamic>{
        'channel': <Object>[0, 0],
        'timestamp': 1.25,
      });
      expect(event.channel, <int>[0, 0]);
      expect(event.timestamp, 1.25);

      final empty = LiveSpeechStarted.fromJson(<String, dynamic>{});
      expect(empty.channel, isEmpty);
      expect(empty.timestamp, 0);
    });
  });

  group('LiveErrorMessage.fromJson', () {
    test('parses a typed server Error frame', () {
      final error = LiveErrorMessage.fromJson(<String, dynamic>{
        'variant': 'SchemaError',
        'description': 'Invalid message',
        'code': 'KeytermsNotSupported',
        'message': 'raw payload',
      });
      expect(error.variant, 'SchemaError');
      expect(error.description, 'Invalid message');
      expect(error.code, 'KeytermsNotSupported');
      expect(error.message, 'raw payload');
    });

    test('defaults to empty fields and nullable code/message', () {
      final empty = LiveErrorMessage.fromJson(<String, dynamic>{});
      expect(empty.variant, '');
      expect(empty.description, '');
      expect(empty.code, isNull);
      expect(empty.message, isNull);

      final nonStrings = LiveErrorMessage.fromJson(<String, dynamic>{
        'variant': 5,
        'code': 7,
        'message': <String>['nope'],
      });
      expect(nonStrings.variant, '');
      expect(nonStrings.code, isNull);
      expect(nonStrings.message, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // live_client.dart over the loopback /v1/listen server
  // -------------------------------------------------------------------------

  group('DeepgramLiveClient (loopback /v1/listen server)',
      timeout: const Timeout(Duration(seconds: 5)), () {
    test(
        'start() opens ws://host/v1/listen with the option query and '
        'Token authorization header', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(
        options: const LiveTranscriptionOptions(
          model: 'nova-2',
          language: 'en-GB',
          version: '2024-01',
          encoding: LiveEncoding.linear16,
          sampleRate: 16000,
          channels: 2,
          multichannel: true,
          interimResults: false,
          endpointingMs: 500,
          utteranceEndMs: 1000,
          vadEvents: true,
          smartFormat: true,
          punctuate: true,
          numerals: true,
          profanityFilter: true,
          redact: 'pci',
          keywords: <String>['alpha', 'beta'],
          keyterm: <String>['Deepgram'],
          tag: <String>['env:test'],
        ),
        wsOptions: _fastWsOptions,
      );
      addTearDown(client.forceClose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      expect(client.isConnected, isTrue);
      expect(conn.request.uri.path, '/v1/listen');
      final Map<String, List<String>> query =
          conn.request.uri.queryParametersAll;
      expect(query['model'], <String>['nova-2']);
      expect(query['language'], <String>['en-GB']);
      expect(query['version'], <String>['2024-01']);
      expect(query['encoding'], <String>['linear16']);
      expect(query['sample_rate'], <String>['16000']);
      expect(query['channels'], <String>['2']);
      expect(query['multichannel'], <String>['true']);
      expect(query['interim_results'], <String>['false']);
      expect(query['endpointing'], <String>['500']);
      expect(query['utterance_end_ms'], <String>['1000']);
      expect(query['vad_events'], <String>['true']);
      expect(query['smart_format'], <String>['true']);
      expect(query['numerals'], <String>['true']);
      expect(query['profanity_filter'], <String>['true']);
      expect(query['redact'], <String>['pci']);
      expect(query['keywords'], <String>['alpha', 'beta']);
      expect(query['keyterm'], <String>['Deepgram']);
      expect(query['tag'], <String>['env:test']);
      expect(query.containsKey('punctuate'), isFalse);
      expect(
        conn.request.headers.value('Authorization'),
        'Token test-api-key',
      );
    });

    test(
        'start() without options sends a bare path; default options send '
        'model/language/interim_results', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(wsOptions: _fastWsOptions);
      addTearDown(client.forceClose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      // `options: null` skips toQuery() entirely: the server default
      // transcription settings apply.
      expect(conn.request.uri.path, '/v1/listen');
      expect(conn.request.uri.queryParameters, isEmpty);

      // An explicitly constructed default options object renders exactly the
      // documented defaults on the wire.
      final client2 = harness.client(
        options: const LiveTranscriptionOptions(),
        wsOptions: _fastWsOptions,
      );
      addTearDown(client2.forceClose);
      final conn2Future = server.nextConnection();
      await client2.start();
      final conn2 = await conn2Future;
      expect(conn2.request.uri.queryParametersAll, <String, List<String>>{
        'model': <String>['nova-3'],
        'language': <String>['en-US'],
        'interim_results': <String>['true'],
      });
    });

    test('start() is idempotent and concurrent starts share one connection',
        () async {
      final server = await _LoopbackLiveServer.start();
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
      await connFuture;
      expect(server.connections, hasLength(1));
    });

    test('results stream emits typed interim then final results', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(wsOptions: _fastWsOptions);
      addTearDown(client.forceClose);
      final results = _Recorder<LiveTranscriptionResult>(client.results);
      addTearDown(results.dispose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      conn.sendText(jsonEncode(_resultsFrame(
        transcript: 'interim text',
        isFinal: false,
      )));
      final LiveTranscriptionResult interim = await results.next;
      expect(interim.transcript, 'interim text');
      expect(interim.isFinal, isFalse);
      expect(interim.speechFinal, isFalse);
      expect(interim.duration, 1.25);
      expect(interim.start, 0.5);
      expect(interim.channelIndex, <int>[0, 1]);
      expect(interim.metadata.requestId, 'req-live');
      expect(interim.metadata.duration, 9.5);
      expect(interim.alternatives.first.confidence, 0.9);
      expect(interim.alternatives.first.words.first.punctuatedWord, 'Hello,');

      conn.sendText(jsonEncode(_resultsFrame(
        transcript: 'final transcript',
        isFinal: true,
        speechFinal: true,
      )));
      final LiveTranscriptionResult finalResult = await results.next;
      expect(finalResult.transcript, 'final transcript');
      expect(finalResult.isFinal, isTrue);
      expect(finalResult.speechFinal, isTrue);
      expect(finalResult.recovered, isFalse);
      expect(finalResult.recoveredAtUtc, isNull);
    });

    test('metadata stream emits the CloseStream Metadata summary', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(wsOptions: _fastWsOptions);
      addTearDown(client.forceClose);
      final metadata = _Recorder<LiveMetadataMessage>(client.metadata);
      addTearDown(metadata.dispose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      conn.sendText(jsonEncode(<String, Object>{
        'type': 'Metadata',
        'request_id': 'rid-9',
        'transaction_key': 'tk-9',
        'sha256': 'deadbeef',
        'created': '2025-06-01T12:00:00Z',
        'duration': 12.5,
        'channels': 2,
      }));
      final LiveMetadataMessage message = await metadata.next;
      expect(message.requestId, 'rid-9');
      expect(message.transactionKey, 'tk-9');
      expect(message.sha256, 'deadbeef');
      expect(message.created, '2025-06-01T12:00:00Z');
      expect(message.duration, 12.5);
      expect(message.channels, 2);
    });

    test('utteranceEnds stream emits UtteranceEnd events', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(
        options: const LiveTranscriptionOptions(
          vadEvents: true,
          utteranceEndMs: 1000,
        ),
        wsOptions: _fastWsOptions,
      );
      addTearDown(client.forceClose);
      final utteranceEnds = _Recorder<LiveUtteranceEnd>(client.utteranceEnds);
      addTearDown(utteranceEnds.dispose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;
      expect(
        conn.request.uri.queryParameters['utterance_end_ms'],
        '1000',
      );
      expect(conn.request.uri.queryParameters['vad_events'], 'true');

      conn.sendText(jsonEncode(<String, Object>{
        'type': 'UtteranceEnd',
        'channel': <int>[1, 0],
        'last_word_end': 3.25,
      }));
      final LiveUtteranceEnd event = await utteranceEnds.next;
      expect(event.channel, <int>[1, 0]);
      expect(event.lastWordEnd, 3.25);
    });

    test('speechStarted stream emits SpeechStarted events', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(
        options: const LiveTranscriptionOptions(vadEvents: true),
        wsOptions: _fastWsOptions,
      );
      addTearDown(client.forceClose);
      final speechStarted = _Recorder<LiveSpeechStarted>(client.speechStarted);
      addTearDown(speechStarted.dispose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      conn.sendText(jsonEncode(<String, Object>{
        'type': 'SpeechStarted',
        'channel': <int>[0, 0],
        'timestamp': 1.5,
      }));
      final LiveSpeechStarted event = await speechStarted.next;
      expect(event.channel, <int>[0, 0]);
      expect(event.timestamp, 1.5);
    });

    test('errors stream emits typed Deepgram Error frames', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(wsOptions: _fastWsOptions);
      addTearDown(client.forceClose);
      final errors = _Recorder<LiveErrorMessage>(client.errors);
      addTearDown(errors.dispose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      conn.sendText(jsonEncode(<String, Object>{
        'type': 'Error',
        'variant': 'SchemaError',
        'description': 'Cannot parse message',
        'code': 'INVALID_MESSAGE',
        'message': 'abc',
      }));
      final LiveErrorMessage error = await errors.next;
      expect(error.variant, 'SchemaError');
      expect(error.description, 'Cannot parse message');
      expect(error.code, 'INVALID_MESSAGE');
      expect(error.message, 'abc');
    });

    test('malformed frames produce ParseError events and never crash',
        () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(wsOptions: _fastWsOptions);
      addTearDown(client.forceClose);
      final errors = _Recorder<LiveErrorMessage>(client.errors);
      addTearDown(errors.dispose);
      final results = _Recorder<LiveTranscriptionResult>(client.results);
      addTearDown(results.dispose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      conn.sendText('this is not json');
      LiveErrorMessage error = await errors.next;
      expect(error.variant, 'ParseError');
      expect(error.description, 'Received a frame that is not valid JSON.');
      expect(error.message, 'this is not json');

      conn.sendText('[1,2,3]');
      error = await errors.next;
      expect(error.description, 'Received a frame that is not a JSON object.');

      conn.sendText('{"payload": true}');
      error = await errors.next;
      expect(error.description, 'Received a frame without a message type.');

      conn.sendText('{"type": 42}');
      error = await errors.next;
      expect(error.description, 'Received a frame without a message type.');

      // Binary frames and unknown types are ignored defensively.
      conn.sendBytes(<int>[1, 2, 3]);
      conn.sendText(jsonEncode(<String, Object>{'type': 'MysteryFrame'}));
      await _quiet();
      expect(errors.values, hasLength(4));
      expect(
        harness.logger.debugs,
        anyElement(contains('Ignoring unknown message type')),
      );

      // The session survived all of it.
      conn.sendText(jsonEncode(_resultsFrame(
        transcript: 'still alive',
        isFinal: true,
      )));
      final LiveTranscriptionResult result = await results.next;
      expect(result.transcript, 'still alive');
      expect(client.isConnected, isTrue);
    });

    test('sendAudio streams binary frames and skips empty chunks', () async {
      final server = await _LoopbackLiveServer.start();
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

    test('finish() sends Finalize and keeps the stream open', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(wsOptions: _fastWsOptions);
      addTearDown(client.forceClose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      await client.finish();
      expect(await conn.nextFrame(), '{"type":"Finalize"}');

      client.sendAudio(<int>[9]);
      expect(await conn.nextFrame(), <int>[9]);
      expect(client.isConnected, isTrue);
    });

    test('configure() sends Configure messages and is a no-op without fields',
        () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(wsOptions: _fastWsOptions);
      addTearDown(client.forceClose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      await client.configure(keyterms: <String>['hello', 'deepgram']);
      expect(
        jsonDecode(await conn.nextFrame() as String),
        <String, Object>{
          'type': 'Configure',
          'keyterms': <String>['hello', 'deepgram'],
        },
      );

      await client.configure(features: <String, bool>{'smart_format': true});
      expect(
        jsonDecode(await conn.nextFrame() as String),
        <String, Object>{
          'type': 'Configure',
          'features': <String, bool>{'smart_format': true},
        },
      );

      await client.configure();
      await _quiet(50);
      expect(conn.frames, hasLength(2));
    });

    test('close() sends CloseStream, drains final results, and is terminal',
        () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(wsOptions: _fastWsOptions);
      final states = _Recorder<WsConnectionState>(client.connectionStates);
      addTearDown(states.dispose);
      final results = _Recorder<LiveTranscriptionResult>(client.results);
      addTearDown(results.dispose);
      final metadata = _Recorder<LiveMetadataMessage>(client.metadata);
      addTearDown(metadata.dispose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      final Future<void> closing = client.close();
      expect(await conn.nextFrame(), '{"type":"CloseStream"}');

      // Graceful drain: final results flushed before the socket goes down.
      conn.sendText(jsonEncode(_resultsFrame(
        transcript: 'flushed on close',
        isFinal: true,
        speechFinal: true,
      )));
      conn.sendText(jsonEncode(<String, Object>{
        'type': 'Metadata',
        'request_id': 'rid-close',
        'duration': 3.5,
        'channels': 1,
      }));
      await conn.closeNormally();
      await closing;

      expect(results.values, hasLength(1));
      expect(results.values.single.transcript, 'flushed on close');
      expect(metadata.values, hasLength(1));
      expect(metadata.values.single.requestId, 'rid-close');
      await states
          .waitFor((WsConnectionState s) => s == WsConnectionState.closed);
      expect(client.isConnected, isFalse);

      // Terminal: start() throws, everything else is a no-op, close() again
      // resolves without error.
      await expectLater(
        client.start(),
        throwsA(isA<DeepgramStateException>()),
      );
      client.sendAudio(<int>[1]);
      await client.finish();
      await client.configure(keyterms: <String>['late']);
      await client.close();
      await _quiet();
      expect(conn.frames, hasLength(1)); // Only the CloseStream frame.
    });

    test('close() before start() terminalizes the session', () async {
      final server = await _LoopbackLiveServer.start();
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
      await client.finish();
      await client.forceClose();
      expect(server.connections, isEmpty);
    });

    test('forceClose() drops the socket without CloseStream', () async {
      final server = await _LoopbackLiveServer.start();
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
      await states
          .waitFor((WsConnectionState s) => s == WsConnectionState.closed);
      expect(conn.frames, isEmpty);
      await client.forceClose(); // Idempotent.
      await _quiet();
      expect(server.connections, hasLength(1));
    });

    test(
        'start() throws DeepgramWebSocketException when the upgrade is '
        'refused and the reconnect policy gives up', () async {
      final server = await _LoopbackLiveServer.start();
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
      await states
          .waitFor((WsConnectionState s) => s == WsConnectionState.failed);
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
      expect(conn.request.uri.path, '/v1/listen');
    });

    test('start() fails fast against a closed port with a give-up policy',
        () async {
      // Reserve a loopback port, free it again, and route the fake host
      // there: every connect is refused instantly, on loopback only.
      final deadServer = await _LoopbackLiveServer.start();
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
      final client = DeepgramLiveClient(
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
      await states
          .waitFor((WsConnectionState s) => s == WsConnectionState.failed);
    });

    test('the session works without an injected logger', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = DeepgramLiveClient(
        config: harness.config,
        auth: harness.auth,
        http: harness.httpEngine,
        wsOptions: _fastWsOptions,
      );
      addTearDown(client.forceClose);
      final results = _Recorder<LiveTranscriptionResult>(client.results);
      addTearDown(results.dispose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      conn.sendText(jsonEncode(_resultsFrame(
        transcript: 'default logger',
        isFinal: true,
      )));
      final LiveTranscriptionResult result = await results.next;
      expect(result.transcript, 'default logger');
    });

    test(
        'user wsOptions are forwarded: onReconnecting/onReconnected fire '
        'around the internal gap recovery', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      var userReconnectedCalls = 0;
      final List<WsReconnectContext> reconnectingContexts =
          <WsReconnectContext>[];
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

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      await conn.drop();
      await states.seen(
          1, (WsConnectionState s) => s == WsConnectionState.reconnecting);
      client.sendAudio(<int>[1, 2]);
      await states.seen(
          2, (WsConnectionState s) => s == WsConnectionState.open);
      final conn2 = await server.nextConnection();

      // The user hook fired once, with the reconnect context exposed...
      expect(userReconnectedCalls, 1);
      expect(reconnectingContexts, hasLength(1));
      expect(reconnectingContexts.single.attempt, 1);
      // ...and the composed wrapper still ran the internal gap flush.
      expect(await conn2.nextFrame(), <int>[1, 2]);
    });

    test(
        'audio buffered before the first connect is flushed on open '
        '(small gap)', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(wsOptions: _slowReconnectWsOptions);
      addTearDown(client.forceClose);

      // Captured before the session ever connects.
      client.sendAudio(<int>[7, 7, 7]);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      expect(await conn.nextFrame(), <int>[7, 7, 7]);
      expect(harness.queue.requests, isEmpty);
    });

    test(
        'audio buffered before the first connect goes through HTTPS '
        'recovery when large', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(
        options: const LiveTranscriptionOptions(model: 'nova-2'),
        wsOptions: _slowReconnectWsOptions,
        gapRecovery: const LiveGapRecoveryOptions(maxLiveFlushBytes: 2),
      );
      addTearDown(client.forceClose);
      final recovered = _Recorder<LiveTranscriptionResult>(
        client.recoveredResults,
      );
      addTearDown(recovered.dispose);
      final results = _Recorder<LiveTranscriptionResult>(client.results);
      addTearDown(results.dispose);

      harness.queue.enqueueJson(_prerecordedBody(<String>['pre-connect gap']));

      final DateTime beforeBuffering = DateTime.now().toUtc();
      client.sendAudio(<int>[1, 2, 3, 4]);
      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      final LiveTranscriptionResult event = await recovered.next;
      expect(event.transcript, 'pre-connect gap');
      expect(event.recovered, isTrue);
      final DateTime? anchor = event.recoveredAtUtc;
      expect(anchor, isNotNull);
      expect(
          anchor!.isAfter(beforeBuffering.subtract(
            const Duration(seconds: 1),
          )),
          isTrue);
      expect(event.isFinal, isTrue);
      expect(event.speechFinal, isTrue);
      expect(event.start, 0);
      expect(event.duration, 4.5);
      expect(event.channelIndex, <int>[0]);
      expect(event.metadata.requestId, 'req-recovery');
      expect(results.values, isEmpty);

      final http.Request request = harness.queue.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/v1/listen');
      expect(request.url.scheme, 'http');
      expect(request.url.host, _deepgramTestHost);
      expect(request.url.queryParameters['model'], 'nova-2');
      expect(request.url.queryParameters['language'], 'en-US');
      expect(
          request.url.queryParameters.containsKey('interim_results'), isFalse);
      expect(request.headers['Authorization'], 'Token test-api-key');
      expect(request.headers['Content-Type'], 'audio/wav');
      expect(request.bodyBytes, <int>[1, 2, 3, 4]);
      await _quiet();
      expect(conn.frames, isEmpty);
    });

    test(
        'reconnect with nothing buffered flushes nothing and issues no '
        'HTTPS call', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(wsOptions: _slowReconnectWsOptions);
      addTearDown(client.forceClose);
      final states = _Recorder<WsConnectionState>(client.connectionStates);
      addTearDown(states.dispose);
      final recovered = _Recorder<LiveTranscriptionResult>(
        client.recoveredResults,
      );
      addTearDown(recovered.dispose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      await conn.drop();
      await states.seen(
          1, (WsConnectionState s) => s == WsConnectionState.reconnecting);
      expect(client.reconnectAttempts, 1);
      await states.seen(
          2, (WsConnectionState s) => s == WsConnectionState.open);
      final conn2 = await server.nextConnection();

      await _quiet();
      expect(conn2.frames, isEmpty);
      expect(harness.queue.requests, isEmpty);
      expect(recovered.values, isEmpty);
      expect(client.reconnectAttempts, 0);
    });

    test(
        'small gap: buffered audio is flushed into the reconnected socket '
        'before live audio', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(wsOptions: _slowReconnectWsOptions);
      addTearDown(client.forceClose);
      final states = _Recorder<WsConnectionState>(client.connectionStates);
      addTearDown(states.dispose);
      final recovered = _Recorder<LiveTranscriptionResult>(
        client.recoveredResults,
      );
      addTearDown(recovered.dispose);
      final results = _Recorder<LiveTranscriptionResult>(client.results);
      addTearDown(results.dispose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      await conn.drop();
      await states.seen(
          1, (WsConnectionState s) => s == WsConnectionState.reconnecting);

      // Audio keeps flowing while disconnected: it is buffered.
      client.sendAudio(<int>[10, 20, 30]);
      client.sendAudio(<int>[40, 50]);

      await states.seen(
          2, (WsConnectionState s) => s == WsConnectionState.open);
      final conn2 = await server.nextConnection();

      // The gap is flushed first, then live audio continues.
      expect(await conn2.nextFrame(), <int>[10, 20, 30]);
      expect(await conn2.nextFrame(), <int>[40, 50]);
      client.sendAudio(<int>[60]);
      expect(await conn2.nextFrame(), <int>[60]);

      expect(harness.queue.requests, isEmpty);
      expect(recovered.values, isEmpty);
      expect(results.values, isEmpty);
      expect(
        harness.logger.infos,
        anyElement(contains('Flushing 5 buffered audio bytes')),
      );
      expect(states.values, <WsConnectionState>[
        WsConnectionState.connecting,
        WsConnectionState.open,
        WsConnectionState.reconnecting,
        WsConnectionState.open,
      ]);
    });

    test(
        'large gap: HTTPS pre-recorded recovery anchored at the disconnect '
        'instant', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(
        options: const LiveTranscriptionOptions(
          encoding: LiveEncoding.linear16,
          sampleRate: 16000,
          smartFormat: true,
          keywords: <String>['alpha', 'beta'],
        ),
        wsOptions: _slowReconnectWsOptions,
        gapRecovery: const LiveGapRecoveryOptions(maxLiveFlushBytes: 4),
      );
      addTearDown(client.forceClose);
      final states = _Recorder<WsConnectionState>(client.connectionStates);
      addTearDown(states.dispose);
      final recovered = _Recorder<LiveTranscriptionResult>(
        client.recoveredResults,
      );
      addTearDown(recovered.dispose);
      final results = _Recorder<LiveTranscriptionResult>(client.results);
      addTearDown(results.dispose);

      harness.queue.enqueueJson(_prerecordedBody(
        <String>['recovered channel zero', 'recovered channel one'],
      ));

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      final DateTime beforeDrop = DateTime.now().toUtc();
      await conn.drop();
      await states.seen(
          1, (WsConnectionState s) => s == WsConnectionState.reconnecting);
      client.sendAudio(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
      await states.seen(
          2, (WsConnectionState s) => s == WsConnectionState.open);
      final conn2 = await server.nextConnection();

      final LiveTranscriptionResult channelZero = await recovered.next;
      final LiveTranscriptionResult channelOne = await recovered.next;
      expect(channelZero.transcript, 'recovered channel zero');
      expect(channelOne.transcript, 'recovered channel one');
      expect(channelZero.channelIndex, <int>[0]);
      expect(channelOne.channelIndex, <int>[1]);
      expect(channelZero.recovered, isTrue);
      expect(channelOne.recovered, isTrue);
      final DateTime anchor = channelZero.recoveredAtUtc!;
      expect(
        anchor.isAfter(beforeDrop.subtract(const Duration(seconds: 1))),
        isTrue,
      );
      expect(
        anchor.isBefore(DateTime.now().toUtc().add(const Duration(seconds: 1))),
        isTrue,
      );
      expect(channelZero.isFinal, isTrue);
      expect(channelZero.speechFinal, isTrue);
      expect(channelZero.start, 0);
      expect(channelZero.duration, 4.5);
      expect(channelZero.metadata.requestId, 'req-recovery');
      expect(channelOne.recoveredAtUtc, anchor);
      // Recovered results are NOT repeated on the live stream.
      expect(results.values, isEmpty);

      final http.Request request = harness.queue.requests.single;
      expect(request.method, 'POST');
      expect(request.url.scheme, 'http');
      expect(request.url.host, _deepgramTestHost);
      expect(request.url.path, '/v1/listen');
      expect(request.url.queryParameters['model'], 'nova-3');
      expect(request.url.queryParameters['language'], 'en-US');
      expect(request.url.queryParameters['smart_format'], 'true');
      expect(request.url.queryParametersAll['keywords'],
          <String>['alpha', 'beta']);
      // Raw-PCM sessions recover with the raw content type.
      expect(request.headers['Content-Type'], 'audio/raw;rate=16000');
      expect(request.headers['Authorization'], 'Token test-api-key');
      expect(request.bodyBytes, <int>[1, 2, 3, 4, 5, 6, 7, 8]);
      expect(
        harness.logger.infos,
        anyElement(contains('HTTPS gap recovery complete')),
      );
      // Large gaps are never flushed into the live socket.
      await _quiet();
      expect(conn2.frames, isEmpty);
    });

    test('large gap strips streaming-only params from the recovery query',
        () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(
        options: const LiveTranscriptionOptions(
          interimResults: true,
          endpointingMs: 300,
          utteranceEndMs: 700,
          vadEvents: true,
          channels: 2,
          smartFormat: true,
        ),
        wsOptions: _slowReconnectWsOptions,
        gapRecovery: const LiveGapRecoveryOptions(maxLiveFlushBytes: 1),
      );
      addTearDown(client.forceClose);
      final states = _Recorder<WsConnectionState>(client.connectionStates);
      addTearDown(states.dispose);

      harness.queue.enqueueJson(_prerecordedBody(<String>['stripped query']));

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;
      await conn.drop();
      await states.seen(
          1, (WsConnectionState s) => s == WsConnectionState.reconnecting);
      client.sendAudio(<int>[1, 2, 3]);
      await states.seen(
          2, (WsConnectionState s) => s == WsConnectionState.open);
      await server.nextConnection();
      await _until(() => harness.queue.requests.length == 1);

      final Map<String, String> query =
          harness.queue.requests.single.url.queryParameters;
      expect(query['model'], 'nova-3');
      expect(query['smart_format'], 'true');
      expect(query.containsKey('interim_results'), isFalse);
      expect(query.containsKey('endpointing'), isFalse);
      expect(query.containsKey('utterance_end_ms'), isFalse);
      expect(query.containsKey('vad_events'), isFalse);
      expect(query.containsKey('channels'), isFalse);
      // No encoding/sample rate: containerized default content type.
      expect(
        harness.queue.requests.single.headers['Content-Type'],
        'audio/wav',
      );
    });

    test('an explicit audioContentType override wins over derivation',
        () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(
        options: const LiveTranscriptionOptions(
          encoding: LiveEncoding.linear16,
          sampleRate: 16000,
        ),
        wsOptions: _slowReconnectWsOptions,
        gapRecovery: const LiveGapRecoveryOptions(
          maxLiveFlushBytes: 1,
          audioContentType: 'audio/mpeg',
        ),
      );
      addTearDown(client.forceClose);
      final states = _Recorder<WsConnectionState>(client.connectionStates);
      addTearDown(states.dispose);

      harness.queue.enqueueJson(_prerecordedBody(<String>['override']));

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;
      await conn.drop();
      await states.seen(
          1, (WsConnectionState s) => s == WsConnectionState.reconnecting);
      client.sendAudio(<int>[1, 2, 3, 4, 5]);
      await states.seen(
          2, (WsConnectionState s) => s == WsConnectionState.open);
      await server.nextConnection();
      await _until(() => harness.queue.requests.length == 1);
      expect(
        harness.queue.requests.single.headers['Content-Type'],
        'audio/mpeg',
      );
    });

    test('gap recovery disabled drops buffered audio silently', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(
        wsOptions: _slowReconnectWsOptions,
        gapRecovery: const LiveGapRecoveryOptions(enabled: false),
      );
      addTearDown(client.forceClose);
      final states = _Recorder<WsConnectionState>(client.connectionStates);
      addTearDown(states.dispose);
      final recovered = _Recorder<LiveTranscriptionResult>(
        client.recoveredResults,
      );
      addTearDown(recovered.dispose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      await conn.drop();
      await states.seen(
          1, (WsConnectionState s) => s == WsConnectionState.reconnecting);
      client.sendAudio(<int>[1, 2, 3]);
      await states.seen(
          2, (WsConnectionState s) => s == WsConnectionState.open);
      final conn2 = await server.nextConnection();

      await _quiet();
      expect(conn2.frames, isEmpty);
      expect(harness.queue.requests, isEmpty);
      expect(recovered.values, isEmpty);
    });

    test(
        'buffer cap drops newer chunks with a warning and flushes only '
        'what fit', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(
        wsOptions: _slowReconnectWsOptions,
        gapRecovery: const LiveGapRecoveryOptions(
          maxBufferBytes: 8,
          maxLiveFlushBytes: 8,
        ),
      );
      addTearDown(client.forceClose);
      final states = _Recorder<WsConnectionState>(client.connectionStates);
      addTearDown(states.dispose);

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;

      await conn.drop();
      await states.seen(
          1, (WsConnectionState s) => s == WsConnectionState.reconnecting);
      client.sendAudio(<int>[1, 2, 3, 4, 5]); // Fits (5 <= 8).
      client.sendAudio(<int>[6, 7, 8, 9, 10]); // Would exceed: dropped.
      expect(
        harness.logger.warns,
        anyElement(contains('Live gap buffer is full')),
      );
      await states.seen(
          2, (WsConnectionState s) => s == WsConnectionState.open);
      final conn2 = await server.nextConnection();

      expect(await conn2.nextFrame(), <int>[1, 2, 3, 4, 5]);
      await _quiet();
      expect(conn2.frames, hasLength(1));
      expect(harness.queue.requests, isEmpty);
    });

    test(
        'a failed HTTPS recovery logs a warning and the session keeps '
        'working', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(
        wsOptions: _slowReconnectWsOptions,
        gapRecovery: const LiveGapRecoveryOptions(maxLiveFlushBytes: 2),
      );
      addTearDown(client.forceClose);
      final states = _Recorder<WsConnectionState>(client.connectionStates);
      addTearDown(states.dispose);
      final recovered = _Recorder<LiveTranscriptionResult>(
        client.recoveredResults,
      );
      addTearDown(recovered.dispose);
      final results = _Recorder<LiveTranscriptionResult>(client.results);
      addTearDown(results.dispose);

      harness.queue.enqueueError(StateError('recovery transport died'));

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;
      await conn.drop();
      await states.seen(
          1, (WsConnectionState s) => s == WsConnectionState.reconnecting);
      client.sendAudio(<int>[1, 2, 3, 4, 5]);
      await states.seen(
          2, (WsConnectionState s) => s == WsConnectionState.open);
      final conn2 = await server.nextConnection();

      await _until(() => harness.logger.warns.any(
          (String message) => message.contains('HTTPS gap recovery failed')));
      expect(recovered.values, isEmpty);
      expect(
        harness.logger.warns,
        anyElement(contains('transcript for the outage window is lost')),
      );

      // Live transcription is unaffected by the failed recovery.
      client.sendAudio(<int>[9]);
      expect(await conn2.nextFrame(), <int>[9]);
      conn2.sendText(jsonEncode(_resultsFrame(
        transcript: 'live after failed recovery',
        isFinal: true,
      )));
      final LiveTranscriptionResult result = await results.next;
      expect(result.transcript, 'live after failed recovery');
    });

    test('uninterpretable recovery responses emit nothing', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(
        wsOptions: _slowReconnectWsOptions,
        gapRecovery: const LiveGapRecoveryOptions(maxLiveFlushBytes: 2),
      );
      addTearDown(client.forceClose);
      final states = _Recorder<WsConnectionState>(client.connectionStates);
      addTearDown(states.dispose);
      final recovered = _Recorder<LiveTranscriptionResult>(
        client.recoveredResults,
      );
      addTearDown(recovered.dispose);

      harness.queue.enqueueJson(<String, dynamic>{'results': 'not-a-map'});
      harness.queue.enqueueJson(
        <String, dynamic>{
          'results': <String, dynamic>{'channels': 'not-a-list'},
        },
      );
      harness.queue.enqueueJson(
        <String, dynamic>{
          'results': <String, dynamic>{
            'channels': <Object>[
              'not-a-map',
              <String, dynamic>{'alternatives': <Object>[]},
            ],
          },
        },
      );

      final connFuture = server.nextConnection();
      await client.start();
      var conn = await connFuture;
      for (var episode = 1; episode <= 3; episode++) {
        await conn.drop();
        await states.seen(
          episode,
          (WsConnectionState s) => s == WsConnectionState.reconnecting,
        );
        client.sendAudio(<int>[1, 2, 3]);
        await states.seen(
          episode + 1,
          (WsConnectionState s) => s == WsConnectionState.open,
        );
        conn = await server.nextConnection();
      }
      await _until(() => harness.queue.requests.length == 3);
      await _quiet();

      expect(recovered.values, isEmpty);
      expect(conn.frames, isEmpty);
    });

    test('malformed alternatives inside a recovery response are skipped',
        () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final client = harness.client(
        wsOptions: _slowReconnectWsOptions,
        gapRecovery: const LiveGapRecoveryOptions(maxLiveFlushBytes: 2),
      );
      addTearDown(client.forceClose);
      final states = _Recorder<WsConnectionState>(client.connectionStates);
      addTearDown(states.dispose);
      final recovered = _Recorder<LiveTranscriptionResult>(
        client.recoveredResults,
      );
      addTearDown(recovered.dispose);

      harness.queue.enqueueJson(
        <String, dynamic>{
          'metadata': <String, dynamic>{'request_id': 'req-mixed'},
          'results': <String, dynamic>{
            'channels': <Object>[
              <String, dynamic>{
                'alternatives': <Object>[
                  'broken-entry',
                  <String, dynamic>{'transcript': 'the good one'},
                ],
              },
            ],
          },
        },
      );

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;
      await conn.drop();
      await states.seen(
          1, (WsConnectionState s) => s == WsConnectionState.reconnecting);
      client.sendAudio(<int>[1, 2, 3, 4]);
      await states.seen(
          2, (WsConnectionState s) => s == WsConnectionState.open);
      await server.nextConnection();

      final LiveTranscriptionResult event = await recovered.next;
      expect(event.transcript, 'the good one');
      expect(event.metadata.requestId, 'req-mixed');
      expect(event.alternatives, hasLength(1));
    });

    test(
        'a second large gap waits for the in-flight recovery (serialized '
        'chain)', () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final scriptable = _ScriptableHttp();
      final harness = _Harness(server, httpClient: scriptable);
      final client = harness.client(
        wsOptions: _slowReconnectWsOptions,
        gapRecovery: const LiveGapRecoveryOptions(maxLiveFlushBytes: 2),
      );
      addTearDown(client.forceClose);
      final states = _Recorder<WsConnectionState>(client.connectionStates);
      addTearDown(states.dispose);
      final recovered = _Recorder<LiveTranscriptionResult>(
        client.recoveredResults,
      );
      addTearDown(recovered.dispose);

      final _PendingResponse firstResponse = scriptable.enqueue();
      final _PendingResponse secondResponse = scriptable.enqueue();

      final connFuture = server.nextConnection();
      await client.start();
      final conn1 = await connFuture;

      // Episode 1: large gap -> recovery 1 starts and hangs.
      await conn1.drop();
      await states.seen(
          1, (WsConnectionState s) => s == WsConnectionState.reconnecting);
      client.sendAudio(<int>[1, 2, 3]);
      await states.seen(
          2, (WsConnectionState s) => s == WsConnectionState.open);
      final conn2 = await server.nextConnection();
      await _until(() => scriptable.requests.length == 1);

      // Episode 2 while recovery 1 is still in flight.
      await conn2.drop();
      await states.seen(
          2, (WsConnectionState s) => s == WsConnectionState.reconnecting);
      client.sendAudio(<int>[4, 5, 6]);
      await states.seen(
          3, (WsConnectionState s) => s == WsConnectionState.open);
      final conn3 = await server.nextConnection();
      expect(
        harness.logger.infos,
        anyElement(contains('already running; the new gap')),
      );
      // The queued gap has not been uploaded yet.
      expect(scriptable.requests, hasLength(1));

      firstResponse.respondJson(_prerecordedBody(<String>['first gap']));
      final LiveTranscriptionResult first = await recovered.next;
      expect(first.transcript, 'first gap');

      await _until(() => scriptable.requests.length == 2);
      secondResponse.respondJson(_prerecordedBody(<String>['second gap']));
      final LiveTranscriptionResult second = await recovered.next;
      expect(second.transcript, 'second gap');
      expect(second.recoveredAtUtc!.isAfter(first.recoveredAtUtc!), isTrue);
      expect(conn3.frames, isEmpty);
    });

    test('recovered results completing after close are dropped silently',
        () async {
      final server = await _LoopbackLiveServer.start();
      addTearDown(server.shutdown);
      final scriptable = _ScriptableHttp();
      final harness = _Harness(server, httpClient: scriptable);
      final client = harness.client(
        wsOptions: _slowReconnectWsOptions,
        gapRecovery: const LiveGapRecoveryOptions(maxLiveFlushBytes: 2),
      );
      final recovered = _Recorder<LiveTranscriptionResult>(
        client.recoveredResults,
      );
      addTearDown(recovered.dispose);
      final states = _Recorder<WsConnectionState>(client.connectionStates);
      addTearDown(states.dispose);

      final _PendingResponse pending = scriptable.enqueue();

      final connFuture = server.nextConnection();
      await client.start();
      final conn = await connFuture;
      await conn.drop();
      await states.seen(
          1, (WsConnectionState s) => s == WsConnectionState.reconnecting);
      client.sendAudio(<int>[1, 2, 3]);
      await states.seen(
          2, (WsConnectionState s) => s == WsConnectionState.open);
      await server.nextConnection();
      await _until(() => scriptable.requests.length == 1);

      // Session torn down while the recovery is still in flight.
      await client.forceClose();
      pending.respondJson(_prerecordedBody(<String>['too late']));
      await _quiet(150);

      expect(recovered.values, isEmpty);
      expect(
        harness.logger.infos,
        anyElement(contains('HTTPS gap recovery complete')),
      );
      expect(
        harness.logger.warns
            .where((String message) => message.contains('Failed to interpret')),
        isEmpty,
      );
    });
  });
}

bool _retryOnceThenGiveUp(WsCloseContext context) => context.attempt < 2;
