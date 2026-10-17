/// Text Intelligence over `POST /v1/read`.
///
/// Analyzes plain text (or a text file URL) for sentiment, topics,
/// summaries, and intents:
///
/// ```dart
/// final result = await deepgram.intelligence.analyze(
///   'I love this product. It changed my life!',
///   options: const TextIntelligenceOptions(sentiment: true, topics: true),
/// );
/// print(result.sentiments.first.sentiment); // positive
/// ```
library;

import '../core/deepgram_config.dart';
import '../core/http/http_engine.dart';

/// Options for `POST /v1/read` text analysis.
///
/// Every field is optional; only the features you enable are billed and
/// returned. `custom_topic` and `custom_intent` are submitted as repeated
/// query keys (`custom_topic=a&custom_topic=b`), while their mode
/// counterparts are single keys.
class TextIntelligenceOptions {
  /// Creates text intelligence options.
  const TextIntelligenceOptions({
    this.sentiment,
    this.topics,
    this.summarize,
    this.intents,
    this.customTopic,
    this.customTopicMode,
    this.customIntent,
    this.customIntentMode,
    this.language,
    this.tag,
    this.callback,
    this.callbackMethod,
  });

  /// Recognizes the sentiment throughout the text.
  final bool? sentiment;

  /// Detects topics throughout the text.
  final bool? topics;

  /// Summarizes the text (the Read API accepts a boolean only).
  final bool? summarize;

  /// Recognizes intent throughout the text.
  final bool? intents;

  /// Custom topics the model should detect (up to 100). Submitted as
  /// repeated `custom_topic` query keys.
  final List<String>? customTopic;

  /// How the model interprets [customTopic]: `strict` (only the custom
  /// topics) or `extended` (custom + model-detected topics). Default:
  /// `extended`.
  final String? customTopicMode;

  /// Custom intents the model should detect. Submitted as repeated
  /// `custom_intent` query keys.
  final List<String>? customIntent;

  /// How the model interprets [customIntent]: `strict` or `extended`.
  /// Default: `extended`.
  final String? customIntentMode;

  /// BCP-47 language tag hinting at the primary language (default: `en`).
  final String? language;

  /// Tags for usage reporting. Submitted as repeated `tag` query keys.
  final List<String>? tag;

  /// URL to which Deepgram makes the callback request.
  final String? callback;

  /// HTTP method for the callback: `POST` or `PUT`. Default: `POST`.
  final String? callbackMethod;

  /// Allowed values for [customTopicMode].
  static const List<String> customTopicModes = <String>['strict', 'extended'];

  /// Allowed values for [customIntentMode].
  static const List<String> customIntentModes = <String>['strict', 'extended'];

  /// Allowed values for [callbackMethod].
  static const List<String> callbackMethods = <String>['POST', 'PUT'];

  /// Builds the query map for `POST /v1/read`.
  ///
  /// Null fields are omitted. List values ([customTopic], [customIntent],
  /// [tag]) are rendered by the HTTP engine as repeated query keys.
  Map<String, dynamic> toQuery() {
    return <String, dynamic>{
      if (sentiment != null) 'sentiment': sentiment,
      if (topics != null) 'topics': topics,
      if (summarize != null) 'summarize': summarize,
      if (intents != null) 'intents': intents,
      if (customTopic != null && customTopic!.isNotEmpty)
        'custom_topic': customTopic,
      if (customTopicMode != null) 'custom_topic_mode': customTopicMode,
      if (customIntent != null && customIntent!.isNotEmpty)
        'custom_intent': customIntent,
      if (customIntentMode != null) 'custom_intent_mode': customIntentMode,
      if (language != null) 'language': language,
      if (tag != null && tag!.isNotEmpty) 'tag': tag,
      if (callback != null) 'callback': callback,
      if (callbackMethod != null) 'callback_method': callbackMethod,
    };
  }
}

/// The result of a `POST /v1/read` text analysis.
///
/// Sentiments, summaries, topics, and intents are flattened into
/// easy-to-consume lists regardless of which response envelope Deepgram
/// returns (the API has shipped both a segment-based legacy shape and a
/// list-based current shape; both are parsed defensively).
class TextIntelligenceResult {
  /// Creates a text intelligence result.
  const TextIntelligenceResult({
    required this.metadata,
    required this.sentiments,
    required this.summaries,
    required this.topics,
    required this.intents,
    this.averageSentiment,
    this.averageSentimentScore,
  });

