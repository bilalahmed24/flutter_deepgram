/// Unit tests for `lib/src/agent/agent_messages.dart` (typed Voice Agent
/// server events) plus the exact client-message wire shapes emitted by
/// `lib/src/agent/agent_client.dart`.
///
/// Part one exercises every `fromJson` factory with plain JSON literals —
/// happy paths, missing/null/malformed fields — pinning the defensive
/// parsing contract (a bad frame can never crash a stream; latency figures
/// arrive as JSON *strings* and are coerced defensively).
///
/// Part two drives a real `DeepgramVoiceAgent` through its full handshake
/// (connect → Welcome → Settings → SettingsApplied) against a scriptable
/// WebSocket server bound to `127.0.0.1` on an ephemeral port, so the exact
/// client message frames (`UpdateListen`, `UpdateThink`, `UpdateSpeak`,
/// `UpdatePrompt`, `InjectUserMessage`, `InjectAgentMessage`,
/// `FunctionCallResponse`, `KeepAlive`, `ForceEndTurn`,
/// `__customToThinkProvider`, binary Media) and the server-event pump
/// dispatch can be verified end to end. All traffic stays on loopback — no
/// external network is ever touched.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:test/test.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';

const Duration _waitTimeout = Duration(seconds: 5);

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
///
/// `DeepgramVoiceAgent` builds its own `ResilientWebSocket` with the default
/// `IoWsFactory` (there is no factory injection point), and
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

  void _markDone() {
    if (_done) return;
    _done = true;
    for (final waiter in _doneWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _doneWaiters.clear();
  }
}

/// A scriptable WebSocket server standing in for
/// `wss://agent.deepgram.com`.
class _LoopbackAgentServer {
  _LoopbackAgentServer._();

  late final HttpServer _server;
  late final StreamSubscription<HttpRequest> _serverSub;

  /// Accepted connections, in order.
  final List<_AgentConn> connections = <_AgentConn>[];

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

/// Wires a config, auth, and HTTP engine against [server].
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

