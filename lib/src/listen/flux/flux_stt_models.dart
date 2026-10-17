/// Typed server messages for the `/v2/listen` Flux transcription WebSocket.
///
/// Every class defensively parses its JSON frame: missing or malformed fields
/// fall back to empty defaults instead of throwing, and values the spec
/// serializes as strings (floats) are parsed number-or-string.
library;

/// A `TurnInfo` word.
class FluxWord {
  /// Creates a word.
  const FluxWord({
    required this.word,
    this.confidence = 0,
    this.start,
    this.end,
  });

  /// Parses a `TurnInfo` word entry.
  factory FluxWord.fromJson(Map<String, dynamic> json) => FluxWord(
        word: _asString(json['word']),
        confidence: _asDouble(json['confidence'], 0),
        start: _asNullableDouble(json['start']),
        end: _asNullableDouble(json['end']),
      );

  /// The punctuated, properly-cased word.
  final String word;

  /// Confidence that this word was transcribed correctly (0–1). The spec
  /// serializes this as a string; both forms are accepted.
  final double confidence;

  /// Start time of the word within the audio window, in seconds, when known.
  final double? start;

  /// End time of the word within the audio window, in seconds, when known.
  final double? end;
}

/// A `TurnInfo` message: the current state of the turn being transcribed.
class FluxTurnInfo {
  /// Creates a turn-info event.
  const FluxTurnInfo({
    this.requestId = '',
    this.sequenceId = 0,
    this.event = '',
    this.turnIndex = 0,
    this.audioWindowStart = 0,
    this.audioWindowEnd = 0,
    this.transcript = '',
    this.words = const <FluxWord>[],
    this.endOfTurnConfidence,
    this.trigger,
    this.languages,
    this.languagesHinted,
  });

  /// Parses a `TurnInfo` message.
  factory FluxTurnInfo.fromJson(Map<String, dynamic> json) {
    final words = <FluxWord>[];
    final rawWords = json['words'];
    if (rawWords is List) {
      for (final item in rawWords) {
        if (item is! Map) continue;
        try {
          words.add(FluxWord.fromJson(_stringMap(item)));
        } catch (_) {
          // Skip a malformed word; one bad entry must not lose the rest.
        }
      }
    }
    return FluxTurnInfo(
      requestId: _asString(json['request_id']),
      sequenceId: _asInt(json['sequence_id'], 0),
      event: _asString(json['event']),
      turnIndex: _asInt(json['turn_index'], 0),
      audioWindowStart: _asDouble(json['audio_window_start'], 0),
      audioWindowEnd: _asDouble(json['audio_window_end'], 0),
      transcript: _asString(json['transcript']),
      words: words,
      endOfTurnConfidence: _asNullableDouble(json['end_of_turn_confidence']),
      trigger: _asStringOrNull(json['trigger']),
      languages: _stringListOrNull(json['languages']),
      languagesHinted: _stringListOrNull(json['languages_hinted']),
    );
  }

  /// Unique request id of the session.
  final String requestId;

  /// Server message sequence number (increments across every message type).
  final int sequenceId;

  /// Turn event: `Update`, `StartOfTurn`, `EagerEndOfTurn`, `TurnResumed`,
  /// or `EndOfTurn`.
  final String event;

  /// Index of the current turn.
  final int turnIndex;

  /// Start of the transcribed audio window, in seconds. The spec
  /// serializes this as a string; both forms are accepted.
  final double audioWindowStart;

  /// End of the transcribed audio window, in seconds. The spec serializes
  /// this as a string; both forms are accepted.
  final double audioWindowEnd;

  /// Text said over the course of the current turn so far.
  final String transcript;

  /// The words in [transcript].
  final List<FluxWord> words;

  /// Confidence that no more speech is coming in this turn (present on
  /// `Update` and end-of-turn events). The spec serializes this as a string.
  final double? endOfTurnConfidence;

  /// Cause of the turn ending (`model`, `manual`, or `timeout`) — present
  /// only on `EndOfTurn` events. An open enum: unknown values must be
  /// tolerated.
  final String? trigger;

  /// Detected languages sorted by descending frequency (only with
  /// `flux-general-multi`).
  final List<String>? languages;

  /// Language hints active for this turn, when configured.
  final List<String>? languagesHinted;
}

/// A `Connected` message: the session was established.
class FluxConnected {
  /// Creates a connected event.
  const FluxConnected({this.requestId = '', this.sequenceId = 0});

  /// Parses a `Connected` message.
  factory FluxConnected.fromJson(Map<String, dynamic> json) => FluxConnected(
        requestId: _asString(json['request_id']),
        sequenceId: _asInt(json['sequence_id'], 0),
      );

  /// Unique request id of the session.
  final String requestId;

  /// Server message sequence number.
  final int sequenceId;
}

/// A `ConfigureSuccess` message: a `Configure` message was applied.
class FluxConfigureSuccess {
  /// Creates a configure-success event.
  const FluxConfigureSuccess({
    this.requestId = '',
    this.sequenceId = 0,
    this.thresholds = const <String, dynamic>{},
    this.keyterms,
    this.languageHints,
    this.numerals,
  });

