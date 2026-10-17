/// Typed models for the Deepgram Voice Agent server events.
///
/// Every event class carries the original JSON in a `raw` map (a constructor
/// parameter defaulting to `const {}`) and exposes a defensive `fromJson`
/// factory: missing or malformed fields fall back to empty values instead of
/// throwing, so a bad frame can never crash a stream.
///
/// Wire shapes follow the authoritative AsyncAPI schemas for the agent v1
/// channel. Latency figures arrive as JSON strings (e.g. `'0.4'`) and are
/// parsed as such, with numeric values coerced defensively.
library;

import 'agent_settings.dart';

/// Coerces a JSON value to [String] without throwing: strings pass through,
/// numbers are stringified, anything else becomes `null`.
String? _stringOrNull(dynamic value) {
  if (value is String) return value;
  if (value is num) return value.toString();
  return null;
}

/// Coerces a JSON value to `bool`, defaulting to `false` for non-bools.
bool _boolOrFalse(dynamic value) => value is bool ? value : false;

/// Coerces a JSON value to a [List] of strings, keeping only string entries;
/// returns `null` for anything that is not a list.
List<String>? _stringListOrNull(dynamic value) {
  if (value is! List) return null;
  final out = <String>[];
  for (final item in value) {
    if (item is String) out.add(item);
  }
  return out;
}

/// Parses a `function_calls` array into [AgentFunctionCallRecord]s;
/// returns `null` for anything that is not a list.
List<AgentFunctionCallRecord>? _parseFunctionCallRecords(dynamic value) {
  if (value is! List) return null;
  final out = <AgentFunctionCallRecord>[];
  for (final item in value) {
    if (item is Map<String, dynamic>) {
      out.add(AgentFunctionCallRecord(
        id: _stringOrNull(item['id']) ?? '',
        name: _stringOrNull(item['name']) ?? '',
        arguments: _stringOrNull(item['arguments']) ?? '',
        response: _stringOrNull(item['response']),
        clientSide: _boolOrFalse(item['client_side']),
        thoughtSignature: _stringOrNull(item['thought_signature']),
      ));
    }
  }
  return out;
}

/// The `Welcome` frame sent by the server right after the connection opens.
class AgentWelcome {
  /// Creates a welcome event.
  const AgentWelcome({required this.requestId, this.raw = const {}});

  /// Unique identifier for the request.
  final String requestId;

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses a `Welcome` frame defensively.
  factory AgentWelcome.fromJson(Map<String, dynamic> json) => AgentWelcome(
        requestId: _stringOrNull(json['request_id']) ?? '',
        raw: json,
      );
}

/// The `SettingsApplied` frame confirming the server accepted the Settings.
class AgentSettingsApplied {
  /// Creates the event.
  const AgentSettingsApplied({this.raw = const {}});

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses a `SettingsApplied` frame defensively.
  factory AgentSettingsApplied.fromJson(Map<String, dynamic> json) =>
      AgentSettingsApplied(raw: json);
}

/// A `ConversationText` frame: a transcribed or generated statement.
class AgentConversationText {
  /// Creates the event.
  const AgentConversationText({
    required this.role,
    required this.content,
    this.languagesHinted,
    this.languages,
    this.raw = const {},
  });

  /// Who spoke the statement: `'user'` or `'assistant'`.
  final String role;

  /// The actual statement that was spoken.
  final String content;

  /// The language hints active at the time of the turn (present on
  /// user-role turns with `flux-general-multi`).
  final List<String>? languagesHinted;

  /// Languages detected in the user's speech, sorted by word count.
  final List<String>? languages;

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses a `ConversationText` frame defensively.
  factory AgentConversationText.fromJson(Map<String, dynamic> json) =>
      AgentConversationText(
        role: _stringOrNull(json['role']) ?? '',
        content: _stringOrNull(json['content']) ?? '',
        languagesHinted: _stringListOrNull(json['languages_hinted']),
        languages: _stringListOrNull(json['languages']),
        raw: json,
      );
}