  /// Parses a decoded `POST /v1/read` response body.
  factory TextIntelligenceResult.fromJson(Map<String, dynamic> json) {
    final results = _asJsonObject(json['results']);

    String? averageSentiment;
    double? averageSentimentScore;
    final rawSentiments = results['sentiments'];
    if (rawSentiments is Map<String, dynamic>) {
      final unwrapped = _unwrapResultsEnvelope(rawSentiments, 'sentiments');
      final average = _cast<Map<String, dynamic>>(unwrapped['average']);
      if (average != null) {
        averageSentiment = _asString(average['sentiment']);
        averageSentimentScore = _asDouble(average['sentiment_score']);
      }
    }

    return TextIntelligenceResult(
      metadata: TextIntelligenceMetadata.fromJson(
        _asJsonObject(json['metadata']),
      ),
      sentiments: _parseSentiments(rawSentiments),
      summaries: _parseSummaries(results),
      topics: _parseTopics(results['topics']),
      intents: _parseIntents(results['intents']),
      averageSentiment: averageSentiment,
      averageSentimentScore: averageSentimentScore,
    );
  }

  /// Request metadata (request id, timestamps, and per-feature model info).
  final TextIntelligenceMetadata metadata;

  /// Detected sentiment segments, ordered by their position in the text.
  final List<TextSentiment> sentiments;

  /// Generated summaries (typically zero or one entry).
  final List<TextSummary> summaries;

  /// Detected topics with confidence scores.
  final List<TextTopic> topics;

  /// Detected intents with confidence scores.
  final List<TextIntent> intents;

  /// Average sentiment label across all segments (e.g. `positive`), when the
  /// API reports one.
  final String? averageSentiment;

  /// Average sentiment score across all segments, when reported.
  final double? averageSentimentScore;
}

/// Metadata accompanying a text intelligence response.
class TextIntelligenceMetadata {
  /// Creates text intelligence metadata.
  const TextIntelligenceMetadata({
    this.requestId,
    this.created,
    this.language,
    this.summaryInfo,
    this.sentimentInfo,
    this.topicsInfo,
    this.intentsInfo,
    this.modelInfo,
    this.models,
  });

  /// Parses metadata from a decoded response, unwrapping the legacy
  /// `{metadata: {metadata: {...}}}` envelope when present.
  factory TextIntelligenceMetadata.fromJson(Map<String, dynamic> json) {
    var source = json;
    final envelope = _cast<Map<String, dynamic>>(json['metadata']);
    if (envelope != null) {
      source = envelope;
    }
    return TextIntelligenceMetadata(
      requestId: _asString(source['request_id']),
      created: _asString(source['created']),
      language: _asString(source['language']),
      summaryInfo: _parseModelUsageInfo(source['summary_info']),
      sentimentInfo: _parseModelUsageInfo(source['sentiment_info']),
      topicsInfo: _parseModelUsageInfo(source['topics_info']),
      intentsInfo: _parseModelUsageInfo(source['intents_info']),
      modelInfo: _cast<Map<String, dynamic>>(source['model_info']),
      models: _stringList(source['models']),
    );
  }

  /// Unique request identifier.
  final String? requestId;

  /// ISO-8601 timestamp of when the request was created.
  final String? created;

  /// Language of the analyzed text, when reported.
  final String? language;

  /// Token accounting for the summarization model, when summarize ran.
  final TextModelUsageInfo? summaryInfo;

  /// Token accounting for the sentiment model, when sentiment ran.
  final TextModelUsageInfo? sentimentInfo;

  /// Token accounting for the topic detection model, when topics ran.
  final TextModelUsageInfo? topicsInfo;

  /// Token accounting for the intent model, when intents ran.
  final TextModelUsageInfo? intentsInfo;

  /// Raw model information map (current API shape), when reported.
  final Map<String, dynamic>? modelInfo;

  /// Names of the models applied to the request (current API shape).
  final List<String>? models;
}

/// Per-feature model usage accounting from text intelligence metadata.
class TextModelUsageInfo {
  /// Creates model usage info.
  const TextModelUsageInfo({
    this.modelUuid,
    this.inputTokens,
    this.outputTokens,
  });

