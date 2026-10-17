/// A Voice Agent client for the Deepgram Agent API
/// (`wss://agent.deepgram.com/v1/agent/converse`).
///
/// The session is driven by [DeepgramVoiceAgent.start], which performs the
/// required handshake: connect, wait for the server's `Welcome`, send the
/// [VoiceAgentSettings], then wait for `SettingsApplied`. After that, stream
/// audio with [sendAudio] and consume the typed event streams.
///
/// KeepAlive: the underlying [ResilientWebSocket] is *always* configured with
/// the values the Agent API requires — one `{"type":"KeepAlive"}` every 8
/// seconds, sent only while idle. Any `keepAliveInterval`,
/// `keepAliveMessage`, or `sendKeepAliveOnlyWhenIdle` supplied via
/// `wsOptions` is therefore overridden; every other field of `wsOptions`
/// (`autoReconnect`, `maxReconnectAttempts`, `minReconnectDelay`,
/// `maxReconnectDelay`, `connectTimeout`, `corroboratedFailureThreshold`,
/// `shouldReconnect`, `onReconnecting`) is forwarded as-is.
///
/// On automatic reconnect, `onReconnected` is composed: the user callback
/// runs first, then the last [VoiceAgentSettings] is re-sent — agent
/// sessions require the Settings message again on a fresh connection.
library;

import 'dart:async';
import 'dart:convert';

import '../core/deepgram_auth.dart';
import '../core/deepgram_config.dart';
import '../core/deepgram_exception.dart';
import '../core/deepgram_logger.dart';
import '../core/http/http_engine.dart';
import '../core/ws/resilient_websocket.dart';

import 'agent_messages.dart';
import 'agent_settings.dart';

/// A Voice Agent session over a resilient WebSocket.
class DeepgramVoiceAgent {
  /// Creates a Voice Agent client. Call [start] to establish a session.
  ///
  /// The [config] decides the endpoint (`config.agentWsUri('/v1/agent/converse')`),
  /// [auth] supplies the credentials, and [http] is the shared engine from
  /// the `DeepgramClient` facade. See the library docs for the KeepAlive and
  /// reconnection policy applied to [wsOptions].
  DeepgramVoiceAgent({
    required DeepgramConfig config,
    required DeepgramAuth auth,
    required HttpEngine http,
    ResilientWebSocketOptions? wsOptions,
    DeepgramLogger? logger,
  })  : _config = config,
        _auth = auth,
        _http = http,
        _userWsOptions = wsOptions,
        _logger = logger ?? DeepgramLogger();

  final DeepgramConfig _config;
  final DeepgramAuth _auth;
  final HttpEngine _http;
  final ResilientWebSocketOptions? _userWsOptions;
  final DeepgramLogger _logger;

  /// Lazily constructed socket. The options are composed so that KeepAlive
  /// always matches the Agent API requirements (8 s, idle-only) and
  /// `onReconnected` re-sends the Settings on a fresh connection.
  late final ResilientWebSocket _ws = ResilientWebSocket(
    uri: _config.agentWsUri('/v1/agent/converse'),
    config: _config,
    auth: _auth,
    options: _effectiveWsOptions(),
    logger: _logger,
  );

  /// The last Settings sent, kept for the reconnect re-send.
  VoiceAgentSettings? _settings;

  /// Whether the initial handshake completed (guard for `_resendSettings`).
  bool _handshakeCompleted = false;

  /// Whether [close] or [forceClose] has been called.
  bool _closed = false;

  Completer<AgentWelcome>? _welcomeCompleter;
  Completer<void>? _settingsAppliedCompleter;

  StreamSubscription<WsMessage>? _pumpSub;