  /// Parses a `ConfigureSuccess` message.
  factory FluxConfigureSuccess.fromJson(Map<String, dynamic> json) =>
      FluxConfigureSuccess(
        requestId: _asString(json['request_id']),
        sequenceId: _asInt(json['sequence_id'], 0),
        thresholds: _stringMap(json['thresholds']),
        keyterms: _keytermsList(json['keyterms']),
        languageHints: _stringListOrNull(json['language_hints']),
        numerals: _asBoolOrNull(json['numerals']),
      );

  /// Unique request id of the session.
  final String requestId;

  /// Server message sequence number.
  final int sequenceId;

  /// The up-to-date thresholds that were applied
  /// (`eot_threshold`, `eager_eot_threshold`, `eot_timeout_ms`).
  final Map<String, dynamic> thresholds;

  /// The up-to-date keyterms. The spec allows either a single string or an
  /// array of strings (or objects with a `keyterm` field); every shape is
  /// normalized into this list.
  final List<String>? keyterms;

  /// The up-to-date language hints (only applicable to `flux-general-multi`).
  final List<String>? languageHints;

  /// Whether numeral formatting is enabled for subsequent transcripts.
  final bool? numerals;
}

/// A `ConfigureFailure` message: a `Configure` message was rejected.
class FluxConfigureFailure {
  /// Creates a configure-failure event.
  const FluxConfigureFailure({
    this.requestId = '',
    this.sequenceId = 0,
    this.code,
    this.description,
  });

  /// Parses a `ConfigureFailure` message.
  factory FluxConfigureFailure.fromJson(Map<String, dynamic> json) =>
      FluxConfigureFailure(
        requestId: _asString(json['request_id']),
        sequenceId: _asInt(json['sequence_id'], 0),
        code: _asStringOrNull(json['code']),
        description: _asStringOrNull(json['description']),
      );

  /// Unique request id of the session.
  final String requestId;

  /// Server message sequence number.
  final int sequenceId;

  /// Failure code identifying the rejected configuration.
  final String? code;

  /// Human-readable description of the configuration failure.
  final String? description;
}

/// A `Warning` message: a non-fatal condition; the connection stays open.
class FluxWarning {
  /// Creates a warning event.
  const FluxWarning({
    this.requestId = '',
    this.sequenceId = 0,
    this.code = '',
    this.description = '',
  });

  /// Parses a `Warning` message.
  factory FluxWarning.fromJson(Map<String, dynamic> json) => FluxWarning(
        requestId: _asString(json['request_id']),
        sequenceId: _asInt(json['sequence_id'], 0),
        code: _asString(json['code']),
        description: _asString(json['description']),
      );

  /// Unique request id of the session.
  final String requestId;

  /// Server message sequence number.
  final int sequenceId;

  /// Warning code in `SCREAMING_SNAKE_CASE`. The SDK adds `PARSE_ERROR` for
  /// frames it could not decode.
  final String code;

  /// Human-readable description of the warning.
  final String description;
}

/// An `Error` message: a fatal error. The server closes the session right
/// after sending it.
class FluxFatalError {
  /// Creates a fatal-error event.
  const FluxFatalError({
    this.requestId,
    this.sequenceId,
    this.code = '',
    this.description = '',
  });

  /// Parses an `Error` message.
  factory FluxFatalError.fromJson(Map<String, dynamic> json) => FluxFatalError(
        requestId: _asStringOrNull(json['request_id']),
        sequenceId: _asIntOrNull(json['sequence_id']),
        code: _asString(json['code']),
        description: _asString(json['description']),
      );

  /// Unique request id of the session, when the server provided one.
  final String? requestId;

  /// Server message sequence number, when the server provided one.
  final int? sequenceId;

  /// Machine-readable error code, e.g. `INTERNAL_SERVER_ERROR`.
  final String code;

  /// Prose description of the error.
  final String description;
}

// ---------------------------------------------------------------------------
// Defensive JSON helpers (library-private)
// ---------------------------------------------------------------------------

Map<String, dynamic> _stringMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map(
      (dynamic key, dynamic val) => MapEntry(key.toString(), val),
    );
  }
  return <String, dynamic>{};
}

String _asString(dynamic value) => value is String ? value : '';

String? _asStringOrNull(dynamic value) => value is String ? value : null;

double _asDouble(dynamic value, double fallback) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

double? _asNullableDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int _asInt(dynamic value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

int? _asIntOrNull(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

bool? _asBoolOrNull(dynamic value) => value is bool ? value : null;

List<String>? _stringListOrNull(dynamic value) {
  if (value is! List) return null;
  final result = <String>[];
  for (final item in value) {
    if (item is String) result.add(item);
  }
  return result;
}

/// Normalizes the spec's `keyterm` shape (a single string, an array of
/// strings, or an array of objects with a `keyterm` field) into a plain
/// list of strings.
List<String>? _keytermsList(dynamic value) {
  if (value == null) return null;
  if (value is String) return <String>[value];
  if (value is! List) return null;
  final result = <String>[];
  for (final item in value) {
    if (item is Map) {
      final inner = item['keyterm'];
      if (inner != null) result.add(inner.toString());
    } else {
      result.add(item.toString());
    }
  }
  return result;
}
