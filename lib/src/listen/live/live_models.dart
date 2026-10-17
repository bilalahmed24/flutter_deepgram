/// Typed server messages for the `/v1/listen` live transcription WebSocket.
///
/// Every class defensively parses its JSON frame: missing or malformed fields
/// fall back to empty defaults instead of throwing, so one bad frame can
/// never take down a stream.
library;

import '../stt_models.dart';

/// A `Results` message: an interim or final transcription for one channel.
class LiveTranscriptionResult {
  /// Creates a transcription result.
  ///
  /// Usually obtained from [LiveTranscriptionResult.fromJson]; the
  /// constructor is public so gap-recovery code can synthesize recovered
  /// results from pre-recorded REST responses.
  LiveTranscriptionResult({
    this.alternatives = const <SttAlternative>[],
    this.channelIndex = const <int>[],
    this.duration = 0,
    this.start = 0,
    this.isFinal = false,
    this.speechFinal = false,
    this.fromFinalize = false,
    required this.metadata,
    this.entities = const <SttEntity>[],
    this.recovered = false,
    this.recoveredAtUtc,
  });

  /// Parses a `Results` message.
  factory LiveTranscriptionResult.fromJson(Map<String, dynamic> json) {
    final channel = _stringMap(json['channel']);
    final alternatives = <SttAlternative>[];
    final rawAlternatives = channel['alternatives'];
    if (rawAlternatives is List) {
      for (final item in rawAlternatives) {
        if (item is! Map) continue;
        try {
          alternatives.add(SttAlternative.fromJson(_stringMap(item)));
        } catch (_) {
          // Skip a malformed alternative; one bad entry must not lose the rest.
        }
      }
    }
    final entities = <SttEntity>[];
    final rawEntities = json['entities'];
    if (rawEntities is List) {
      for (final item in rawEntities) {
        if (item is! Map) continue;
        try {
          entities.add(SttEntity.fromJson(_stringMap(item)));
        } catch (_) {
          // Skip a malformed entity.
        }
      }
    }
    return LiveTranscriptionResult(
      alternatives: alternatives,
      channelIndex: _intList(json['channel_index']),
      duration: _asDouble(json['duration'], 0),
      start: _asDouble(json['start'], 0),
      isFinal: json['is_final'] == true,
      speechFinal: json['speech_final'] == true,
      fromFinalize: json['from_finalize'] == true,
      metadata: SttMetadata.fromJson(_stringMap(json['metadata'])),
      entities: entities,
    );
  }

  /// Alternatives for the channel this result belongs to, best first.
  final List<SttAlternative> alternatives;

  /// `[channel, stream]` indices this result belongs to.
  final List<int> channelIndex;

  /// Duration of the covered audio span, in seconds.
  final double duration;

  /// Start of the covered audio span, in seconds.
  final double start;

  /// Whether this result is final (it will not be revised again).
  final bool isFinal;

  /// Whether speech ended with this result (endpointing).
  final bool speechFinal;

  /// Whether this result was flushed by a `Finalize` message.
  final bool fromFinalize;

  /// Request metadata.
  final SttMetadata metadata;

  /// Entities detected when `detect_entities` is enabled. Only present in
  /// final results.
  final List<SttEntity> entities;

  /// Whether this result was recovered through gap recovery rather than
  /// received over the live socket.
  final bool recovered;

  /// UTC instant the connection was lost, anchoring a recovered result to
  /// its true position in the timeline. `null` for live results.
  final DateTime? recoveredAtUtc;

  /// The transcript of the first alternative (empty string when none).
  String get transcript {
    if (alternatives.isEmpty) return '';
    return alternatives.first.transcript;
  }
}

/// The `Metadata` message: a summary flushed by the server after
/// `CloseStream`, once all final results have been delivered.
class LiveMetadataMessage {
  /// Creates a metadata message.
  LiveMetadataMessage({
    this.requestId = '',
    this.transactionKey = '',
    this.sha256 = '',
    this.created = '',
    this.duration = 0,
    this.channels = 0,
  });

