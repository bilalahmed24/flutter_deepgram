/// Typed options for every documented query parameter of Deepgram's
/// pre-recorded speech-to-text endpoint, `POST /v1/listen`.
///
/// Options are immutable and serialize themselves with [toQuery] using the
/// documented snake_case wire keys. Null fields are skipped so the API
/// defaults apply; booleans are sent as the strings `true`/`false`; list
/// fields are sent as repeated query keys.
library;

/// Options for `POST /v1/listen`.
///
/// Example:
///
/// ```dart
/// const options = PrerecordedOptions(
///   model: DeepgramSttModels.nova3,
///   smartFormat: true,
///   detectLanguage: true,
///   summarize: SummarizeOptions(mode: SummarizeMode.paragraphs),
/// );
/// // options.toQuery() ->
/// // model=nova-3&smart_format=true&detect_language=true&summarize=v2
/// //   &summarize_mode=paragraphs
/// ```
class PrerecordedOptions {
  /// Creates a set of pre-recorded transcription options.
  const PrerecordedOptions({
    this.model,
    this.version,
    this.language,
    this.detectLanguage,
    this.multilingual,
    this.alternatives,
    this.punctuate,
    this.profanityFilter,
    this.redact,
    this.numerals,
    this.search,
    this.replace,
    this.keywords,
    this.keywordBoost,
    this.diarize,
    this.diarizeVersion,
    this.detectEntities,
    this.sentiment,
    this.topics,
    this.customTopic,
    this.customTopicMode,
    this.summarize,
    this.summarizeAudioType,
    this.intents,
    this.customIntent,
    this.customIntentMode,
    this.paragraphs,
    this.utterances,
    this.utteranceWords,
    this.uttSplit,
    this.tag,
    this.tier,
    this.timeout,
    this.extra,
    this.mipOptOut,
    this.callback,
    this.callbackMethod,
    this.smartFormat,
    this.fmtMedium,
    this.multichannel,
    this.dictation,
    this.fillerWords,
    this.keyterm,
    this.measurements,
    this.encoding,
    this.sampleRate,
  });

  /// AI model used to process the audio. See [DeepgramSttModels] for
  /// well-known values; the server default is `base-general`.
  final String? model;

  /// Version of the AI model to use; defaults to `latest` on the server.
  final String? version;

  /// BCP-47 language tag of the primary spoken language; defaults to `en`.
  final String? language;

  /// Language detection (`detect_language`): `true` to detect the dominant
  /// language, or a list of candidate BCP-47 tags (also accepts a single
  /// tag as a string).
  final Object? detectLanguage;

  /// Multilingual transcription (`multilingual`).
  final bool? multilingual;

  /// Maximum number of alternative transcripts returned per channel
  /// (`alternatives`).
  final int? alternatives;

  /// Adds punctuation and capitalization (`punctuate`). Ignored when
  /// [smartFormat] is `true`, which already implies punctuation.
  final bool? punctuate;

  /// Masks profanity with the nearest non-profane word (`profanity_filter`).
  final bool? profanityFilter;

  /// Redaction (`redact`): `true`, one of the [DeepgramRedactions] policies
  /// (`pci`, `numbers`, `ssn`), or a list of policies.
  final Object? redact;

  /// Converts written numbers to numerals (`numerals`).
  final bool? numerals;

  /// Terms to search for (`search`); sent as repeated keys. Matches are
  /// reported per channel as search hits.
  final List<String>? search;

  /// Terms to find and replace in the transcript (`replace`); sent as
  /// repeated keys. Use the form `find:replace`.
  final List<String>? replace;

  /// Keywords to boost or suppress (`keywords`); sent as repeated keys.
  /// Each entry is `term` or `term:intensifier` (negative intensifiers
  /// suppress). Not supported by Nova-3; use [keyterm] there instead.
  final List<String>? keywords;

  /// Legacy keyword boost strength (`keyword_boost`).
  final String? keywordBoost;

  /// Recognizes speaker changes (`diarize`). Deprecated by Deepgram in favor
  /// of [diarizeVersion]; kept for backward compatibility.
  final bool? diarize;

  /// Diarization model version (`diarize_model`): `latest`, `v1`, or `v2`.
  /// Specifying it enables diarization; `diarize=true` is not needed.
  final String? diarizeVersion;

  /// Extracts key entities from the transcript (`detect_entities`).
  final bool? detectEntities;

  /// Recognizes sentiment throughout the transcript (`sentiment`).
  final bool? sentiment;

  /// Detects topics throughout the transcript (`topics`).
  final bool? topics;

  /// Custom topics to detect (`custom_topic`); sent as repeated keys.
  /// Up to 100 entries are accepted.
  final List<String>? customTopic;