/// The `UserStartedSpeaking` frame — the user began talking (barge-in).
class AgentUserStartedSpeaking {
  /// Creates the event.
  const AgentUserStartedSpeaking({this.raw = const {}});

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses a `UserStartedSpeaking` frame defensively.
  factory AgentUserStartedSpeaking.fromJson(Map<String, dynamic> json) =>
      AgentUserStartedSpeaking(raw: json);
}

/// An `AgentThinking` frame — the agent's visible thought process.
class AgentAgentThinking {
  /// Creates the event.
  const AgentAgentThinking({required this.content, this.raw = const {}});

  /// The text of the agent's thought process.
  final String content;

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses an `AgentThinking` frame defensively.
  factory AgentAgentThinking.fromJson(Map<String, dynamic> json) =>
      AgentAgentThinking(
        content: _stringOrNull(json['content']) ?? '',
        raw: json,
      );
}

/// An `AgentStartedSpeaking` frame — the agent begins a spoken reply.
class AgentAgentStartedSpeaking {
  /// Creates the event.
  const AgentAgentStartedSpeaking({
    required this.totalLatency,
    required this.ttsLatency,
    required this.tttLatency,
    this.raw = const {},
  });

  /// Seconds from receiving the user's utterance to producing the reply.
  final String totalLatency;

  /// The portion of the total latency attributable to text-to-speech.
  final String ttsLatency;

  /// The portion of the total latency attributable to text-to-text.
  final String tttLatency;

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses an `AgentStartedSpeaking` frame defensively. The numbers arrive
  /// as strings per the wire spec and are coerced with `?? ''`.
  factory AgentAgentStartedSpeaking.fromJson(Map<String, dynamic> json) =>
      AgentAgentStartedSpeaking(
        totalLatency: _stringOrNull(json['total_latency']) ?? '',
        ttsLatency: _stringOrNull(json['tts_latency']) ?? '',
        tttLatency: _stringOrNull(json['ttt_latency']) ?? '',
        raw: json,
      );
}

/// An `AgentAudioDone` frame — the agent finished speaking.
class AgentAgentAudioDone {
  /// Creates the event.
  const AgentAgentAudioDone({this.raw = const {}});

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses an `AgentAudioDone` frame defensively.
  factory AgentAgentAudioDone.fromJson(Map<String, dynamic> json) =>
      AgentAgentAudioDone(raw: json);
}

/// A `LatencyReport` frame with per-stage timings, in seconds.
class AgentLatencyReport {
  /// Creates the event.
  const AgentLatencyReport({
    this.sttLatency,
    this.tttTokenLatency,
    this.tttTextLatency,
    this.tttToolLatency,
    this.tttThinkingLatency,
    this.ttsLatency,
    this.totalLatency,
    this.raw = const {},
  });

  /// Speech-to-text: time from audio received to transcript produced.
  final String? sttLatency;

  /// Time to first token of any type (text, tool call, or thinking).
  final String? tttTokenLatency;

  /// Time to first text token from the LLM.
  final String? tttTextLatency;

  /// Time to first tool-call token from the LLM.
  final String? tttToolLatency;

  /// Time to first thinking token from the LLM.
  final String? tttThinkingLatency;

  /// Text-to-speech: time from first text token to first audio byte.
  final String? ttsLatency;

  /// End-to-end: time from user utterance end to first audio byte.
  final String? totalLatency;

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses a `LatencyReport` frame defensively. Keys: `stt_latency`,
  /// `ttt_token_latency`, `ttt_text_latency`, `ttt_tool_latency`,
  /// `ttt_thinking_latency`, `tts_latency`, `total_latency`.
  factory AgentLatencyReport.fromJson(Map<String, dynamic> json) =>
      AgentLatencyReport(
        sttLatency: _stringOrNull(json['stt_latency']),
        tttTokenLatency: _stringOrNull(json['ttt_token_latency']),
        tttTextLatency: _stringOrNull(json['ttt_text_latency']),
        tttToolLatency: _stringOrNull(json['ttt_tool_latency']),
        tttThinkingLatency: _stringOrNull(json['ttt_thinking_latency']),
        ttsLatency: _stringOrNull(json['tts_latency']),
        totalLatency: _stringOrNull(json['total_latency']),
        raw: json,
      );
}