  final StreamController<AgentWelcome> _welcomeController =
      StreamController<AgentWelcome>.broadcast();
  final StreamController<void> _settingsAppliedController =
      StreamController<void>.broadcast();
  final StreamController<AgentConversationText> _conversationTextController =
      StreamController<AgentConversationText>.broadcast();
  final StreamController<void> _userStartedSpeakingController =
      StreamController<void>.broadcast();
  final StreamController<AgentAgentThinking> _agentThinkingController =
      StreamController<AgentAgentThinking>.broadcast();
  final StreamController<AgentAgentStartedSpeaking>
      _agentStartedSpeakingController =
      StreamController<AgentAgentStartedSpeaking>.broadcast();
  final StreamController<void> _agentAudioDoneController =
      StreamController<void>.broadcast();
  final StreamController<AgentLatencyReport> _latencyReportsController =
      StreamController<AgentLatencyReport>.broadcast();
  final StreamController<AgentFunctionCallRequest>
      _functionCallRequestsController =
      StreamController<AgentFunctionCallRequest>.broadcast();
  final StreamController<AgentFunctionCallCancelled>
      _functionCallCancelledController =
      StreamController<AgentFunctionCallCancelled>.broadcast();
  final StreamController<AgentInjectionRefused> _injectionRefusedController =
      StreamController<AgentInjectionRefused>.broadcast();
  final StreamController<AgentErrorEvent> _errorsController =
      StreamController<AgentErrorEvent>.broadcast();
  final StreamController<AgentWarningEvent> _warningsController =
      StreamController<AgentWarningEvent>.broadcast();
  final StreamController<AgentHistoryEvent> _historyController =
      StreamController<AgentHistoryEvent>.broadcast();
  final StreamController<String> _providerUpdatesController =
      StreamController<String>.broadcast();
  final StreamController<AgentCustomThinkPayload>
      _customThinkProviderMessagesController =
      StreamController<AgentCustomThinkPayload>.broadcast();
  final StreamController<List<int>> _audioController =
      StreamController<List<int>>.broadcast();

  // ---------------------------------------------------------------------
  // Typed event streams
  // ---------------------------------------------------------------------

  /// `Welcome` frames (the initial one and any after a reconnect).
  Stream<AgentWelcome> get welcome => _welcomeController.stream;

  /// `SettingsApplied` confirmations.
  Stream<void> get settingsApplied => _settingsAppliedController.stream;

  /// `ConversationText` frames — transcribed user speech and agent replies.
  Stream<AgentConversationText> get conversationText =>
      _conversationTextController.stream;

  /// `UserStartedSpeaking` frames — stop audio playback immediately
  /// (barge-in).
  Stream<void> get userStartedSpeaking => _userStartedSpeakingController.stream;

  /// `AgentThinking` frames.
  Stream<AgentAgentThinking> get agentThinking =>
      _agentThinkingController.stream;

  /// `AgentStartedSpeaking` frames carrying the per-stage latencies.
  Stream<AgentAgentStartedSpeaking> get agentStartedSpeaking =>
      _agentStartedSpeakingController.stream;

  /// `AgentAudioDone` frames — the agent finished speaking.
  Stream<void> get agentAudioDone => _agentAudioDoneController.stream;

  /// `LatencyReport` frames.
  Stream<AgentLatencyReport> get latencyReports =>
      _latencyReportsController.stream;

  /// `FunctionCallRequest` frames — execute the client-side functions and
  /// reply with [sendFunctionCallResponse].
  Stream<AgentFunctionCallRequest> get functionCallRequests =>
      _functionCallRequestsController.stream;

  /// `FunctionCallCancelled` frames — drop the pending calls; send no
  /// response for these ids.
  Stream<AgentFunctionCallCancelled> get functionCallCancelled =>
      _functionCallCancelledController.stream;

  /// `InjectionRefused` frames.
  Stream<AgentInjectionRefused> get injectionRefused =>
      _injectionRefusedController.stream;

  /// `Error` frames.
  Stream<AgentErrorEvent> get errors => _errorsController.stream;

  /// `Warning` frames (including malformed frames reported as `SchemaError`).
  Stream<AgentWarningEvent> get warnings => _warningsController.stream;

  /// `History` frames echoed by the server.
  Stream<AgentHistoryEvent> get history => _historyController.stream;

  /// Provider/settings update type strings: `ListenUpdated`,
  /// `ThinkUpdated`, `SpeakUpdated`, `PromptUpdated`, `SettingsApplied`.
  Stream<String> get providerUpdates => _providerUpdatesController.stream;

  /// `__customFromThinkProvider` frames, passed through unchanged.
  Stream<AgentCustomThinkPayload> get customThinkProviderMessages =>
      _customThinkProviderMessagesController.stream;

  /// The agent's audio replies (binary frames).
  Stream<List<int>> get audio => _audioController.stream;

  /// The underlying connection state changes.
  Stream<WsConnectionState> get connectionStates => _ws.states;