  /// How custom topics are matched (`custom_topic_mode`): `strict` (only
  /// custom topics) or `extended` (custom plus model-detected topics).
  /// See [CustomTopicMode] for the allowed values.
  final String? customTopicMode;

  /// Summarization settings (`summarize`). See [SummarizeOptions].
  final SummarizeOptions? summarize;

  /// Kind of audio being summarized (`summarize_audio_type`), for example
  /// `phone_call` or `meeting`. Applied on top of [summarize]; setting it
  /// without [summarize] implies `summarize=v2`.
  final String? summarizeAudioType;

  /// Recognizes speaker intent throughout the transcript (`intents`).
  final bool? intents;

  /// Custom intents to detect (`custom_intent`); sent as repeated keys.
  final List<String>? customIntent;

  /// How custom intents are matched (`custom_intent_mode`): `strict` or
  /// `extended`. See [CustomIntentMode] for the allowed values.
  final String? customIntentMode;

  /// Splits the transcript into paragraphs (`paragraphs`).
  final bool? paragraphs;

  /// Segments speech into semantic utterances (`utterances`).
  final bool? utterances;

  /// Includes word detail inside each utterance (`utterance_words`).
  final bool? utteranceWords;

  /// Seconds of pause before an utterance boundary is declared
  /// (`utt_split`); the server default is 0.8.
  final double? uttSplit;

  /// Labels attached to the request for usage reporting (`tag`); sent as
  /// repeated keys.
  final List<String>? tag;

  /// Legacy model tier selector (`tier`).
  final String? tier;

  /// Maximum time in seconds Deepgram should spend on the request
  /// (`timeout`); fractional seconds are truncated.
  final Duration? timeout;

  /// Arbitrary key-value pairs echoed back in the response metadata
  /// (`extra`); each pair is sent as a repeated `key:value` entry.
  final Map<String, String>? extra;

  /// Opts the request out of the Model Improvement Program (`mip_opt_out`).
  final bool? mipOptOut;

  /// URL Deepgram should POST/PUT the asynchronous result to (`callback`).
  final String? callback;

  /// HTTP method for [callback] (`callback_method`): `POST` or `PUT`.
  final String? callbackMethod;

  /// Applies additional formatting for readability (`smart_format`).
  /// When `true`, [punctuate] is not sent because Smart Format already
  /// implies punctuation.
  final bool? smartFormat;

  /// Medium the transcript is formatted for (`smart_format` medium hint):
  /// `web` or `vr`. Only sent when [smartFormat] is `true`, in which case it
  /// is appended as a second `smart_format` key
  /// (`smart_format=true&smart_format=web`).
  final String? fmtMedium;

  /// Transcribes each audio channel independently (`multichannel`).
  final bool? multichannel;

  /// Dictation mode for formatting dictated speech (`dictation`).
  final bool? dictation;

  /// Transcribes filler words such as "uh" and "um" (`filler_words`).
  final bool? fillerWords;

  /// Key terms to boost (Nova-3 only, plain terms without intensifiers);
  /// sent as repeated keys. Prefer this over [keywords] on Nova-3.
  final List<String>? keyterm;

  /// Converts spoken measurements to abbreviations (`measurements`).
  final bool? measurements;

  /// Expected encoding of raw audio bytes (`encoding`), for example
  /// `linear16`. Only meaningful together with [sampleRate] and raw
  /// payloads.
  final String? encoding;

  /// Sample rate in Hz of raw audio (`sample_rate`); required when
  /// [encoding] is set.
  final int? sampleRate;