/// A `FunctionCallRequest` frame — the server asks your application (or a
/// client-side function) to execute and reply.
class AgentFunctionCallRequest {
  /// Creates the event.
  const AgentFunctionCallRequest({
    required this.functions,
    this.raw = const {},
  });

  /// The functions to be called.
  final List<AgentRequestedFunction> functions;

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses a `FunctionCallRequest` frame defensively; a malformed
  /// `functions` array yields an empty list.
  factory AgentFunctionCallRequest.fromJson(Map<String, dynamic> json) {
    var parsed = const <AgentRequestedFunction>[];
    final list = json['functions'];
    if (list is List) {
      final out = <AgentRequestedFunction>[];
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          out.add(AgentRequestedFunction.fromJson(item));
        }
      }
      parsed = out;
    }
    return AgentFunctionCallRequest(functions: parsed, raw: json);
  }
}

/// One requested function inside a [AgentFunctionCallRequest].
class AgentRequestedFunction {
  /// Creates the entry.
  const AgentRequestedFunction({
    required this.id,
    required this.name,
    required this.arguments,
    required this.clientSide,
    this.thoughtSignature,
    this.raw = const {},
  });

  /// Unique identifier for the function call.
  final String id;

  /// The name of the function to call.
  final String name;

  /// JSON string containing the function arguments.
  final String arguments;

  /// Whether the function should be executed client-side.
  final bool clientSide;

  /// Additional function call identifier required by some Gemini models.
  final String? thoughtSignature;

  /// The original JSON of this entry.
  final Map<String, dynamic> raw;

  /// Parses a requested-function entry defensively.
  factory AgentRequestedFunction.fromJson(Map<String, dynamic> json) =>
      AgentRequestedFunction(
        id: _stringOrNull(json['id']) ?? '',
        name: _stringOrNull(json['name']) ?? '',
        arguments: _stringOrNull(json['arguments']) ?? '',
        clientSide: _boolOrFalse(json['client_side']),
        thoughtSignature: _stringOrNull(json['thought_signature']),
        raw: json,
      );
}

/// A `FunctionCallCancelled` frame — pending calls are no longer valid.
class AgentFunctionCallCancelled {
  /// Creates the event.
  const AgentFunctionCallCancelled({
    required this.functions,
    this.raw = const {},
  });

  /// The function calls that are no longer valid.
  final List<AgentCancelledFunction> functions;

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses a `FunctionCallCancelled` frame defensively; a malformed
  /// `functions` array yields an empty list.
  factory AgentFunctionCallCancelled.fromJson(Map<String, dynamic> json) {
    var parsed = const <AgentCancelledFunction>[];
    final list = json['functions'];
    if (list is List) {
      final out = <AgentCancelledFunction>[];
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          out.add(AgentCancelledFunction.fromJson(item));
        }
      }
      parsed = out;
    }
    return AgentFunctionCallCancelled(functions: parsed, raw: json);
  }
}

/// One cancelled function inside a [AgentFunctionCallCancelled].
class AgentCancelledFunction {
  /// Creates the entry.
  const AgentCancelledFunction({
    required this.id,
    required this.name,
    this.raw = const {},
  });

  /// The id from the `FunctionCallRequest` that is now cancelled; send no
  /// `FunctionCallResponse` for this id.
  final String id;

  /// The name of the cancelled function.
  final String name;

  /// The original JSON of this entry.
  final Map<String, dynamic> raw;

  /// Parses a cancelled-function entry defensively.
  factory AgentCancelledFunction.fromJson(Map<String, dynamic> json) =>
      AgentCancelledFunction(
        id: _stringOrNull(json['id']) ?? '',
        name: _stringOrNull(json['name']) ?? '',
        raw: json,
      );
}