  /// Whether the socket is currently open.
  bool get isConnected => _ws.isConnected;

  /// 1-based count of reconnection attempts in the current episode.
  int get reconnectAttempts => _ws.reconnectAttempts;

  /// The shared HTTP engine (exposed for advanced use cases).
  HttpEngine get http => _http;

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  /// Connects to `wss://agent.deepgram.com/v1/agent/converse`, waits for the
  /// server's `Welcome`, sends [settings], and waits for `SettingsApplied`.
  ///
  /// Throws [DeepgramTimeoutException] when the connection, `Welcome`, or
  /// `SettingsApplied` do not arrive within [handshakeTimeout]; throws
  /// [DeepgramWebSocketException] when the server reports an `Error` during
  /// the handshake; throws [DeepgramStateException] when a session is already
  /// active or the client was closed.
  Future<void> start(
    VoiceAgentSettings settings, {
    Duration handshakeTimeout = const Duration(seconds: 15),
  }) async {
    if (_closed) {
      throw const DeepgramStateException('This voice agent has been closed.');
    }
    final WsConnectionState current = _ws.state;
    if (current == WsConnectionState.open ||
        current == WsConnectionState.connecting ||
        current == WsConnectionState.reconnecting) {
      throw const DeepgramStateException(
          'A voice agent session is already active; close it first.');
    }

    _settings = settings;
    _handshakeCompleted = false;
    _ensurePump();

    final welcomeCompleter = Completer<AgentWelcome>();
    final appliedCompleter = Completer<void>();
    _welcomeCompleter = welcomeCompleter;
    _settingsAppliedCompleter = appliedCompleter;

    _logger
        .debug('Connecting to ${_config.agentWsUri('/v1/agent/converse')}...');

    // Subscribe to the states BEFORE connecting so the `open` event cannot
    // be missed; bail out on `failed`.
    final stateCompleter = Completer<WsConnectionState>();
    final stateSub = _ws.states.listen((state) {
      if (state == WsConnectionState.open ||
          state == WsConnectionState.failed) {
        if (!stateCompleter.isCompleted) stateCompleter.complete(state);
      }
    });
    try {
      unawaited(_ws.connect());
      final WsConnectionState state;
      try {
        state = await stateCompleter.future.timeout(handshakeTimeout);
      } on TimeoutException {
        throw const DeepgramTimeoutException(
            'Timed out waiting for the voice agent connection to open.');
      }
      if (state != WsConnectionState.open) {
        throw const DeepgramWebSocketException(
            'Could not open the voice agent connection.');
      }
    } finally {
      unawaited(stateSub.cancel());
    }

    // Await the Welcome frame.
    try {
      await welcomeCompleter.future.timeout(handshakeTimeout);
    } on TimeoutException {
      throw const DeepgramTimeoutException(
          'Timed out waiting for the Welcome message.');
    }
    _logger.debug('Welcome received; sending Settings.');

    _ws.send(jsonEncode(settings.toJson()));

    // Await the SettingsApplied confirmation.
    try {
      await appliedCompleter.future.timeout(handshakeTimeout);
    } on TimeoutException {
      throw const DeepgramTimeoutException(
          'Timed out waiting for the SettingsApplied confirmation.');
    }

    _handshakeCompleted = true;
    _welcomeCompleter = null;
    _settingsAppliedCompleter = null;
    _logger.info('Voice agent session established (Settings applied).');
  }