  /// Serializes these options into the exact query parameters sent to
  /// `POST /v1/listen`.
  ///
  /// Null fields are skipped, booleans become the strings `true`/`false`,
  /// and list fields render as repeated query keys. When [smartFormat] is
  /// `true`, `punctuate` is omitted entirely.
  Map<String, dynamic> toQuery() {
    final query = <String, dynamic>{};

    if (model != null) query['model'] = model;
    if (version != null) query['version'] = version;
    if (language != null) query['language'] = language;

    final detect = detectLanguage;
    if (detect is bool) {
      query['detect_language'] = _boolStr(detect);
    } else if (detect is String) {
      query['detect_language'] = detect;
    } else if (detect is List<dynamic>) {
      query['detect_language'] = detect;
    }

    if (multilingual != null) {
      query['multilingual'] = _boolStr(multilingual!);
    }
    if (alternatives != null) query['alternatives'] = alternatives;
    if (profanityFilter != null) {
      query['profanity_filter'] = _boolStr(profanityFilter!);
    }
    if (numerals != null) query['numerals'] = _boolStr(numerals!);

    if (search != null && search!.isNotEmpty) query['search'] = search;
    if (replace != null && replace!.isNotEmpty) query['replace'] = replace;
    if (keywords != null && keywords!.isNotEmpty) {
      query['keywords'] = keywords;
    }
    if (keywordBoost != null) query['keyword_boost'] = keywordBoost;

    final redactValue = redact;
    if (redactValue is bool) {
      query['redact'] = _boolStr(redactValue);
    } else if (redactValue is String) {
      query['redact'] = redactValue;
    } else if (redactValue is List<dynamic>) {
      query['redact'] = redactValue;
    }

    if (diarize != null) query['diarize'] = _boolStr(diarize!);
    if (diarizeVersion != null) query['diarize_model'] = diarizeVersion;
    if (detectEntities != null) {
      query['detect_entities'] = _boolStr(detectEntities!);
    }
    if (sentiment != null) query['sentiment'] = _boolStr(sentiment!);
    if (topics != null) query['topics'] = _boolStr(topics!);
    if (customTopic != null && customTopic!.isNotEmpty) {
      query['custom_topic'] = customTopic;
    }
    if (customTopicMode != null) {
      query['custom_topic_mode'] = customTopicMode;
    }

    _applySummarize(query);

    if (intents != null) query['intents'] = _boolStr(intents!);
    if (customIntent != null && customIntent!.isNotEmpty) {
      query['custom_intent'] = customIntent;
    }
    if (customIntentMode != null) {
      query['custom_intent_mode'] = customIntentMode;
    }
    if (paragraphs != null) query['paragraphs'] = _boolStr(paragraphs!);
    if (utterances != null) query['utterances'] = _boolStr(utterances!);
    if (utteranceWords != null) {
      query['utterance_words'] = _boolStr(utteranceWords!);
    }
    if (uttSplit != null) query['utt_split'] = uttSplit;
    if (tag != null && tag!.isNotEmpty) query['tag'] = tag;
    if (tier != null) query['tier'] = tier;
    if (timeout != null) query['timeout'] = timeout!.inSeconds;
    if (mipOptOut != null) query['mip_opt_out'] = _boolStr(mipOptOut!);
    if (callback != null) query['callback'] = callback;
    if (callbackMethod != null) query['callback_method'] = callbackMethod;
    if (multichannel != null) {
      query['multichannel'] = _boolStr(multichannel!);
    }
    if (dictation != null) query['dictation'] = _boolStr(dictation!);
    if (fillerWords != null) {
      query['filler_words'] = _boolStr(fillerWords!);
    }
    if (keyterm != null && keyterm!.isNotEmpty) query['keyterm'] = keyterm;
    if (measurements != null) {
      query['measurements'] = _boolStr(measurements!);
    }
    if (encoding != null) query['encoding'] = encoding;
    if (sampleRate != null) query['sample_rate'] = sampleRate;

    // Smart Format implies punctuation; never send punctuate alongside it.
    if (smartFormat == true) {
      query['smart_format'] = fmtMedium == null
          ? 'true'
          : <String>['true', fmtMedium!];
    } else if (smartFormat != null) {
      query['smart_format'] = _boolStr(smartFormat!);
    }
    if (punctuate != null && smartFormat != true) {
      query['punctuate'] = _boolStr(punctuate!);
    }

    if (extra != null && extra!.isNotEmpty) {
      query['extra'] = <String>[
        for (final entry in extra!.entries) '${entry.key}:${entry.value}',
      ];
    }

    return query;
  }

  /// Merges [summarize] (and the standalone [summarizeAudioType]) into
  /// [query].
  void _applySummarize(Map<String, dynamic> query) {
    final options = summarize;
    if (options != null) {
      options.toQuery().forEach((String key, dynamic value) {
        query[key] = value;
      });
      if (summarizeAudioType != null &&
          !query.containsKey('summarize_audio_type') &&
          (query['summarize'] == 'true' || query['summarize'] == 'v2')) {
        query['summarize_audio_type'] = summarizeAudioType!;
      }
    } else if (summarizeAudioType != null) {
      // An audio type on its own implies v2 summarization.
      query['summarize'] = 'v2';
      query['summarize_audio_type'] = summarizeAudioType!;
    }
  }
}

/// The style of summary produced by Deepgram's summarizer
/// (`summarize_mode`).
enum SummarizeMode {
  /// Conversational summary style (`conversational`).
  conversational,

  /// Paragraph-oriented summary (`paragraphs`).
  paragraphs,

  /// Bullet-point summary (`bullet_points`).
  bulletPoints,

  /// General-purpose summary (`general`).
  general,
}

/// Wire-string mapping for [SummarizeMode].
extension SummarizeModeWire on SummarizeMode {
  /// Returns the documented query value for this mode.
  String toQueryValue() {
    switch (this) {
      case SummarizeMode.conversational:
        return 'conversational';
      case SummarizeMode.paragraphs:
        return 'paragraphs';
      case SummarizeMode.bulletPoints:
        return 'bullet_points';
      case SummarizeMode.general:
        return 'general';
    }
  }
}