/// An `InjectionRefused` frame — an injected message was rejected.
class AgentInjectionRefused {
  /// Creates the event.
  const AgentInjectionRefused({required this.message, this.raw = const {}});

  /// Details about why the injection was refused.
  final String message;

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses an `InjectionRefused` frame defensively.
  factory AgentInjectionRefused.fromJson(Map<String, dynamic> json) =>
      AgentInjectionRefused(
        message: _stringOrNull(json['message']) ?? '',
        raw: json,
      );
}

/// An `Error` frame — the server reports a failure.
class AgentErrorEvent {
  /// Creates the event.
  const AgentErrorEvent({
    required this.description,
    required this.code,
    this.raw = const {},
  });

  /// A description of what went wrong.
  final String description;

  /// Error code identifying the type of error.
  final String code;

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses an `Error` frame defensively.
  factory AgentErrorEvent.fromJson(Map<String, dynamic> json) =>
      AgentErrorEvent(
        description: _stringOrNull(json['description']) ?? '',
        code: _stringOrNull(json['code']) ?? '',
        raw: json,
      );
}

/// A `Warning` frame — the server reports a non-fatal issue.
class AgentWarningEvent {
  /// Creates the event.
  const AgentWarningEvent({
    required this.description,
    required this.code,
    this.raw = const {},
  });

  /// Description of the warning.
  final String description;

  /// Warning code identifying the type of warning.
  final String code;

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses a `Warning` frame defensively.
  factory AgentWarningEvent.fromJson(Map<String, dynamic> json) =>
      AgentWarningEvent(
        description: _stringOrNull(json['description']) ?? '',
        code: _stringOrNull(json['code']) ?? '',
        raw: json,
      );
}

/// A `History` frame echoing a conversation entry (a role/content message or
/// a function-call record list).
class AgentHistoryEvent {
  /// Creates the event.
  const AgentHistoryEvent({
    this.role,
    this.content,
    this.functionCalls,
    this.raw = const {},
  });

  /// Who spoke the statement: `'user'` or `'assistant'`; `null` for
  /// function-call entries.
  final String? role;

  /// The actual statement that was spoken; `null` for function-call entries.
  final String? content;

  /// The function calls recorded in this entry; `null` for text entries.
  final List<AgentFunctionCallRecord>? functionCalls;

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses a `History` frame defensively.
  factory AgentHistoryEvent.fromJson(Map<String, dynamic> json) =>
      AgentHistoryEvent(
        role: _stringOrNull(json['role']),
        content: _stringOrNull(json['content']),
        functionCalls: _parseFunctionCallRecords(json['function_calls']),
        raw: json,
      );
}

/// A provider/settings update confirmation:
/// `ListenUpdated`, `ThinkUpdated`, `SpeakUpdated`, `PromptUpdated`, or
/// `SettingsApplied`.
class AgentProviderUpdate {
  /// Creates the update from its [kind].
  const AgentProviderUpdate({required this.kind, this.raw = const {}});

  /// The update type string, e.g. `'ListenUpdated'`.
  final String kind;

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses the `type` field defensively.
  factory AgentProviderUpdate.fromJson(Map<String, dynamic> json) =>
      AgentProviderUpdate(kind: _stringOrNull(json['type']) ?? '', raw: json);
}

/// A `__customFromThinkProvider` frame — the think provider's response body
/// passed through unchanged.
class AgentCustomThinkPayload {
  /// Creates the payload.
  const AgentCustomThinkPayload({required this.content, this.raw = const {}});

  /// The think provider's response body. If the provider's response is not
  /// valid JSON, it arrives as a JSON string.
  final dynamic content;

  /// The original JSON of this event.
  final Map<String, dynamic> raw;

  /// Parses a `__customFromThinkProvider` frame defensively.
  factory AgentCustomThinkPayload.fromJson(Map<String, dynamic> json) =>
      AgentCustomThinkPayload(content: json['content'], raw: json);
}