  /// Parses model usage info from a decoded JSON object.
  factory TextModelUsageInfo.fromJson(Map<String, dynamic> json) {
    return TextModelUsageInfo(
      modelUuid: _asString(json['model_uuid']),
      inputTokens: _asInt(json['input_tokens']),
      outputTokens: _asInt(json['output_tokens']),
    );
  }

  /// UUID of the model that processed the feature.
  final String? modelUuid;

  /// Number of input tokens consumed.
  final int? inputTokens;

  /// Number of output tokens consumed.
  final int? outputTokens;
}

/// One sentiment segment of the analyzed text.
class TextSentiment {
  /// Creates a sentiment segment.
  const TextSentiment({
    this.text = '',
    this.sentiment = '',
    this.sentimentScore,
    this.startWord,
    this.endWord,
  });

  /// Parses a sentiment segment (or legacy segment item) from decoded JSON.
  factory TextSentiment.fromJson(Map<String, dynamic> json) {
    return TextSentiment(
      text: _asString(json['text']) ?? '',
      sentiment: _asString(json['sentiment']) ?? '',
      sentimentScore: _asDouble(json['sentiment_score']),
      startWord: _asInt(json['start_word']),
      endWord: _asInt(json['end_word']),
    );
  }

  /// The text of the segment.
  final String text;

  /// Sentiment label: `positive`, `neutral`, or `negative`.
  final String sentiment;

  /// Sentiment score between -1 and 1.
  final double? sentimentScore;

  /// Index of the first word of the segment.
  final int? startWord;

  /// Index of the last word of the segment.
  final int? endWord;
}

/// One generated summary of the analyzed text.
class TextSummary {
  /// Creates a summary.
  const TextSummary({this.summary = '', this.startWord, this.endWord});

  /// Parses a summary from decoded JSON.
  factory TextSummary.fromJson(Map<String, dynamic> json) {
    return TextSummary(
      summary: _asString(json['summary']) ?? _asString(json['text']) ?? '',
      startWord: _asInt(json['start_word']),
      endWord: _asInt(json['end_word']),
    );
  }

  /// The summary text.
  final String summary;

  /// Index of the first word the summary covers, when reported.
  final int? startWord;

  /// Index of the last word the summary covers, when reported.
  final int? endWord;
}

/// One detected topic within a segment of the analyzed text.
class TextTopic {
  /// Creates a topic.
  const TextTopic({
    this.topic = '',
    this.confidenceScore,
    this.startWord,
    this.endWord,
  });

  /// Parses a topic from decoded JSON.
  factory TextTopic.fromJson(Map<String, dynamic> json) {
    return TextTopic(
      topic: _asString(json['topic']) ?? '',
      confidenceScore: _asDouble(json['confidence_score']),
      startWord: _asInt(json['start_word']),
      endWord: _asInt(json['end_word']),
    );
  }

  /// The detected topic label.
  final String topic;

  /// Confidence score between 0 and 1.
  final double? confidenceScore;

  /// Index of the first word of the segment the topic was found in.
  final int? startWord;

  /// Index of the last word of that segment.
  final int? endWord;
}

/// One detected intent within a segment of the analyzed text.
class TextIntent {
  /// Creates an intent.
  const TextIntent({
    this.intent = '',
    this.confidenceScore,
    this.startWord,
    this.endWord,
  });

  /// Parses an intent from decoded JSON.
  factory TextIntent.fromJson(Map<String, dynamic> json) {
    return TextIntent(
      intent: _asString(json['intent']) ?? '',
      confidenceScore: _asDouble(json['confidence_score']),
      startWord: _asInt(json['start_word']),
      endWord: _asInt(json['end_word']),
    );
  }

  /// The detected intent label.
  final String intent;

  /// Confidence score between 0 and 1.
  final double? confidenceScore;

  /// Index of the first word of the segment the intent was found in.
  final int? startWord;

  /// Index of the last word of that segment.
  final int? endWord;
}

/// REST client for the Deepgram Text Intelligence API (`/v1/read`).
class TextIntelligenceClient {
  /// Creates a text intelligence client.
  TextIntelligenceClient(
      {required HttpEngine http, required DeepgramConfig config})
      : _http = http,
        _config = config;

  final HttpEngine _http;
  final DeepgramConfig _config;