/// The kind of audio being summarized (`summarize_audio_type`).
enum SummarizeAudioType {
  /// Telephone call audio (`phone_call`).
  phoneCall,

  /// Multi-participant meeting audio (`meeting`).
  meeting,

  /// Broadcast audio (`broadcast`).
  broadcast,

  /// Podcast audio (`podcast`).
  podcast,

  /// Dictated audio (`dictation`).
  dictation,
}

/// Wire-string mapping for [SummarizeAudioType].
extension SummarizeAudioTypeWire on SummarizeAudioType {
  /// Returns the documented query value for this audio type.
  String toQueryValue() {
    switch (this) {
      case SummarizeAudioType.phoneCall:
        return 'phone_call';
      case SummarizeAudioType.meeting:
        return 'meeting';
      case SummarizeAudioType.broadcast:
        return 'broadcast';
      case SummarizeAudioType.podcast:
        return 'podcast';
      case SummarizeAudioType.dictation:
        return 'dictation';
    }
  }
}

/// Options for Deepgram's summarization feature (`summarize`).
///
/// Wire formats produced:
///
/// * v1: `summarize=true`
/// * v2: `summarize=v2` — the only form that carries [mode] and [audioType]
///
/// Whenever [mode] or [audioType] is set, or [v2] is `true`, the `v2` string
/// form is used; otherwise a plain boolean is sent.
class SummarizeOptions {
  /// Creates summarization options.
  const SummarizeOptions({
    this.enabled = true,
    this.model,
    this.mode,
    this.audioType,
    this.v2 = false,
  });

  /// Serializes these options to query parameters.
  Map<String, dynamic> toQuery() {
    final query = <String, dynamic>{};
    if (!enabled) {
      query['summarize'] = 'false';
      return query;
    }
    final useV2 = v2 || mode != null || audioType != null;
    query['summarize'] = useV2 ? 'v2' : 'true';
    if (model != null) query['summarize_model'] = model;
    if (mode != null) query['summarize_mode'] = mode!.toQueryValue();
    if (audioType != null) {
      query['summarize_audio_type'] = audioType!.toQueryValue();
    }
    return query;
  }

  /// Whether summarization is enabled.
  final bool enabled;

  /// Optional summarization model name (sent as `summarize_model`).
  final String? model;

  /// The style of summary to generate.
  final SummarizeMode? mode;

  /// The kind of audio being summarized, which tunes the summary.
  final SummarizeAudioType? audioType;

  /// Forces the `summarize=v2` wire form.
  final bool v2;
}

/// Allowed values for the `custom_topic_mode` parameter.
class CustomTopicMode {
  const CustomTopicMode._();

  /// Only topics submitted via `custom_topic` are returned.
  static const strict = 'strict';

  /// Model-detected topics are returned in addition to the custom ones.
  static const extended = 'extended';
}

/// Allowed values for the `custom_intent_mode` parameter.
class CustomIntentMode {
  const CustomIntentMode._();

  /// Only intents submitted via `custom_intent` are returned.
  static const strict = 'strict';

  /// Model-detected intents are returned in addition to the custom ones.
  static const extended = 'extended';
}

/// Well-known Deepgram speech-to-text model identifiers accepted by the
/// `model` parameter.
class DeepgramSttModels {
  const DeepgramSttModels._();

  /// Nova 3 — latest-generation general-purpose model.
  static const nova3 = 'nova-3';

  /// Nova 2 — general-purpose model.
  static const nova2 = 'nova-2';

  /// Nova 2, tuned for medical vocabulary.
  static const nova2Medical = 'nova-2-medical';

  /// Nova 2, tuned for phone-call audio.
  static const nova2Phonecall = 'nova-2-phonecall';

  /// Nova 2, tuned for meetings.
  static const nova2Meeting = 'nova-2-meeting';

  /// Nova 2 general.
  static const nova2General = 'nova-2-general';

  /// Enhanced — previous-generation model.
  static const enhanced = 'enhanced';

  /// Base — legacy model.
  static const base = 'base';

  /// Whisper large, hosted by Deepgram.
  static const whisperLarge = 'whisper-large';

  /// Flux general English (used with the `/v2/listen` API).
  static const fluxGeneralEn = 'flux-general-en';

  /// Flux general multilingual (used with the `/v2/listen` API).
  static const fluxGeneralMulti = 'flux-general-multi';
}

/// Redaction policies accepted by the `redact` parameter.
class DeepgramRedactions {
  const DeepgramRedactions._();

  /// Payment card information.
  static const pci = 'pci';

  /// Spoken numbers.
  static const numbers = 'numbers';

  /// US social security numbers.
  static const ssn = 'ssn';
}

/// Serializes a bool the way Deepgram expects query booleans.
String _boolStr(bool value) => value ? 'true' : 'false';
