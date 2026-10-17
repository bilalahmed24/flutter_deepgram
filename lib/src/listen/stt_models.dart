/// Shared, immutable result models for Deepgram speech-to-text.
///
/// These classes describe every node of Deepgram's transcription JSON and are
/// reused by the pre-recorded REST client (`POST /v1/listen`), the live
/// streaming client (`wss://api.deepgram.com/v1/listen`), and — wherever the
/// response shapes overlap — the turn-based Flux client
/// (`wss://api.deepgram.com/v2/listen`).
///
/// Every `fromJson` factory in this library is defensive: unexpected or
/// malformed values are skipped or replaced with neutral defaults instead of
/// throwing, so an evolution of the server schema can never crash the SDK.
library;

// ---------------------------------------------------------------------------
// Defensive JSON helpers
// ---------------------------------------------------------------------------

/// Returns [v] when it is of type [T], otherwise `null`.
T? _cast<T>(dynamic v) => v is T ? v : null;

/// Reads a JSON value as a [String].
String? _asStr(dynamic v) => _cast<String>(v);

/// Reads a JSON number as a [double].
double? _asDouble(dynamic v) => _cast<num>(v)?.toDouble();

/// Reads a JSON number as an [int].
int? _asInt(dynamic v) => _cast<num>(v)?.toInt();

/// Coerces a JSON value into a `Map<String, dynamic>` if it is a map.
Map<String, dynamic>? _asMap(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map<dynamic, dynamic>) {
    return v.map(
      (dynamic key, dynamic value) =>
          MapEntry<String, dynamic>(key.toString(), value),
    );
  }
  return null;
}

/// Returns a JSON value as a raw list if it is one.
List<dynamic>? _asList(dynamic v) => _cast<List<dynamic>>(v);

/// Parses a list of JSON objects with [parse], skipping non-object entries.
List<T>? _parseList<T>(
  dynamic v,
  T Function(Map<String, dynamic> json) parse,
) {
  final list = _asList(v);
  if (list == null) return null;
  final result = <T>[];
  for (final item in list) {
    final map = _asMap(item);
    if (map != null) {
      result.add(parse(map));
    }
  }
  return result;
}

/// Parses a value that may be either a single JSON object or a list of them.
List<T>? _parseOneOrMany<T>(
  dynamic v,
  T Function(Map<String, dynamic> json) parse,
) {
  final map = _asMap(v);
  if (map != null) return <T>[parse(map)];
  return _parseList<T>(v, parse);
}

/// Parses results-level feature payloads, which Deepgram wraps as
/// `{"segments": [...]}`, while also tolerating bare objects and bare lists.
List<T>? _parseSegments<T>(
  dynamic v,
  T Function(Map<String, dynamic> json) parse,
) {
  final map = _asMap(v);
  if (map != null) {
    final segments = map['segments'];
    if (segments != null) {
      return _parseList<T>(segments, parse);
    }
    return <T>[parse(map)];
  }
  return _parseList<T>(v, parse);
}