  /// Gracefully closes the session: drains the socket (up to 5 s), then
  /// releases every stream. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _ws.close();
    } catch (error) {
      _logger.warn('Error while closing the socket: $error');
    }
    await _release();
  }

  /// Immediately closes the session without draining, then releases every
  /// stream. Idempotent.
  Future<void> forceClose() async {
    if (_closed) return;
    _closed = true;
    try {
      await _ws.forceClose();
    } catch (error) {
      _logger.warn('Error while force-closing the socket: $error');
    }
    await _release();
  }

  // ---------------------------------------------------------------------
  // Client messages
  // ---------------------------------------------------------------------

  /// Streams a binary Media frame to the agent. Only valid after [start]
  /// completed (the server ignores media before `SettingsApplied`).
  void sendAudio(List<int> bytes) => _ws.sendBytes(bytes);

  /// Updates the listen (STT) provider mid-session. The model and language
  /// can change, as can keyterms and the Flux end-of-turn thresholds.
  void updateListen(AgentListen listen) => _sendJson(<String, dynamic>{
        'type': 'UpdateListen',
        'listen': listen.toJson(),
      });

  /// Updates the think (LLM) provider mid-session.
  void updateThink(AgentThink think) => _sendJson(<String, dynamic>{
        'type': 'UpdateThink',
        'think': think.toJson(),
      });

  /// Updates the speak (TTS) provider mid-session.
  void updateSpeak(AgentSpeak speak) => _sendJson(<String, dynamic>{
        'type': 'UpdateSpeak',
        'speak': speak.toJson(),
      });

  /// Replaces the system prompt for the rest of the session.
  void updatePrompt(String prompt) => _sendJson(<String, dynamic>{
        'type': 'UpdatePrompt',
        'prompt': prompt,
      });

  /// Adds a synthetic user turn the agent reacts to.
  void injectUserMessage(String content) => _sendJson(<String, dynamic>{
        'type': 'InjectUserMessage',
        'content': content,
      });

  /// Makes the agent speak [message]. The [behavior] controls how the
  /// injection interacts with any in-progress turn; allowed values are
  /// `'default'` (speak only if nobody is mid-turn), `'queue'` (append after
  /// queued text), and `'interrupt'` (speak immediately, interrupting). The
  /// value is passed through as-is.
  void injectAgentMessage(String message, {String behavior = 'default'}) =>
      _sendJson(<String, dynamic>{
        'type': 'InjectAgentMessage',
        'message': message,
        'behavior': behavior,
      });

  /// Replies to a [AgentFunctionCallRequest]. [id] must match the requested
  /// function's id; [content] is the result handed back to the agent.
  void sendFunctionCallResponse({
    required String id,
    required String name,
    required String content,
  }) =>
      _sendJson(<String, dynamic>{
        'type': 'FunctionCallResponse',
        'id': id,
        'name': name,
        'content': content,
      });

  /// Forces the end of the current user turn (e.g. when end-of-turn
  /// detection is suppressed with `eot_threshold: 1.0`).
  void forceEndTurn() => _sendJson(<String, dynamic>{
        'type': 'ForceEndTurn',
      });

  /// Sends an arbitrary JSON value to the think provider, unvalidated. Use
  /// with [customThinkProviderMessages] to echo provider responses.
  void sendCustomToThinkProvider(Object content) => _sendJson(<String, dynamic>{
        'type': '__customToThinkProvider',
        'content': content,
      });

  // ---------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------

  /// Composes the socket options: agent-mandated KeepAlive (8 s, idle-only,
  /// `{"type":"KeepAlive"}`) plus every user-supplied reconnect knob.
  ResilientWebSocketOptions _effectiveWsOptions() {
    final base = _userWsOptions ?? const ResilientWebSocketOptions();
    return ResilientWebSocketOptions(
      autoReconnect: base.autoReconnect,
      maxReconnectAttempts: base.maxReconnectAttempts,
      keepAliveInterval: const Duration(seconds: 8),
      keepAliveMessage: '{"type":"KeepAlive"}',
      sendKeepAliveOnlyWhenIdle: true,
      minReconnectDelay: base.minReconnectDelay,
      maxReconnectDelay: base.maxReconnectDelay,
      connectTimeout: base.connectTimeout,
      corroboratedFailureThreshold: base.corroboratedFailureThreshold,
      shouldReconnect: base.shouldReconnect,
      onReconnecting: base.onReconnecting,
      onReconnected: () {
        base.onReconnected?.call();
        _resendSettings();
      },
    );
  }

  /// Re-sends the last Settings after a reconnect. Guarded so it only runs
  /// once the initial [start] completed.
  void _resendSettings() {
    if (_closed || !_handshakeCompleted) return;
    final settings = _settings;
    if (settings == null) return;
    _logger
        .info('Reconnected: re-sending Settings for the fresh agent session.');
    _ws.send(jsonEncode(settings.toJson()));
  }

  /// Subscribes the message pump exactly once, before any connect.
  void _ensurePump() {
    if (_pumpSub != null) return;
    _pumpSub = _ws.messages.listen(
      _handleFrame,
      onError: (Object error) {
        _logger.warn('Message stream error: $error');
      },
    );
  }

  /// Encodes and sends a JSON client message.
  void _sendJson(Map<String, dynamic> message) => _ws.send(jsonEncode(message));

  /// Routes a single frame: binary payloads feed [audio]; text payloads are
  /// parsed and dispatched by `type`. Malformed frames produce a
  /// `SchemaError` warning instead of an exception.
  void _handleFrame(WsMessage message) {
    try {
      if (message.isBinary) {
        final bytes = message.bytes;
        if (bytes != null && bytes.isNotEmpty) {
          if (!_audioController.isClosed) _audioController.add(bytes);
        }
        return;
      }
      final text = message.text;
      if (text == null) return;
      final dynamic decoded;
      try {
        decoded = jsonDecode(text);
      } catch (error) {
        _emitSchemaWarning('Malformed JSON frame: $error');
        return;
      }
      if (decoded is! Map<String, dynamic>) {
        _emitSchemaWarning('Expected a JSON object frame.');
        return;
      }
      _dispatch(decoded);
    } catch (error) {
      _emitSchemaWarning('Unexpected error while processing a frame: $error');
    }
  }

  /// Dispatches a parsed server event by its `type`.
  void _dispatch(Map<String, dynamic> json) {
    final typeName = json['type'] is String ? json['type'] as String : '';
    switch (typeName) {
      case 'Welcome':
        _onWelcome(json);
        break;
      case 'SettingsApplied':
        _onSettingsApplied(json);
        break;
      case 'ListenUpdated':
      case 'ThinkUpdated':
      case 'SpeakUpdated':
      case 'PromptUpdated':
        _onProviderUpdate(json);
        break;
      case 'InjectionRefused':
        _onInjectionRefused(json);
        break;
      case 'ConversationText':
        _onConversationText(json);
        break;
      case 'UserStartedSpeaking':
        if (!_userStartedSpeakingController.isClosed) {
          _userStartedSpeakingController.add(null);
        }
        break;
      case 'AgentThinking':
        _onAgentThinking(json);
        break;
      case 'LatencyReport':
        _onLatencyReport(json);
        break;
      case 'FunctionCallRequest':
        _onFunctionCallRequest(json);
        break;
      case 'FunctionCallCancelled':
        _onFunctionCallCancelled(json);
        break;
      case 'AgentStartedSpeaking':
        _onAgentStartedSpeaking(json);
        break;
      case 'AgentAudioDone':
        if (!_agentAudioDoneController.isClosed) {
          _agentAudioDoneController.add(null);
        }
        break;
      case '__customFromThinkProvider':
        _onCustomFromThinkProvider(json);
        break;
      case 'Error':
        _onErrorEvent(json);
        break;
      case 'Warning':
        _onWarningEvent(json);
        break;
      case 'History':
        _onHistory(json);
        break;
      default:
        _logger.debug('Ignoring unknown agent message type: $typeName');
    }
  }

  void _onWelcome(Map<String, dynamic> json) {
    final event = AgentWelcome.fromJson(json);
    if (!_welcomeController.isClosed) _welcomeController.add(event);
    final completer = _welcomeCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(event);
    }
  }

  void _onSettingsApplied(Map<String, dynamic> json) {
    if (!_settingsAppliedController.isClosed) {
      _settingsAppliedController.add(null);
    }
    if (!_providerUpdatesController.isClosed) {
      _providerUpdatesController.add('SettingsApplied');
    }
    final completer = _settingsAppliedCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _onProviderUpdate(Map<String, dynamic> json) {
    final update = AgentProviderUpdate.fromJson(json);
    if (!_providerUpdatesController.isClosed) {
      _providerUpdatesController.add(update.kind);
    }
    _logger.debug('Provider update: ${update.kind}');
  }

  void _onInjectionRefused(Map<String, dynamic> json) {
    final event = AgentInjectionRefused.fromJson(json);
    if (!_injectionRefusedController.isClosed) {
      _injectionRefusedController.add(event);
    }
  }

  void _onConversationText(Map<String, dynamic> json) {
    final event = AgentConversationText.fromJson(json);
    if (!_conversationTextController.isClosed) {
      _conversationTextController.add(event);
    }
  }

  void _onAgentThinking(Map<String, dynamic> json) {
    final event = AgentAgentThinking.fromJson(json);
    if (!_agentThinkingController.isClosed) {
      _agentThinkingController.add(event);
    }
  }

  void _onLatencyReport(Map<String, dynamic> json) {
    final event = AgentLatencyReport.fromJson(json);
    if (!_latencyReportsController.isClosed) {
      _latencyReportsController.add(event);
    }
  }

  void _onFunctionCallRequest(Map<String, dynamic> json) {
    final event = AgentFunctionCallRequest.fromJson(json);
    if (!_functionCallRequestsController.isClosed) {
      _functionCallRequestsController.add(event);
    }
  }

  void _onFunctionCallCancelled(Map<String, dynamic> json) {
    final event = AgentFunctionCallCancelled.fromJson(json);
    if (!_functionCallCancelledController.isClosed) {
      _functionCallCancelledController.add(event);
    }
  }

  void _onAgentStartedSpeaking(Map<String, dynamic> json) {
    final event = AgentAgentStartedSpeaking.fromJson(json);
    if (!_agentStartedSpeakingController.isClosed) {
      _agentStartedSpeakingController.add(event);
    }
  }

  void _onCustomFromThinkProvider(Map<String, dynamic> json) {
    final event = AgentCustomThinkPayload.fromJson(json);
    if (!_customThinkProviderMessagesController.isClosed) {
      _customThinkProviderMessagesController.add(event);
    }
  }

  void _onErrorEvent(Map<String, dynamic> json) {
    final event = AgentErrorEvent.fromJson(json);
    if (!_errorsController.isClosed) _errorsController.add(event);
    _logger.error('Agent error ${event.code}: ${event.description}');
    final exception =
        DeepgramWebSocketException(event.description, code: event.code);
    // Fail an in-flight handshake, if any. Only the completer whose stage
    // `start()` is currently awaiting is completed with the error; the
    // other (if any) is marked ignored so it can never leak an unhandled
    // async error into the host app.
    final welcome = _welcomeCompleter;
    if (welcome != null && !welcome.isCompleted) {
      _welcomeCompleter = null;
      _settingsAppliedCompleter?.future.ignore();
      welcome.completeError(exception);
    } else {
      final applied = _settingsAppliedCompleter;
      if (applied != null && !applied.isCompleted) {
        applied.future.ignore();
        applied.completeError(exception);
      }
    }
    _welcomeCompleter = null;
    _settingsAppliedCompleter = null;
  }

  void _onWarningEvent(Map<String, dynamic> json) {
    final event = AgentWarningEvent.fromJson(json);
    if (!_warningsController.isClosed) _warningsController.add(event);
    _logger.warn('Agent warning ${event.code}: ${event.description}');
  }

  void _onHistory(Map<String, dynamic> json) {
    final event = AgentHistoryEvent.fromJson(json);
    if (!_historyController.isClosed) _historyController.add(event);
  }

  /// Emits a `SchemaError` warning for malformed frames.
  void _emitSchemaWarning(String description) {
    _logger.warn(description);
    if (!_warningsController.isClosed) {
      _warningsController.add(
          AgentWarningEvent(description: description, code: 'SchemaError'));
    }
  }

  /// Cancels the pump and closes every stream controller. Idempotent.
  Future<void> _release() async {
    try {
      await _pumpSub?.cancel();
    } catch (_) {}
    _pumpSub = null;
    await _closeController(_welcomeController);
    await _closeController(_settingsAppliedController);
    await _closeController(_conversationTextController);
    await _closeController(_userStartedSpeakingController);
    await _closeController(_agentThinkingController);
    await _closeController(_agentStartedSpeakingController);
    await _closeController(_agentAudioDoneController);
    await _closeController(_latencyReportsController);
    await _closeController(_functionCallRequestsController);
    await _closeController(_functionCallCancelledController);
    await _closeController(_injectionRefusedController);
    await _closeController(_errorsController);
    await _closeController(_warningsController);
    await _closeController(_historyController);
    await _closeController(_providerUpdatesController);
    await _closeController(_customThinkProviderMessagesController);
    await _closeController(_audioController);
    _welcomeCompleter = null;
    _settingsAppliedCompleter = null;
    _logger.debug('Voice agent streams released.');
  }

  /// Closes [controller] if it is not already closed; never throws.
  Future<void> _closeController(StreamController<dynamic> controller) async {
    if (!controller.isClosed) {
      try {
        await controller.close();
      } catch (_) {}
    }
  }
}