  /// The configuration this client was built from.
  DeepgramConfig get config => _config;

  /// Analyzes plain text: `POST /v1/read` with body `{'text': text}`.
  ///
  /// Throws a typed DeepgramException subtype (see
  /// `deepgram_exception.dart`) on failure; errors are already retried by
  /// the engine where safe.
  Future<TextIntelligenceResult> analyze(
    String text, {
    TextIntelligenceOptions? options,
    HttpCancelToken? cancelToken,
  }) async {
    final result = await _http.postJson(
      '/v1/read',
      body: <String, dynamic>{'text': text},
      query: options?.toQuery(),
      cancelToken: cancelToken,
    );
    return TextIntelligenceResult.fromJson(result.body);
  }

  /// Analyzes a text file hosted at [url]: `POST /v1/read` with body
  /// `{'url': url}` (the alternate `ReadV1RequestUrl` shape).
  Future<TextIntelligenceResult> analyzeUrl(
    String url, {
    TextIntelligenceOptions? options,
    HttpCancelToken? cancelToken,
  }) async {
    final result = await _http.postJson(
      '/v1/read',
      body: <String, dynamic>{'url': url},
      query: options?.toQuery(),
      cancelToken: cancelToken,
    );
    return TextIntelligenceResult.fromJson(result.body);
  }
}

// ---------------------------------------------------------------------------
// Defensive JSON helpers (file-private)
// ---------------------------------------------------------------------------

T? _cast<T>(dynamic v) => v is T ? v : null;

Map<String, dynamic> _asJsonObject(dynamic v) =>
    v is Map<String, dynamic> ? v : const <String, dynamic>{};

List<dynamic> _asJsonArray(dynamic v) =>
    v is List<dynamic> ? v : const <dynamic>[];

String? _asString(dynamic v) => v is String ? v : null;

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v);
  return null;
}

double? _asDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

List<String>? _stringList(dynamic v) {
  if (v is! List<dynamic>) return null;
  return <String>[
    for (final item in v)
      if (item is String) item
  ];
}

TextModelUsageInfo? _parseModelUsageInfo(dynamic v) {
  final map = _cast<Map<String, dynamic>>(v);
  if (map == null) return null;
  return TextModelUsageInfo.fromJson(map);
}

/// Unwraps legacy `{results: {<key>: {...}}}` envelopes used by some
/// `/v1/read` response fields, returning the innermost payload map.
Map<String, dynamic> _unwrapResultsEnvelope(
  Map<String, dynamic> map,
  String key,
) {
  var current = map;
  for (var depth = 0; depth < 3; depth++) {
    final inner = _cast<Map<String, dynamic>>(current['results']);
    if (inner == null) break;
    final nested = _cast<Map<String, dynamic>>(inner[key]);
    if (nested != null) {
      current = nested;
      continue;
    }
    current = inner;
    break;
  }
  return current;
}

List<TextSentiment> _parseSentiments(dynamic raw) {
  final out = <TextSentiment>[];
  if (raw is List<dynamic>) {
    for (final item in raw) {
      final map = _cast<Map<String, dynamic>>(item);
      if (map != null) out.add(TextSentiment.fromJson(map));
    }
    return out;
  }
  final map = _cast<Map<String, dynamic>>(raw);
  if (map == null) return out;
  final unwrapped = _unwrapResultsEnvelope(map, 'sentiments');
  for (final item in _asJsonArray(unwrapped['segments'])) {
    final segment = _cast<Map<String, dynamic>>(item);
    if (segment != null) out.add(TextSentiment.fromJson(segment));
  }
  return out;
}

List<TextSummary> _parseSummaries(Map<String, dynamic> results) {
  final out = <TextSummary>[];

  // Current shape: results.summaries is a list of summary objects.
  final rawList = results['summaries'];
  if (rawList is List<dynamic>) {
    for (final item in rawList) {
      final map = _cast<Map<String, dynamic>>(item);
      if (map == null) continue;
      final text = _summaryTextOf(map);
      if (text == null) continue;
      out.add(TextSummary(
        summary: text,
        startWord: _asInt(map['start_word']),
        endWord: _asInt(map['end_word']),
      ));
    }
    if (out.isNotEmpty) return out;
  }

  // Legacy shape: results.summary = {results: {summary: {text}}} or a flat
  // {text} / {result} / {short} object.
  final rawSummary = _cast<Map<String, dynamic>>(results['summary']);
  if (rawSummary == null) return out;
  var node = rawSummary;
  final envelope = _cast<Map<String, dynamic>>(node['results']);
  if (envelope != null) {
    final nested = _cast<Map<String, dynamic>>(envelope['summary']);
    node = nested ?? envelope;
  }
  final text = _summaryTextOf(node);
  if (text == null) return out;
  out.add(TextSummary(
    summary: text,
    startWord: _asInt(node['start_word']),
    endWord: _asInt(node['end_word']),
  ));
  return out;
}