/// Parses a list of strings, skipping non-string entries.
List<String>? _stringList(dynamic v) {
  final list = _asList(v);
  if (list == null) return null;
  final result = <String>[];
  for (final item in list) {
    final s = _asStr(item);
    if (s != null) {
      result.add(s);
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Word-level models
// ---------------------------------------------------------------------------

/// A single transcribed word with timing, confidence, and optional speaker
/// and language information.
class SttWord {
  /// Creates a word.
  const SttWord({
    required this.word,
    this.start,
    this.end,
    this.confidence,
    this.punctuatedWord,
    this.speaker,
    this.language,
  });

  /// Parses a word from its Deepgram JSON representation.
  factory SttWord.fromJson(Map<String, dynamic> json) {
    return SttWord(
      word: _asStr(json['word']) ?? '',
      start: _asDouble(json['start']),
      end: _asDouble(json['end']),
      confidence: _asDouble(json['confidence']),
      punctuatedWord: _asStr(json['punctuated_word']),
      speaker: _asInt(json['speaker']),
      language: _asStr(json['language']),
    );
  }

  /// The recognized word, spelled as it appears in the raw transcript.
  final String word;

  /// Offset of the word start in seconds from the beginning of the audio.
  final double? start;

  /// Offset of the word end in seconds.
  final double? end;

  /// Deepgram's confidence that this word is correct, from 0.0 to 1.0.
  final double? confidence;

  /// The word with punctuation and capitalization applied, when formatting
  /// features are enabled.
  final String? punctuatedWord;

  /// Speaker index assigned by diarization, starting at 0.
  final int? speaker;

  /// Language of the word, when multilingual recognition is enabled.
  final String? language;
}

// ---------------------------------------------------------------------------
// Feature models (summary, sentiment, topic, intent, entity, search hits,
// translation)
// ---------------------------------------------------------------------------

/// A summary covering a span of the transcript.
class SttSummary {
  /// Creates a summary.
  const SttSummary({
    required this.summary,
    this.startWord,
    this.endWord,
  });

  /// Parses a summary from its Deepgram JSON representation.
  factory SttSummary.fromJson(Map<String, dynamic> json) {
    return SttSummary(
      summary: _asStr(json['summary']) ?? '',
      startWord: _asDouble(json['start_word']),
      endWord: _asDouble(json['end_word']),
    );
  }

  /// The summary text.
  final String summary;

  /// Index of the first transcript word covered by this summary.
  final double? startWord;

  /// Index of the last transcript word covered by this summary.
  final double? endWord;
}

/// A sentiment segment: positive, neutral, or negative.
class SttSentiment {
  /// Creates a sentiment segment.
  const SttSentiment({
    required this.text,
    required this.sentiment,
    this.startWord,
    this.endWord,
    this.sentimentScore,
  });

  /// Parses a sentiment from its Deepgram JSON representation.
  factory SttSentiment.fromJson(Map<String, dynamic> json) {
    return SttSentiment(
      text: _asStr(json['text']) ?? '',
      sentiment: _asStr(json['sentiment']) ?? '',
      startWord: _asDouble(json['start_word']),
      endWord: _asDouble(json['end_word']),
      sentimentScore: _asDouble(json['sentiment_score']),
    );
  }

  /// The transcript text the sentiment was computed over.
  final String text;

  /// The detected sentiment: `positive`, `neutral`, or `negative`.
  final String sentiment;

  /// Index of the first word covered by this segment.
  final double? startWord;

  /// Index of the last word covered by this segment.
  final double? endWord;

  /// Normalized sentiment score, typically between -1.0 and 1.0.
  final double? sentimentScore;
}

/// A topic detected over a span of the transcript.
class SttTopic {
  /// Creates a topic.
  const SttTopic({
    required this.topics,
    required this.text,
    this.startWord,
    this.endWord,
  });

  /// Parses a topic from its Deepgram JSON representation.
  factory SttTopic.fromJson(Map<String, dynamic> json) {
    return SttTopic(
      topics: _topicsValue(json['topics']),
      text: _asStr(json['text']) ?? '',
      startWord: _asDouble(json['start_word']),
      endWord: _asDouble(json['end_word']),
    );
  }

  /// The topic label or labels covering this span of text.
  final String topics;

  /// The transcript text the topic was detected over.
  final String text;

  /// Index of the first word covered by this segment.
  final double? startWord;

  /// Index of the last word covered by this segment.
  final double? endWord;
}

/// Normalizes the `topics` field, which Deepgram emits as a plain string, a
/// list of strings, or a list of `{topic, confidence_score}` objects.
String _topicsValue(dynamic v) {
  final s = _asStr(v);
  if (s != null) return s;
  final list = _asList(v);
  if (list == null) return '';
  final parts = <String>[];
  for (final item in list) {
    final str = _asStr(item);
    if (str != null) {
      parts.add(str);
      continue;
    }
    final map = _asMap(item);
    final topic = map == null ? null : _asStr(map['topic']);
    if (topic != null) {
      parts.add(topic);
    }
  }
  return parts.join(', ');
}

/// An intent detected over a span of the transcript.
///
/// Per-utterance payloads carry `{"intent": ..., "intents": [ ... ]}` — when
/// the primary [intent] or [confidence] is absent, the first entry of the
/// `intents` list is used as a fallback.
class SttIntent {
  /// Creates an intent.
  const SttIntent({
    this.intent,
    this.confidence,
    this.text,
    this.startWord,
    this.endWord,
  });

  /// Parses an intent from its Deepgram JSON representation.
  factory SttIntent.fromJson(Map<String, dynamic> json) {
    var intent = _asStr(json['intent']);
    var confidence = _asDouble(json['confidence_score']);
    if (intent == null || confidence == null) {
      final list = _asList(json['intents']);
      if (list != null && list.isNotEmpty) {
        final first = _asMap(list.first);
        if (first != null) {
          intent ??= _asStr(first['intent']);
          confidence ??= _asDouble(first['confidence_score']);
        }
      }
    }
    return SttIntent(
      intent: intent,
      confidence: confidence,
      text: _asStr(json['text']),
      startWord: _asDouble(json['start_word']),
      endWord: _asDouble(json['end_word']),
    );
  }

  /// The primary intent label, for example `book_flight`.
  final String? intent;

  /// Confidence score of the primary intent, from 0.0 to 1.0.
  final double? confidence;

  /// The transcript text the intent was detected over.
  final String? text;

  /// Index of the first word covered by this segment.
  final double? startWord;

  /// Index of the last word covered by this segment.
  final double? endWord;
}

/// An entity (a labeled value such as a person, place, or number) extracted
/// from the transcript.
class SttEntity {
  /// Creates an entity.
  const SttEntity({
    required this.label,
    required this.value,
    this.confidence,
    this.startWord,
    this.endWord,
  });

  /// Parses an entity from its Deepgram JSON representation.
  factory SttEntity.fromJson(Map<String, dynamic> json) {
    return SttEntity(
      label: _asStr(json['label']) ?? '',
      value: _asStr(json['value']) ?? '',
      confidence: _asDouble(json['confidence']),
      startWord: _asDouble(json['start_word']),
      endWord: _asDouble(json['end_word']),
    );
  }

  /// The entity type label, for example `LOCATION`.
  final String label;

  /// The formatted entity value.
  final String value;

  /// Confidence that this entity was extracted correctly.
  final double? confidence;

  /// Index of the first word covered by this entity.
  final double? startWord;

  /// Index of the last word covered by this entity.
  final double? endWord;
}

/// A single match produced by the `search` or `replace` features.
class SttHit {
  /// Creates a search hit.
  const SttHit({
    required this.text,
    required this.start,
    required this.end,
    this.confidence,
  });

  /// Parses a hit from its Deepgram JSON representation. The matched text is
  /// read from the `snippet` key, with `text` accepted as an alias.
  factory SttHit.fromJson(Map<String, dynamic> json) {
    return SttHit(
      text: _asStr(json['snippet']) ?? _asStr(json['text']) ?? '',
      start: _asDouble(json['start']) ?? 0.0,
      end: _asDouble(json['end']) ?? 0.0,
      confidence: _asDouble(json['confidence']),
    );
  }

  /// The matched text.
  final String text;

  /// Offset of the match start in seconds.
  final double start;

  /// Offset of the match end in seconds.
  final double end;

  /// Confidence of the match.
  final double? confidence;
}

/// A transcript translated into a single target language.
class SttTranslation {
  /// Creates a translation.
  const SttTranslation({
    required this.language,
    required this.translation,
  });

  /// Parses a translation from its Deepgram JSON representation.
  factory SttTranslation.fromJson(Map<String, dynamic> json) {
    return SttTranslation(
      language: _asStr(json['language']) ?? '',
      translation: _asStr(json['translation']) ?? '',
    );
  }

  /// The target language of the translation.
  final String language;

  /// The translated text.
  final String translation;
}

// ---------------------------------------------------------------------------
// Paragraph models
// ---------------------------------------------------------------------------

/// A single sentence within a paragraph.
class SttSentence {
  /// Creates a sentence.
  const SttSentence({
    required this.text,
    required this.start,
    required this.end,
  });

  /// Parses a sentence from its Deepgram JSON representation.
  factory SttSentence.fromJson(Map<String, dynamic> json) {
    return SttSentence(
      text: _asStr(json['text']) ?? '',
      start: _asDouble(json['start']) ?? 0.0,
      end: _asDouble(json['end']) ?? 0.0,
    );
  }

  /// The sentence text.
  final String text;

  /// Offset of the sentence start in seconds.
  final double start;

  /// Offset of the sentence end in seconds.
  final double end;
}

/// A paragraph of transcription, produced when `paragraphs=true` is
/// requested.
class SttParagraph {
  /// Creates a paragraph.
  const SttParagraph({
    required this.sentences,
    required this.numWords,
    required this.start,
    required this.end,
  });

  /// Parses a paragraph from its Deepgram JSON representation.
  factory SttParagraph.fromJson(Map<String, dynamic> json) {
    return SttParagraph(
      sentences:
          _parseList<SttSentence>(json['sentences'], SttSentence.fromJson) ??
              const <SttSentence>[],
      numWords: _asInt(json['num_words']) ?? 0,
      start: _asDouble(json['start']) ?? 0.0,
      end: _asDouble(json['end']) ?? 0.0,
    );
  }

  /// The sentences that make up this paragraph.
  final List<SttSentence> sentences;

  /// The number of words in this paragraph.
  final int numWords;

  /// Offset of the paragraph start in seconds.
  final double start;

  /// Offset of the paragraph end in seconds.
  final double end;
}

// ---------------------------------------------------------------------------
// Channel / alternative models
// ---------------------------------------------------------------------------

/// One transcription hypothesis for an audio channel.
class SttAlternative {
  /// Creates an alternative.
  const SttAlternative({
    required this.transcript,
    this.confidence,
    this.words = const <SttWord>[],
    this.paragraphs,
    this.summaries,
    this.sentiments,
    this.topics,
    this.intents,
    this.entities,
    this.translations,
  });

  /// Parses an alternative from its Deepgram JSON representation.
  factory SttAlternative.fromJson(Map<String, dynamic> json) {
    return SttAlternative(
      transcript: _asStr(json['transcript']) ?? '',
      confidence: _asDouble(json['confidence']),
      words: _parseList<SttWord>(json['words'], SttWord.fromJson) ??
          const <SttWord>[],
      paragraphs: _parseParagraphs(json['paragraphs']),
      summaries:
          _parseOneOrMany<SttSummary>(json['summaries'], SttSummary.fromJson),
      sentiments: _parseOneOrMany<SttSentiment>(
          json['sentiments'], SttSentiment.fromJson),
      topics: _parseList<SttTopic>(json['topics'], SttTopic.fromJson),
      intents: _parseOneOrMany<SttIntent>(json['intents'], SttIntent.fromJson),
      entities: _parseList<SttEntity>(json['entities'], SttEntity.fromJson),
      translations: _parseList<SttTranslation>(
          json['translations'], SttTranslation.fromJson),
    );
  }

  /// The transcript text for this alternative.
  final String transcript;

  /// Deepgram's confidence in this alternative, from 0.0 to 1.0.
  final double? confidence;

  /// The individual transcribed words, when word-level detail is enabled.
  final List<SttWord> words;

  /// Paragraphs, when `paragraphs=true` is requested.
  final List<SttParagraph>? paragraphs;

  /// Summaries, when summarization is enabled.
  final List<SttSummary>? summaries;

  /// Sentiment segments, when sentiment analysis is enabled.
  final List<SttSentiment>? sentiments;

  /// Detected topics, when topic detection is enabled.
  final List<SttTopic>? topics;

  /// Detected intents, when intent recognition is enabled.
  final List<SttIntent>? intents;

  /// Detected entities, when `detect_entities=true` is requested.
  final List<SttEntity>? entities;

  /// Translations of this alternative, when translation is enabled.
  final List<SttTranslation>? translations;
}

/// Paragraphs are nested one level deeper than every other alternative
/// feature: `alternatives[].paragraphs` is an object whose `paragraphs` key
/// holds the actual list. A bare list is tolerated defensively.
List<SttParagraph>? _parseParagraphs(dynamic v) {
  final wrapper = _asMap(v);
  if (wrapper != null) {
    return _parseList<SttParagraph>(
      wrapper['paragraphs'],
      SttParagraph.fromJson,
    );
  }
  return _parseList<SttParagraph>(v, SttParagraph.fromJson);
}

/// Transcription results for a single audio channel.
class SttChannel {
  /// Creates a channel.
  const SttChannel({
    required this.alternatives,
    this.detectedLanguage,
    this.languageCode,
  });

  /// Parses a channel from its Deepgram JSON representation.
  factory SttChannel.fromJson(Map<String, dynamic> json) {
    return SttChannel(
      alternatives: _parseList<SttAlternative>(
              json['alternatives'], SttAlternative.fromJson) ??
          const <SttAlternative>[],
      detectedLanguage: _asStr(json['detected_language']),
      languageCode: _asStr(json['language_code']),
    );
  }

  /// The transcription hypotheses for this channel, ordered by confidence.
  final List<SttAlternative> alternatives;

  /// The language Deepgram detected in this channel, when language detection
  /// is enabled.
  final String? detectedLanguage;

  /// The language code of this channel, when multilingual recognition is used.
  final String? languageCode;
}

// ---------------------------------------------------------------------------
// Metadata models
// ---------------------------------------------------------------------------

/// Identifying information about a Deepgram model that produced a result.
class SttModelInfo {
  /// Creates model info.
  const SttModelInfo({this.name, this.version, this.arch});

  /// Parses model info from its Deepgram JSON representation.
  factory SttModelInfo.fromJson(Map<String, dynamic> json) {
    return SttModelInfo(
      name: _asStr(json['name']),
      version: _asStr(json['version']),
      arch: _asStr(json['arch']),
    );
  }

  /// The human-readable model name.
  final String? name;

  /// The model version string.
  final String? version;

  /// The model architecture, for example `nova-2`.
  final String? arch;
}

/// `metadata.model_info` is keyed by model UUID; this returns the first
/// usable entry, tolerating a direct `{name, version, arch}` object.
SttModelInfo? _parseModelInfo(dynamic v) {
  final map = _asMap(v);
  if (map == null) return null;
  for (final value in map.values) {
    final inner = _asMap(value);
    if (inner != null) {
      final info = SttModelInfo.fromJson(inner);
      if (info.name != null || info.version != null || info.arch != null) {
        return info;
      }
    }
  }
  final direct = SttModelInfo.fromJson(map);
  if (direct.name != null || direct.version != null || direct.arch != null) {
    return direct;
  }
  return null;
}

/// Information about the diarizer that produced speaker labels, present only
/// when diarization ran.
class SttDiarizeInfo {
  /// Creates diarize info.
  const SttDiarizeInfo({
    this.modelUuid,
    this.arch,
    this.speakerLabels,
    this.hw,
  });

  /// Parses diarize info from its Deepgram JSON representation.
  factory SttDiarizeInfo.fromJson(Map<String, dynamic> json) {
    return SttDiarizeInfo(
      modelUuid: _asStr(json['model_uuid']),
      arch: _asStr(json['arch']),
      speakerLabels: _parseSpeakerLabels(json['speaker_labels']),
      hw: _asStr(json['hw']),
    );
  }

  /// The diarizer model UUID.
  final String? modelUuid;

  /// The diarizer architecture, such as `v1` or `v2`.
  final String? arch;

  /// Speaker label assignments as `[channel, label]` pairs, when Deepgram
  /// reports the full label matrix.
  final List<List<int>>? speakerLabels;

  /// The hardware the diarizer ran on, when reported.
  final String? hw;
}

/// Parses `speaker_labels` as a list of `[channel, label]` integer pairs,
/// skipping malformed entries.
List<List<int>>? _parseSpeakerLabels(dynamic v) {
  final list = _asList(v);
  if (list == null) return null;
  final result = <List<int>>[];
  for (final item in list) {
    final pair = _asList(item);
    if (pair == null) continue;
    final ints = <int>[];
    for (final element in pair) {
      final value = _asInt(element);
      if (value != null) {
        ints.add(value);
      }
    }
    result.add(ints);
  }
  return result;
}

/// Response metadata shared by all transcription results.
class SttMetadata {
  /// Creates metadata.
  const SttMetadata({
    this.requestId,
    this.transactionKey,
    this.sha256,
    this.created,
    this.duration,
    this.channels,
    this.modelInfo,
    this.models,
    this.modelUuid,
    this.diarizeInfo,
    this.additionalModelUuids,
    this.extra,
  });

  /// Parses metadata from its Deepgram JSON representation.
  factory SttMetadata.fromJson(Map<String, dynamic> json) {
    final diarizeMap = _asMap(json['diarize_info']);
    return SttMetadata(
      requestId: _asStr(json['request_id']),
      transactionKey: _asStr(json['transaction_key']),
      sha256: _asStr(json['sha256']),
      created: _asStr(json['created']),
      duration: _asDouble(json['duration']),
      channels: _asInt(json['channels']),
      modelInfo: _parseModelInfo(json['model_info']),
      models: _stringList(json['models']),
      modelUuid: _asStr(json['model_uuid']),
      diarizeInfo:
          diarizeMap == null ? null : SttDiarizeInfo.fromJson(diarizeMap),
      additionalModelUuids: _stringList(json['additional_model_uuids']),
      extra: _asMap(json['extra']),
    );
  }

  /// The Deepgram request id for this transcription.
  final String? requestId;

  /// Deprecated transaction key, when the server still sends one.
  final String? transactionKey;

  /// SHA-256 hash of the submitted audio.
  final String? sha256;

  /// ISO-8601 timestamp of when the result was created.
  final String? created;

  /// Duration of the submitted audio in seconds.
  final double? duration;

  /// Number of audio channels in the submission.
  final int? channels;

  /// Information about the primary model used.
  final SttModelInfo? modelInfo;

  /// UUIDs of all models used to produce this result.
  final List<String>? models;

  /// UUID of the primary model, when reported.
  final String? modelUuid;

  /// Information about the diarizer, when diarization ran.
  final SttDiarizeInfo? diarizeInfo;

  /// UUIDs of additional models (for example the summarizer), when reported.
  final List<String>? additionalModelUuids;

  /// Arbitrary key-value pairs attached to the response via the `extra` query
  /// parameter.
  final Map<String, dynamic>? extra;
}

// ---------------------------------------------------------------------------
// Utterance model
// ---------------------------------------------------------------------------

/// A semantic unit of speech, produced when `utterances=true` is requested.
class SttUtterance {
  /// Creates an utterance. [channel] is provided as an optional constructor
  /// parameter because some transports report it outside the utterance
  /// object itself.
  const SttUtterance({
    this.start,
    this.end,
    this.confidence,
    required this.transcript,
    this.words = const <SttWord>[],
    this.speaker,
    this.id,
    this.channel,
    this.summaries,
    this.sentiments,
    this.topics,
    this.intents,
    this.entities,
    this.translations,
    this.detector,
  });

  /// Parses an utterance from its Deepgram JSON representation.
  factory SttUtterance.fromJson(Map<String, dynamic> json) {
    var sentiments = _parseOneOrMany<SttSentiment>(
        json['sentiments'], SttSentiment.fromJson);
    sentiments ??=
        _parseOneOrMany<SttSentiment>(json['sentiment'], SttSentiment.fromJson);
    return SttUtterance(
      start: _asDouble(json['start']),
      end: _asDouble(json['end']),
      confidence: _asDouble(json['confidence']),
      transcript: _asStr(json['transcript']) ?? '',
      words: _parseList<SttWord>(json['words'], SttWord.fromJson) ??
          const <SttWord>[],
      speaker: _asInt(json['speaker']),
      id: _asStr(json['id']),
      channel: _asInt(json['channel']),
      summaries:
          _parseOneOrMany<SttSummary>(json['summaries'], SttSummary.fromJson),
      sentiments: sentiments,
      topics: _parseOneOrMany<SttTopic>(json['topics'], SttTopic.fromJson),
      intents: _parseOneOrMany<SttIntent>(json['intents'], SttIntent.fromJson),
      entities: _parseList<SttEntity>(json['entities'], SttEntity.fromJson),
      translations: _parseList<SttTranslation>(
          json['translations'], SttTranslation.fromJson),
      detector: _asStr(json['detector']),
    );
  }

  /// Offset of the utterance start in seconds.
  final double? start;

  /// Offset of the utterance end in seconds.
  final double? end;

  /// Deepgram's confidence for this utterance, from 0.0 to 1.0.
  final double? confidence;

  /// The transcript text of this utterance.
  final String transcript;

  /// The individual words of this utterance, when word detail is available.
  final List<SttWord> words;

  /// Speaker index assigned by diarization, when enabled.
  final int? speaker;

  /// Server-assigned utterance id, when reported.
  final String? id;

  /// Index of the audio channel this utterance belongs to.
  final int? channel;

  /// Summaries covering this utterance, when enabled.
  final List<SttSummary>? summaries;

  /// Sentiment segments covering this utterance, when enabled.
  final List<SttSentiment>? sentiments;

  /// Topics covering this utterance, when enabled.
  final List<SttTopic>? topics;

  /// Intents covering this utterance, when enabled.
  final List<SttIntent>? intents;

  /// Entities extracted from this utterance, when enabled.
  final List<SttEntity>? entities;

  /// Translations of this utterance, when enabled.
  final List<SttTranslation>? translations;

  /// Name of the feature detector that produced this utterance's
  /// annotations, when applicable.
  final String? detector;
}

// ---------------------------------------------------------------------------
// Top-level pre-recorded result
// ---------------------------------------------------------------------------

/// The complete response of `POST /v1/listen` (pre-recorded transcription).
///
/// The `results` object of the raw JSON is flattened onto this class:
/// [channels] always carries at least the first channel's alternatives, and
/// [utterances], [summaries], [sentiments], [topics], [intents],
/// [translations], and [summary] are populated only when the corresponding
/// features were requested.
class PrerecordedTranscriptionResult {
  /// Creates a transcription result.
  const PrerecordedTranscriptionResult({
    required this.metadata,
    this.channels = const <SttChannel>[],
    this.utterances,
    this.summary,
    this.summaries,
    this.sentiments,
    this.topics,
    this.intents,
    this.translations,
  });

  /// Parses the full `POST /v1/listen` response body.
  factory PrerecordedTranscriptionResult.fromJson(Map<String, dynamic> json) {
    // Copy defensively: the source map belongs to the caller.
    final metadataJson = Map<String, dynamic>.from(
      _asMap(json['metadata']) ?? <String, dynamic>{},
    );
    if (_asStr(metadataJson['request_id']) == null) {
      // Asynchronous (callback) responses carry the request id at the top
      // level instead of inside metadata.
      final topLevelId = _asStr(json['request_id']);
      if (topLevelId != null) {
        metadataJson['request_id'] = topLevelId;
      }
    }
    final results = _asMap(json['results']) ?? <String, dynamic>{};
    return PrerecordedTranscriptionResult(
      metadata: SttMetadata.fromJson(metadataJson),
      channels:
          _parseList<SttChannel>(results['channels'], SttChannel.fromJson) ??
              const <SttChannel>[],
      utterances: _parseList<SttUtterance>(
          results['utterances'], SttUtterance.fromJson),
      summary: _parseSummary(results['summary']),
      summaries: _parseOneOrMany<SttSummary>(
          results['summaries'], SttSummary.fromJson),
      sentiments: _parseSegments<SttSentiment>(
          results['sentiments'], SttSentiment.fromJson),
      topics: _parseSegments<SttTopic>(results['topics'], SttTopic.fromJson),
      intents:
          _parseSegments<SttIntent>(results['intents'], SttIntent.fromJson),
      translations: _parseTranslations(results['translations']),
    );
  }

  /// Response metadata (request id, duration, model info, ...).
  final SttMetadata metadata;

  /// Per-channel transcription results.
  final List<SttChannel> channels;

  /// Semantic units of speech, when `utterances=true` was requested.
  final List<SttUtterance>? utterances;

  /// The results-level summary: either a plain string or the `text`, `short`,
  /// or `result` field of a summary object, depending on the summarization
  /// version the server used.
  final String? summary;

  /// Segment-level summaries, when v2 summarization is enabled.
  final List<SttSummary>? summaries;

  /// Sentiment segments, when `sentiment=true` was requested.
  final List<SttSentiment>? sentiments;

  /// Detected topics, when `topics=true` was requested.
  final List<SttTopic>? topics;

  /// Detected intents, when `intents=true` was requested.
  final List<SttIntent>? intents;

  /// Translations keyed by language code, when translation is enabled.
  final Map<String, String>? translations;

  /// The Deepgram request id for this transcription.
  String? get requestId => metadata.requestId;
}

/// The results-level `summary` value: a plain string, or an object carrying
/// the text under `text`, `short`, or `result`.
String? _parseSummary(dynamic v) {
  final s = _asStr(v);
  if (s != null) return s;
  final map = _asMap(v);
  if (map == null) return null;
  return _asStr(map['text']) ?? _asStr(map['short']) ?? _asStr(map['result']);
}

/// `results.translations` maps language codes to translated text.
Map<String, String>? _parseTranslations(dynamic v) {
  final map = _asMap(v);
  if (map == null) return null;
  final result = <String, String>{};
  map.forEach((String key, dynamic value) {
    final text = _asStr(value);
    if (text != null) {
      result[key] = text;
    }
  });
  return result;
}