  /// Runs the full handshake: connect → Welcome → Settings →
  /// SettingsApplied, and resolves with the connection and the agent.
  Future<(_AgentConn, DeepgramVoiceAgent)> startSession({
    VoiceAgentSettings settings = _defaultSettings,
    ResilientWebSocketOptions? wsOptions,
    DeepgramLogger? logger,
    void Function(DeepgramVoiceAgent agent)? onCreated,
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
      'request_id': 'req-handshake',
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
Future<void> _quiet([int milliseconds = 80]) =>
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
  // Server events: defensive fromJson parsing (pure JSON literals)
  // -------------------------------------------------------------------------

  group('AgentWelcome.fromJson', () {
    test('parses the documented frame', () {
      final json = <String, dynamic>{
        'type': 'Welcome',
        'request_id': 'req-abc-123',
      };
      final event = AgentWelcome.fromJson(json);
      expect(event.requestId, 'req-abc-123');
      expect(event.raw, same(json));
    });

    test('coerces numeric request ids and defaults missing ones to empty', () {
      expect(
        AgentWelcome.fromJson(<String, dynamic>{
          'type': 'Welcome',
          'request_id': 42,
        }).requestId,
        '42',
      );
      expect(
        AgentWelcome.fromJson(<String, dynamic>{'type': 'Welcome'}).requestId,
        '',
      );
      expect(
        AgentWelcome.fromJson(<String, dynamic>{'request_id': null}).requestId,
        '',
      );
      expect(
        AgentWelcome.fromJson(<String, dynamic>{
          'request_id': <String>['nope'],
        }).requestId,
        '',
      );
    });
  });

  group('AgentSettingsApplied / void events', () {
    test('preserve the raw frame', () {
      final json = <String, dynamic>{'type': 'SettingsApplied'};
      expect(AgentSettingsApplied.fromJson(json).raw, same(json));
      expect(AgentUserStartedSpeaking.fromJson(json).raw, same(json));
      expect(AgentAgentAudioDone.fromJson(json).raw, same(json));
    });

    test('default raw to an empty map when constructed directly', () {
      expect(const AgentSettingsApplied().raw, isEmpty);
      expect(const AgentUserStartedSpeaking().raw, isEmpty);
      expect(const AgentAgentAudioDone().raw, isEmpty);
      expect(const AgentWelcome(requestId: 'x').raw, isEmpty);
    });
  });

  group('AgentConversationText.fromJson', () {
    test('parses a user turn with language metadata', () {
      final event = AgentConversationText.fromJson(<String, dynamic>{
        'type': 'ConversationText',
        'role': 'user',
        'content': 'Hola, ¿cómo estás?',
        'languages_hinted': <String>['en', 'es'],
        'languages': <String>['es', 'en'],
      });
      expect(event.role, 'user');
      expect(event.content, 'Hola, ¿cómo estás?');
      expect(event.languagesHinted, <String>['en', 'es']);
      expect(event.languages, <String>['es', 'en']);
      expect(event.raw['type'], 'ConversationText');
    });

    test('parses an assistant turn without language metadata', () {
      final event = AgentConversationText.fromJson(<String, dynamic>{
        'type': 'ConversationText',
        'role': 'assistant',
        'content': '¡Muy bien!',
      });
      expect(event.role, 'assistant');
      expect(event.content, '¡Muy bien!');
      expect(event.languagesHinted, isNull);
      expect(event.languages, isNull);
    });

    test('never crashes on malformed fields', () {
      final event = AgentConversationText.fromJson(<String, dynamic>{
        'role': 7,
        'content': true,
        'languages_hinted': 'en',
        'languages': <dynamic>['en', 3, null, 'fr'],
      });
      expect(event.role, '7');
      expect(event.content, '');
      expect(event.languagesHinted, isNull);
      expect(event.languages, <String>['en', 'fr']);
    });

    test('defaults missing fields to empty values', () {
      final event = AgentConversationText.fromJson(<String, dynamic>{});
      expect(event.role, '');
      expect(event.content, '');
      expect(event.languagesHinted, isNull);
      expect(event.languages, isNull);
    });
  });

  group('AgentAgentThinking.fromJson', () {
    test('parses the thought content', () {
      final event = AgentAgentThinking.fromJson(<String, dynamic>{
        'type': 'AgentThinking',
        'content': 'The user wants a cab.',
      });
      expect(event.content, 'The user wants a cab.');
    });

    test('coerces numbers and defaults missing content to empty', () {
      expect(
        AgentAgentThinking.fromJson(<String, dynamic>{'content': 3.5}).content,
        '3.5',
      );
      expect(
        AgentAgentThinking.fromJson(<String, dynamic>{'content': false})
            .content,
        '',
      );
      expect(AgentAgentThinking.fromJson(<String, dynamic>{}).content, '');
    });
  });

  group('AgentAgentStartedSpeaking.fromJson', () {
    test('parses the latency figures delivered as JSON strings', () {
      final event = AgentAgentStartedSpeaking.fromJson(<String, dynamic>{
        'type': 'AgentStartedSpeaking',
        'total_latency': '0.52',
        'tts_latency': '0.19',
        'ttt_latency': '0.33',
      });
      expect(event.totalLatency, '0.52');
      expect(event.ttsLatency, '0.19');
      expect(event.tttLatency, '0.33');
    });

    test('coerces numeric latencies and defaults missing ones to empty', () {
      final event = AgentAgentStartedSpeaking.fromJson(<String, dynamic>{
        'total_latency': 1.5,
        'tts_latency': <String>['x'],
        'ttt_latency': null,
      });
      expect(event.totalLatency, '1.5');
      expect(event.ttsLatency, '');
      expect(event.tttLatency, '');
    });
  });

  group('AgentLatencyReport.fromJson', () {
    test('parses all seven per-stage timings from JSON strings', () {
      final event = AgentLatencyReport.fromJson(<String, dynamic>{
        'type': 'LatencyReport',
        'stt_latency': '0.31',
        'ttt_token_latency': '0.22',
        'ttt_text_latency': '0.24',
        'ttt_tool_latency': '0.28',
        'ttt_thinking_latency': '0.26',
        'tts_latency': '0.18',
        'total_latency': '0.73',
      });
      expect(event.sttLatency, '0.31');
      expect(event.tttTokenLatency, '0.22');
      expect(event.tttTextLatency, '0.24');
      expect(event.tttToolLatency, '0.28');
      expect(event.tttThinkingLatency, '0.26');
      expect(event.ttsLatency, '0.18');
      expect(event.totalLatency, '0.73');
      expect(event.raw['type'], 'LatencyReport');
    });

    test('coerces numeric timings defensively', () {
      final event = AgentLatencyReport.fromJson(<String, dynamic>{
        'stt_latency': 0.4,
        'total_latency': 2,
      });
      expect(event.sttLatency, '0.4');
      expect(event.totalLatency, '2');
      expect(event.tttTokenLatency, isNull);
    });

    test('yields nulls for missing or malformed timings', () {
      final event = AgentLatencyReport.fromJson(<String, dynamic>{
        'stt_latency': null,
        'tts_latency': true,
      });
      expect(event.sttLatency, isNull);
      expect(event.ttsLatency, isNull);
      expect(event.totalLatency, isNull);
      final empty = AgentLatencyReport.fromJson(<String, dynamic>{});
      expect(empty.sttLatency, isNull);
      expect(empty.tttThinkingLatency, isNull);
    });
  });

  group('AgentFunctionCallRequest.fromJson', () {
    test('parses requested functions with every field', () {
      final event = AgentFunctionCallRequest.fromJson(<String, dynamic>{
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
      expect(event.functions, hasLength(2));
      final first = event.functions.first;
      expect(first.id, 'call-1');
      expect(first.name, 'get_weather');
      expect(first.arguments, '{"city":"SF"}');
      expect(first.clientSide, isTrue);
      expect(first.thoughtSignature, 'sig-1');
      expect(first.raw['id'], 'call-1');
      final second = event.functions[1];
      expect(second.clientSide, isFalse);
      expect(second.thoughtSignature, isNull);
    });

    test('malformed functions arrays yield an empty list', () {
      expect(
        AgentFunctionCallRequest.fromJson(<String, dynamic>{
          'functions': 'nope',
        }).functions,
        isEmpty,
      );
      expect(
        AgentFunctionCallRequest.fromJson(<String, dynamic>{}).functions,
        isEmpty,
      );
      expect(
        AgentFunctionCallRequest.fromJson(<String, dynamic>{
          'functions': null,
        }).functions,
        isEmpty,
      );
    });

    test('non-map entries are skipped; map entries parse defensively', () {
      final event = AgentFunctionCallRequest.fromJson(<String, dynamic>{
        'functions': <dynamic>[
          'not-a-map',
          42,
          null,
          <String, dynamic>{'name': 'partial'},
          <String, dynamic>{
            'id': 9,
            'name': true,
            'arguments': <dynamic>[1],
            'client_side': 'yes',
          },
        ],
      });
      expect(event.functions, hasLength(2));
      final partial = event.functions[0];
      expect(partial.id, '');
      expect(partial.name, 'partial');
      expect(partial.arguments, '');
      expect(partial.clientSide, isFalse);
      final coerced = event.functions[1];
      expect(coerced.id, '9');
      expect(coerced.name, '');
      expect(coerced.arguments, '');
      expect(coerced.clientSide, isFalse);
    });
  });

  group('AgentFunctionCallCancelled.fromJson', () {
    test('parses the cancelled call ids', () {
      final event = AgentFunctionCallCancelled.fromJson(<String, dynamic>{
        'type': 'FunctionCallCancelled',
        'functions': <dynamic>[
          <String, dynamic>{'id': 'call-1', 'name': 'get_weather'},
          <String, dynamic>{'id': 'call-2', 'name': 'check_order'},
        ],
      });
      expect(event.functions, hasLength(2));
      expect(event.functions.first.id, 'call-1');
      expect(event.functions.first.name, 'get_weather');
      expect(event.functions[1].id, 'call-2');
    });

    test('malformed arrays and entries never crash', () {
      expect(
        AgentFunctionCallCancelled.fromJson(<String, dynamic>{
          'type': 'FunctionCallCancelled',
        }).functions,
        isEmpty,
      );
      expect(
        AgentFunctionCallCancelled.fromJson(<String, dynamic>{
          'functions': <dynamic>[
            'skip-me',
            <String, dynamic>{'id': 5},
            <String, dynamic>{'name': false},
          ],
        }).functions,
        hasLength(2),
      );
    });
  });

  group('AgentInjectionRefused / AgentErrorEvent / AgentWarningEvent', () {
    test('AgentInjectionRefused parses the refusal message', () {
      final event = AgentInjectionRefused.fromJson(<String, dynamic>{
        'type': 'InjectionRefused',
        'message': 'Cannot inject while the agent is thinking.',
      });
      expect(event.message, 'Cannot inject while the agent is thinking.');
      expect(
        AgentInjectionRefused.fromJson(<String, dynamic>{'message': 7}).message,
        '7',
      );
      expect(
        AgentInjectionRefused.fromJson(<String, dynamic>{}).message,
        '',
      );
    });

    test('AgentErrorEvent parses description and code', () {
      final event = AgentErrorEvent.fromJson(<String, dynamic>{
        'type': 'Error',
        'description': 'Invalid think provider.',
        'code': 'SETTINGS_INVALID',
      });
      expect(event.description, 'Invalid think provider.');
      expect(event.code, 'SETTINGS_INVALID');
      final malformed = AgentErrorEvent.fromJson(<String, dynamic>{
        'description': 404,
        'code': <String>['x'],
      });
      expect(malformed.description, '404');
      expect(malformed.code, '');
    });

    test('AgentWarningEvent parses description and code', () {
      final event = AgentWarningEvent.fromJson(<String, dynamic>{
        'type': 'Warning',
        'description': 'Keyterm list is too long.',
        'code': 'WARNING_KEYTERMS_TRUNCATED',
      });
      expect(event.description, 'Keyterm list is too long.');
      expect(event.code, 'WARNING_KEYTERMS_TRUNCATED');
      final empty = AgentWarningEvent.fromJson(<String, dynamic>{});
      expect(empty.description, '');
      expect(empty.code, '');
    });
  });

  group('AgentHistoryEvent.fromJson', () {
    test('parses a text entry', () {
      final event = AgentHistoryEvent.fromJson(<String, dynamic>{
        'type': 'History',
        'role': 'user',
        'content': 'I need a ride.',
      });
      expect(event.role, 'user');
      expect(event.content, 'I need a ride.');
      expect(event.functionCalls, isNull);
    });

    test('parses a function_calls entry with every record field', () {
      final event = AgentHistoryEvent.fromJson(<String, dynamic>{
        'type': 'History',
        'function_calls': <dynamic>[
          <String, dynamic>{
            'id': 'call-1',
            'name': 'book_cab',
            'arguments': '{"to":"SFO"}',
            'response': '{"eta":9}',
            'client_side': true,
            'thought_signature': 'sig',
          },
          <String, dynamic>{'id': 'call-2', 'name': 'cancel', 'arguments': ''},
        ],
      });
      expect(event.role, isNull);
      expect(event.content, isNull);
      final calls = event.functionCalls!;
      expect(calls, hasLength(2));
      expect(calls.first.id, 'call-1');
      expect(calls.first.name, 'book_cab');
      expect(calls.first.arguments, '{"to":"SFO"}');
      expect(calls.first.response, '{"eta":9}');
      expect(calls.first.clientSide, isTrue);
      expect(calls.first.thoughtSignature, 'sig');
      expect(calls[1].clientSide, isFalse);
      expect(calls[1].response, isNull);
    });

    test('malformed function_calls never crash', () {
      expect(
        AgentHistoryEvent.fromJson(<String, dynamic>{'function_calls': 'x'})
            .functionCalls,
        isNull,
      );
      expect(
        AgentHistoryEvent.fromJson(<String, dynamic>{}).functionCalls,
        isNull,
      );
      final event = AgentHistoryEvent.fromJson(<String, dynamic>{
        'function_calls': <dynamic>[
          'skip',
          3,
          null,
          <String, dynamic>{'name': 'partial'},
          <String, dynamic>{
            'id': true,
            'name': 1,
            'arguments': false,
            'response': 4,
            'client_side': 1,
            'thought_signature': 0,
          },
        ],
      });
      final calls = event.functionCalls!;
      expect(calls, hasLength(2));
      expect(calls[0].id, '');
      expect(calls[0].name, 'partial');
      expect(calls[0].arguments, '');
      expect(calls[1].id, '');
      expect(calls[1].name, '1');
      expect(calls[1].arguments, '');
      expect(calls[1].response, '4');
      expect(calls[1].clientSide, isFalse);
      expect(calls[1].thoughtSignature, '0');
    });
  });

  group('AgentProviderUpdate.fromJson', () {
    test('carries the frame type as its kind', () {
      for (final kind in <String>[
        'ListenUpdated',
        'ThinkUpdated',
        'SpeakUpdated',
        'PromptUpdated',
        'SettingsApplied',
      ]) {
        final event =
            AgentProviderUpdate.fromJson(<String, dynamic>{'type': kind});
        expect(event.kind, kind, reason: kind);
      }
    });

    test('defaults a missing type to empty; numbers are stringified', () {
      expect(AgentProviderUpdate.fromJson(<String, dynamic>{}).kind, '');
      expect(
        AgentProviderUpdate.fromJson(<String, dynamic>{'type': null}).kind,
        '',
      );
      // Numbers are coerced defensively (same policy as every string
      // field in this library).
      expect(
        AgentProviderUpdate.fromJson(<String, dynamic>{'type': 5}).kind,
        '5',
      );
      expect(
        AgentProviderUpdate.fromJson(<String, dynamic>{
          'type': <String>['x'],
        }).kind,
        '',
      );
    });
  });

  group('AgentCustomThinkPayload.fromJson', () {
    test('passes object content through unchanged', () {
      final content = <String, dynamic>{
        'choices': <dynamic>[
          <String, dynamic>{'text': 'hi'},
        ],
      };
      final event = AgentCustomThinkPayload.fromJson(<String, dynamic>{
        'type': '__customFromThinkProvider',
        'content': content,
      });
      expect(event.content, same(content));
    });

    test('passes list, string, number, and null content through', () {
      expect(
        AgentCustomThinkPayload.fromJson(<String, dynamic>{
          'content': <dynamic>[1, 'two'],
        }).content,
        <dynamic>[1, 'two'],
      );
      expect(
        AgentCustomThinkPayload.fromJson(<String, dynamic>{'content': 'raw'})
            .content,
        'raw',
      );
      expect(
        AgentCustomThinkPayload.fromJson(<String, dynamic>{'content': 12.5})
            .content,
        12.5,
      );
      expect(
        AgentCustomThinkPayload.fromJson(<String, dynamic>{'content': null})
            .content,
        isNull,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Client messages: exact wire shapes over a loopback socket
  // -------------------------------------------------------------------------

  group('client message wire shapes', () {
    test('handshake sends Settings right after Welcome, with Token auth',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      final connFuture = server.nextConnection();
      final agent = DeepgramVoiceAgent(
        config: harness.config,
        auth: harness.auth,
        http: harness.httpEngine,
      );
      addTearDown(agent.forceClose);

      final welcome = _Recorder<AgentWelcome>(agent.welcome);
      addTearDown(welcome.dispose);
      final applied = _Recorder<void>(agent.settingsApplied);
      addTearDown(applied.dispose);

      final startFuture = agent.start(_defaultSettings);
      final conn = await connFuture;

      // The upgrade request hits the agent endpoint with Token auth.
      expect(conn.request.uri.path, '/v1/agent/converse');
      expect(conn.request.uri.query, '');
      expect(
        conn.request.headers.value(HttpHeaders.authorizationHeader),
        'Token test-api-key',
      );
      // The shared HTTP engine is exposed for advanced use cases.
      expect(agent.http, same(harness.httpEngine));

      // Nothing is sent before the Welcome frame.
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
      expect(conn.frames, hasLength(1));
    });

    test('UpdateListen wraps the listen block under `listen`', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      agent.updateListen(const AgentListen(
        provider: AgentListenProvider.v2(
          model: 'flux-general-multi',
          languageHints: <String>['en', 'es'],
          eotThreshold: 0.8,
          eagerEotThreshold: 0.6,
          eotTimeoutMs: 3000,
          keyterms: <String>['Deepgram'],
        ),
      ));
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'UpdateListen',
        'listen': <String, dynamic>{
          'provider': <String, dynamic>{
            'type': 'deepgram',
            'version': 'v2',
            'model': 'flux-general-multi',
            'keyterms': <String>['Deepgram'],
            'language_hints': <String>['en', 'es'],
            'eot_threshold': 0.8,
            'eager_eot_threshold': 0.6,
            'eot_timeout_ms': 3000,
          },
        },
      });
    });

    test('UpdateThink wraps the think block under `think`', () async {
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

    test('UpdateSpeak wraps the speak block under `speak`', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      agent.updateSpeak(const AgentSpeak(
        provider: AgentSpeakProvider(
          model: 'aura-2-apollo-en',
          version: 'v1',
          speed: 1.2,
        ),
      ));
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'UpdateSpeak',
        'speak': <String, dynamic>{
          'provider': <String, dynamic>{
            'type': 'deepgram',
            'version': 'v1',
            'model': 'aura-2-apollo-en',
            'speed': 1.2,
          },
        },
      });
    });

    test('UpdatePrompt replaces the system prompt', () async {
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

    test('InjectUserMessage carries the content', () async {
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

    test('InjectAgentMessage carries every behavior value', () async {
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

    test('FunctionCallResponse echoes id, name, and content', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      agent.sendFunctionCallResponse(
        id: 'call-7',
        name: 'get_weather',
        content: '{"temp_f": 62}',
      );
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'FunctionCallResponse',
        'id': 'call-7',
        'name': 'get_weather',
        'content': '{"temp_f": 62}',
      });
    });

    test('ForceEndTurn is a single-key message', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      agent.forceEndTurn();
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': 'ForceEndTurn',
      });
    });

    test('__customToThinkProvider forwards arbitrary JSON content', () async {
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

      agent.sendCustomToThinkProvider(<String>['raw', 'provider', 'body']);
      expect(_decode(await conn.nextFrame()), <String, dynamic>{
        'type': '__customToThinkProvider',
        'content': <String>['raw', 'provider', 'body'],
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

    test('KeepAlive fires after 8 s idle with the exact documented frame',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      // The agent mandates one {"type":"KeepAlive"} every 8 s while idle.
      final frame = await conn.nextFrame(
        timeout: const Duration(seconds: 15),
      );
      expect(frame, isA<String>());
      expect(_decode(frame), <String, dynamic>{'type': 'KeepAlive'});
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  // -------------------------------------------------------------------------
  // Server event pump: dispatch by `type`
  // -------------------------------------------------------------------------

  group('server event dispatch', () {
    test('ConversationText events reach conversationText', () async {
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
        'languages_hinted': <String>['en'],
        'languages': <String>['en'],
      });
      final event = await events.next;
      expect(event.role, 'user');
      expect(event.content, 'Book me a table for two.');
      expect(event.languagesHinted, <String>['en']);
      expect(event.languages, <String>['en']);
      expect(event.raw['type'], 'ConversationText');
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
      expect(userStarted.values, hasLength(1));
      conn.sendJson(<String, dynamic>{'type': 'AgentAudioDone'});
      await audioDone.next;
      expect(audioDone.values, hasLength(1));
    });

    test('AgentThinking events carry the thought content', () async {
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
      final event = await events.next;
      expect(event.content, 'Considering Italian restaurants nearby.');
    });

    test('AgentStartedSpeaking carries the string latencies', () async {
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

    test('LatencyReport events expose every stage', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final events = _Recorder<AgentLatencyReport>(agent.latencyReports);
      addTearDown(events.dispose);

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
      final event = await events.next;
      expect(event.sttLatency, '0.31');
      expect(event.tttTokenLatency, '0.22');
      expect(event.tttTextLatency, '0.24');
      expect(event.tttToolLatency, '0.28');
      expect(event.tttThinkingLatency, '0.26');
      expect(event.ttsLatency, '0.18');
      expect(event.totalLatency, '0.73');
    });

    test('FunctionCallRequest events expose the requested functions', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final events =
          _Recorder<AgentFunctionCallRequest>(agent.functionCallRequests);
      addTearDown(events.dispose);

      conn.sendJson(<String, dynamic>{
        'type': 'FunctionCallRequest',
        'functions': <dynamic>[
          <String, dynamic>{
            'id': 'call-1',
            'name': 'get_weather',
            'arguments': '{"city":"SF"}',
            'client_side': true,
          },
        ],
      });
      final event = await events.next;
      expect(event.functions, hasLength(1));
      expect(event.functions.first.id, 'call-1');
      expect(event.functions.first.name, 'get_weather');
      expect(event.functions.first.arguments, '{"city":"SF"}');
      expect(event.functions.first.clientSide, isTrue);
    });

    test('FunctionCallCancelled events expose the cancelled ids', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final events =
          _Recorder<AgentFunctionCallCancelled>(agent.functionCallCancelled);
      addTearDown(events.dispose);

      conn.sendJson(<String, dynamic>{
        'type': 'FunctionCallCancelled',
        'functions': <dynamic>[
          <String, dynamic>{'id': 'call-1', 'name': 'get_weather'},
        ],
      });
      final event = await events.next;
      expect(event.functions.first.id, 'call-1');
      expect(event.functions.first.name, 'get_weather');
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

    test('unknown types are ignored without breaking the pump', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final logger = RecordingLogger();
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession(logger: logger);

      final conversation =
          _Recorder<AgentConversationText>(agent.conversationText);
      addTearDown(conversation.dispose);

      conn.sendJson(<String, dynamic>{'type': 'SpaceAliens', 'beam': 'up'});
      conn.sendJson(<String, dynamic>{'type': 42});
      await _quiet();

      expect(conversation.values, isEmpty);
      expect(agent.isConnected, isTrue);
      expect(
        logger.debugs,
        containsAllInOrder(<String>[
          'Ignoring unknown agent message type: SpaceAliens',
          'Ignoring unknown agent message type: ',
        ]),
      );

      // The pump is still alive: a known type keeps flowing.
      conn.sendJson(<String, dynamic>{
        'type': 'ConversationText',
        'role': 'assistant',
        'content': 'Still here.',
      });
      expect((await conversation.next).content, 'Still here.');
    });

    test('malformed JSON text frames surface as SchemaError warnings',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      final warnings = _Recorder<AgentWarningEvent>(agent.warnings);
      addTearDown(warnings.dispose);

      conn.sendText('{not valid json');
      final warning = await warnings.next;
      expect(warning.code, 'SchemaError');
      expect(warning.description, contains('Malformed JSON frame'));

      // Non-object JSON payloads are rejected the same way.
      conn.sendText('[1, 2, 3]');
      final second = await warnings.next;
      expect(second.code, 'SchemaError');
      expect(second.description, 'Expected a JSON object frame.');

      // The session survives.
      expect(agent.isConnected, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // Handshake + lifecycle
  // -------------------------------------------------------------------------

  group('handshake and lifecycle', () {
    test('start() times out when the server never sends Welcome', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      final connFuture = server.nextConnection();
      final agent = DeepgramVoiceAgent(
        config: harness.config,
        auth: harness.auth,
        http: harness.httpEngine,
      );
      addTearDown(agent.forceClose);

      await expectLater(
        agent.start(_defaultSettings,
            handshakeTimeout: const Duration(milliseconds: 250)),
        throwsA(isA<DeepgramTimeoutException>()),
      );
      // The connection was accepted; the server simply stayed silent.
      await connFuture;
    });

    test('start() times out when SettingsApplied never arrives', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      final connFuture = server.nextConnection();
      final agent = DeepgramVoiceAgent(
        config: harness.config,
        auth: harness.auth,
        http: harness.httpEngine,
      );
      addTearDown(agent.forceClose);

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
        throwsA(isA<DeepgramTimeoutException>()),
      );
    });

    test('an Error frame after Welcome fails the handshake', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      final connFuture = server.nextConnection();
      final agent = DeepgramVoiceAgent(
        config: harness.config,
        auth: harness.auth,
        http: harness.httpEngine,
      );
      addTearDown(agent.forceClose);

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
    });

    test('a second start() while active is refused', () async {
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

    test(
        'close() drains until the server hangs up, then releases every '
        'stream; idempotent', () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);
      final (conn, agent) = await harness.startSession();

      // `close()` drains the socket for up to 5 s waiting for the server to
      // end the stream (it sends no close message of its own). Hang up from
      // the server side shortly after the drain begins — like the real
      // Deepgram agent server does at session end — so the wait resolves.
      final closing = agent.close();
      unawaited(Future<void>.delayed(const Duration(milliseconds: 100))
          .then((_) => conn.socket.close(1000, 'session complete')));
      await closing;

      // Every stream controller is closed: late listeners see done.
      await expectLater(agent.welcome, emitsDone);
      await expectLater(agent.conversationText, emitsDone);
      await expectLater(agent.audio, emitsDone);
      await expectLater(conn.done, completes);

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

      await agent.forceClose();
    });

    test('an unexpected drop reconnects, re-Welcomes, and re-sends Settings',
        () async {
      final server = await _LoopbackAgentServer.start();
      addTearDown(server.shutdown);
      final harness = _Harness(server);

      DeepgramVoiceAgent? agentSlot;
      final userCallbackOrder = <String>[];
      final wsOptions = ResilientWebSocketOptions(
        // Long enough to observe the in-flight reconnect attempt
        // deterministically before the redial lands.
        minReconnectDelay: const Duration(milliseconds: 150),
        maxReconnectDelay: const Duration(milliseconds: 150),
        onReconnected: () {
          userCallbackOrder.add('user');
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
      expect(userCallbackOrder, <String>['user']);
      expect(welcomes.values, hasLength(2));
      expect(welcomes.values.last.requestId, 'req-reconnect');
      expect(agent.isConnected, isTrue);
    });
  });
}