  /// Parses a `Metadata` message.
  factory LiveMetadataMessage.fromJson(Map<String, dynamic> json) =>
      LiveMetadataMessage(
        requestId: _asString(json['request_id']),
        transactionKey: _asString(json['transaction_key']),
        sha256: _asString(json['sha256']),
        created: _asString(json['created']),
        duration: _asDouble(json['duration'], 0),
        channels: _asInt(json['channels'], 0),
      );

  /// Unique request id shared by every message of the session.
  final String requestId;

  /// Deprecated transaction key.
  final String transactionKey;

  /// SHA-256 of the submitted audio.
  final String sha256;

  /// ISO-8601 timestamp of the request.
  final String created;

  /// Total duration of the submitted audio, in seconds.
  final double duration;

  /// Number of audio channels.
  final int channels;
}

/// An `UtteranceEnd` message: the microphone went silent long enough to end
/// an utterance (requires `utterance_end_ms`).
class LiveUtteranceEnd {
  /// Creates an utterance-end event.
  LiveUtteranceEnd({this.channel = const <int>[], this.lastWordEnd = 0});

  /// Parses an `UtteranceEnd` message.
  factory LiveUtteranceEnd.fromJson(Map<String, dynamic> json) =>
      LiveUtteranceEnd(
        channel: _intList(json['channel']),
        lastWordEnd: _asDouble(json['last_word_end'], 0),
      );

  /// `[channel, stream]` indices the event belongs to.
  final List<int> channel;

  /// End time of the last word in the ended utterance, in seconds.
  final double lastWordEnd;
}

/// A `SpeechStarted` message: speech was detected after a silence
/// (requires `vad_events`).
class LiveSpeechStarted {
  /// Creates a speech-started event.
  LiveSpeechStarted({this.channel = const <int>[], this.timestamp = 0});

  /// Parses a `SpeechStarted` message.
  factory LiveSpeechStarted.fromJson(Map<String, dynamic> json) =>
      LiveSpeechStarted(
        channel: _intList(json['channel']),
        timestamp: _asDouble(json['timestamp'], 0),
      );

  /// `[channel, stream]` indices the event belongs to.
  final List<int> channel;

  /// Timestamp of the detected speech start, in seconds.
  final double timestamp;
}

/// An `Error` message: a non-fatal server-side rejection.
///
/// Fatal failures close the socket instead of sending this message.
class LiveErrorMessage {
  /// Creates an error event.
  LiveErrorMessage({
    this.variant = '',
    this.description = '',
    this.code,
    this.message,
  });

  /// Parses an `Error` message.
  factory LiveErrorMessage.fromJson(Map<String, dynamic> json) =>
      LiveErrorMessage(
        variant: _asString(json['variant']),
        description: _asString(json['description']),
        code: _asStringOrNull(json['code']),
        message: _asStringOrNull(json['message']),
      );

  /// Error category. The server sends `SchemaError` (an unparseable client
  /// text message) or `InvalidConfigureMessage` (a rejected `Configure`
  /// message); the SDK adds `ParseError` for frames it could not decode.
  final String variant;

  /// Human-readable description of what went wrong.
  final String description;

  /// Machine-readable reason, e.g. `KeytermsNotSupported` for a rejected
  /// `Configure` message.
  final String? code;

  /// For `SchemaError`: the original client message that could not be
  /// parsed. For SDK `ParseError` events: the offending server frame.
  final String? message;
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

int _asInt(dynamic value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

List<int> _intList(dynamic value) {
  if (value is! List) return const <int>[];
  final result = <int>[];
  for (final item in value) {
    if (item is int) {
      result.add(item);
    } else if (item is num) {
      result.add(item.toInt());
    } else if (item is String) {
      final parsed = int.tryParse(item);
      if (parsed != null) result.add(parsed);
    }
  }
  return result;
}