String? _summaryTextOf(Map<String, dynamic> map) {
  var text = _asString(map['summary']);
  text ??= _asString(map['text']);
  text ??= _asString(map['result']);
  text ??= _asString(map['short']);
  if (text == null) {
    final nested = _cast<Map<String, dynamic>>(map['summary']);
    if (nested != null) text = _asString(nested['text']);
  }
  if (text == null || text.isEmpty) return null;
  return text;
}

List<TextTopic> _parseTopics(dynamic raw) {
  final out = <TextTopic>[];
  if (raw is List<dynamic>) {
    for (final item in raw) {
      final segment = _cast<Map<String, dynamic>>(item);
      if (segment != null) _collectTopics(segment, out);
    }
    return out;
  }
  final map = _cast<Map<String, dynamic>>(raw);
  if (map == null) return out;
  final unwrapped = _unwrapResultsEnvelope(map, 'topics');
  for (final item in _asJsonArray(unwrapped['segments'])) {
    final segment = _cast<Map<String, dynamic>>(item);
    if (segment != null) _collectTopics(segment, out);
  }
  return out;
}

void _collectTopics(Map<String, dynamic> segment, List<TextTopic> out) {
  final startWord = _asInt(segment['start_word']);
  final endWord = _asInt(segment['end_word']);
  final nested = _asJsonArray(segment['topics']);
  if (nested.isEmpty) {
    final direct = _asString(segment['topic']);
    if (direct != null && direct.isNotEmpty) {
      out.add(TextTopic(
        topic: direct,
        startWord: startWord,
        endWord: endWord,
      ));
    }
    return;
  }
  for (final item in nested) {
    final topicMap = _cast<Map<String, dynamic>>(item);
    if (topicMap == null) continue;
    out.add(TextTopic(
      topic: _asString(topicMap['topic']) ?? '',
      confidenceScore: _asDouble(topicMap['confidence_score']),
      startWord: _asInt(topicMap['start_word']) ?? startWord,
      endWord: _asInt(topicMap['end_word']) ?? endWord,
    ));
  }
}

List<TextIntent> _parseIntents(dynamic raw) {
  final out = <TextIntent>[];
  if (raw is List<dynamic>) {
    for (final item in raw) {
      final segment = _cast<Map<String, dynamic>>(item);
      if (segment != null) _collectIntents(segment, out);
    }
    return out;
  }
  final map = _cast<Map<String, dynamic>>(raw);
  if (map == null) return out;
  final unwrapped = _unwrapResultsEnvelope(map, 'intents');
  for (final item in _asJsonArray(unwrapped['segments'])) {
    final segment = _cast<Map<String, dynamic>>(item);
    if (segment != null) _collectIntents(segment, out);
  }
  return out;
}

void _collectIntents(Map<String, dynamic> segment, List<TextIntent> out) {
  final startWord = _asInt(segment['start_word']);
  final endWord = _asInt(segment['end_word']);
  final nested = _asJsonArray(segment['intents']);
  if (nested.isEmpty) {
    final direct = _asString(segment['intent']);
    if (direct != null && direct.isNotEmpty) {
      out.add(TextIntent(
        intent: direct,
        startWord: startWord,
        endWord: endWord,
      ));
    }
    return;
  }
  for (final item in nested) {
    final intentMap = _cast<Map<String, dynamic>>(item);
    if (intentMap == null) continue;
    out.add(TextIntent(
      intent: _asString(intentMap['intent']) ?? '',
      confidenceScore: _asDouble(intentMap['confidence_score']),
      startWord: _asInt(intentMap['start_word']) ?? startWord,
      endWord: _asInt(intentMap['end_word']) ?? endWord,
    ));
  }
}
