/// Options for live (streaming) speech-to-text over the `/v1/listen`
/// WebSocket.
///
/// See the API reference:
/// https://developers.deepgram.com/reference/speech-to-text/listen-streaming
library;

/// Audio encodings accepted by Deepgram's streaming endpoints.
///
/// The value is reused by both `/v1/listen` and the turn-based `/v2/listen`
/// Flux API (which supports a subset of these encodings).
enum LiveEncoding {
  /// 16-bit little-endian signed PCM. Requires a sample rate.
  linear16('linear16'),

  /// 32-bit little-endian signed PCM. Requires a sample rate.
  linear32('linear32'),

  /// Free Lossless Audio Codec (FLAC).
  flac('flac'),

  /// G.711 A-law companded PCM. Requires a sample rate.
  alaw('alaw'),

  /// G.711 μ-law companded PCM. Requires a sample rate.
  mulaw('mulaw'),

  /// Adaptive Multi-Rate narrowband (8 kHz).
  amrNb('amr-nb'),

  /// Adaptive Multi-Rate wideband (16 kHz).
  amrWb('amr-wb'),

  /// Raw Opus frames.
  opus('opus'),

  /// Ogg-containerized Opus.
  oggOpus('ogg-opus'),

  /// Speex narrowband.
  speex('speex'),

  /// ITU-T G.729.
  g729('g729');

  const LiveEncoding(this.wireName);

  /// The value sent on the wire as the `encoding` query parameter.
  final String wireName;
}

/// Query parameters for a `/v1/listen` live transcription session.
class LiveTranscriptionOptions {
  /// Creates a live transcription options bundle.
  const LiveTranscriptionOptions({
    this.model = 'nova-3',
    this.version,
    this.language = 'en-US',
    this.encoding,
    this.sampleRate,
    this.channels,
    this.multichannel,
    this.interimResults = true,
    this.endpointingMs,
    this.endpointingEnabled,
    this.utteranceEndMs,
    this.vadEvents,
    this.punctuate,
    this.smartFormat,
    this.numerals,
    this.profanityFilter,
    this.redact,
    this.diarize,
    this.diarizeModel,
    this.keywords,
    this.keyterm,
    this.replace,
    this.search,
    this.tag,
    this.extra,
    this.mipOptOut,
    this.detectEntities,
    this.dictation,
  });

  /// AI model used for the transcription. Defaults to `nova-3`.
  final String model;

  /// Model version; when `null` the server default (`latest`) applies.
  final String? version;

  /// BCP-47 language tag. Defaults to `en-US`.
  final String language;

  /// Required when streaming raw (uncontainerized) audio, together with
  /// [sampleRate]. Containerized audio (wav, mp3, ogg, ...) must omit it.
  final LiveEncoding? encoding;

  /// Sample rate in Hz. Required together with [encoding].
  final int? sampleRate;

  /// Number of audio channels in the raw stream. Streaming-only hint; it is
  /// not forwarded to the pre-recorded API during gap recovery.
  final int? channels;

  /// Transcribe each audio channel independently.
  final bool? multichannel;

  /// Emit ongoing partial results as more audio arrives. Defaults to `true`.
  final bool interimResults;

  /// Endpointing silence window in milliseconds.
  ///
  /// * `null` (default): nothing is sent; the server default (10 ms) applies.
  /// * A positive value: sent as `endpointing=<ms>`.
  /// * Zero (or a negative value), or [endpointingEnabled] set to `false`:
  ///   endpointing is disabled with `endpointing=false`.
  final int? endpointingMs;

  /// Explicitly enables or disables endpointing. `false` always wins over
  /// [endpointingMs]; `true` alone sends nothing (the server default applies).
  final bool? endpointingEnabled;

  /// Milliseconds of silence before an `UtteranceEnd` message is emitted
  /// (requires `vad_events`). `null` keeps the server default.
  final int? utteranceEndMs;

  /// Request `SpeechStarted` events (voice activity detection).
  final bool? vadEvents;

  /// Add punctuation and capitalization. Redundant when [smartFormat] is
  /// `true` (smart formatting includes punctuation), so it is omitted then.
  final bool? punctuate;

  /// Apply additional formatting (punctuation, capitalization, numbers,
  /// dates, ...) to improve readability.
  final bool? smartFormat;

  /// Convert written numbers to numerals.
  final bool? numerals;

  /// Filter profanity from the transcript.
  final bool? profanityFilter;

  /// Redaction: `true`, a policy string (`pci`, `numbers`,
  /// `aggressive_numbers`, `ssn`), or a list of policies (sent as repeated
  /// `redact` keys).
  final Object? redact;

  /// Deprecated: recognize speaker changes. Prefer [diarizeModel].
  final bool? diarize;

  /// Diarization model (`latest` or `v1`). Specifying it enables diarization.
  final String? diarizeModel;

  /// Keyword boosting (not supported by Nova-3 — use [keyterm] instead).
  final List<String>? keywords;

  /// Nova-3 key term prompting. Sent as repeated `keyterm` query keys.
  final List<String>? keyterm;

  /// `find:replacement` pairs. Sent as repeated `replace` query keys.
  final List<String>? replace;

  /// Terms to search for; matches are returned with [replace]-style
  /// highlighting. Sent as repeated `search` query keys.
  final List<String>? search;

  /// Tags for usage reporting. Sent as repeated `tag` query keys.
  final List<String>? tag;

  /// Arbitrary key-value pairs echoed in API responses for downstream
  /// processing.
  final Map<String, String>? extra;

  /// Opt out of the Deepgram Model Improvement Program.
  final bool? mipOptOut;

  /// Extract entities from final results (streaming detection).
  final bool? detectEntities;

  /// Dictation mode for controlling formatting of dictated speech.
  final bool? dictation;

  /// Builds the query parameters for the WebSocket URI.
  ///
  /// Null fields are omitted, booleans render as `true`/`false`, and list
  /// fields ([keywords], [keyterm], [replace], [search], [tag]) render as
  /// repeated query keys.
  Map<String, dynamic> toQuery() {
    final query = <String, dynamic>{
      'model': model,
      'language': language,
      'interim_results': interimResults ? 'true' : 'false',
    };
    if (version != null) {
      query['version'] = version;
    }
    if (encoding != null) {
      query['encoding'] = encoding!.wireName;
    }
    if (sampleRate != null) {
      query['sample_rate'] = sampleRate.toString();
    }
    if (channels != null) {
      query['channels'] = channels.toString();
    }
    if (multichannel != null) {
      query['multichannel'] = multichannel! ? 'true' : 'false';
    }
    if (endpointingEnabled == false ||
        (endpointingMs != null && endpointingMs! <= 0)) {
      query['endpointing'] = 'false';
    } else if (endpointingMs != null) {
      query['endpointing'] = endpointingMs.toString();
    }
    if (utteranceEndMs != null) {
      query['utterance_end_ms'] = utteranceEndMs.toString();
    }
    if (vadEvents != null) {
      query['vad_events'] = vadEvents! ? 'true' : 'false';
    }
    if (smartFormat != null) {
      query['smart_format'] = smartFormat! ? 'true' : 'false';
    }
    // Punctuation is implied by smart formatting; sending both is redundant.
    if (punctuate != null && smartFormat != true) {
      query['punctuate'] = punctuate! ? 'true' : 'false';
    }
    if (numerals != null) {
      query['numerals'] = numerals! ? 'true' : 'false';
    }
    if (profanityFilter != null) {
      query['profanity_filter'] = profanityFilter! ? 'true' : 'false';
    }
    final redactValue = redact;
    if (redactValue is bool) {
      if (redactValue) {
        query['redact'] = 'true';
      }
    } else if (redactValue is String) {
      if (redactValue.isNotEmpty) {
        query['redact'] = redactValue;
      }
    } else if (redactValue is List) {
      final policies = <String>[
        for (final item in redactValue)
          if (item != null) item.toString(),
      ];
      if (policies.isNotEmpty) {
        query['redact'] = policies;
      }
    }
    if (diarize != null) {
      query['diarize'] = diarize! ? 'true' : 'false';
    }
    if (diarizeModel != null) {
      query['diarize_model'] = diarizeModel;
    }
    if (keywords != null && keywords!.isNotEmpty) {
      query['keywords'] = keywords;
    }
    if (keyterm != null && keyterm!.isNotEmpty) {
      query['keyterm'] = keyterm;
    }
    if (replace != null && replace!.isNotEmpty) {
      query['replace'] = replace;
    }
    if (search != null && search!.isNotEmpty) {
      query['search'] = search;
    }
    if (tag != null && tag!.isNotEmpty) {
      query['tag'] = tag;
    }
    if (mipOptOut != null) {
      query['mip_opt_out'] = mipOptOut! ? 'true' : 'false';
    }
    if (detectEntities != null) {
      query['detect_entities'] = detectEntities! ? 'true' : 'false';
    }
    if (dictation != null) {
      query['dictation'] = dictation! ? 'true' : 'false';
    }
    if (extra != null) {
      query.addAll(extra!);
    }
    return query;
  }
}

/// Gap-recovery behaviour for a live transcription session.
///
/// While the WebSocket is down, the live client's `sendAudio` buffers audio
/// up to [maxBufferBytes]. On reconnection, small gaps are flushed straight
/// into the new socket (before live audio continues), while large gaps are
/// recovered in parallel through the pre-recorded HTTPS API — anchored at the
/// disconnect instant so the recovered transcript keeps its true position in
/// the timeline.
class LiveGapRecoveryOptions {
  /// Creates a gap-recovery options bundle.
  const LiveGapRecoveryOptions({
    this.enabled = true,
    this.maxLiveFlushBytes = 320000,
    this.maxBufferBytes = 5242880,
    this.audioContentType,
    this.maxCloseWait = const Duration(seconds: 10),
  });

  /// Whether disconnect audio buffering and gap recovery are enabled.
  final bool enabled;

  /// Gaps up to this many bytes (~10 s of 16 kHz 16-bit mono) are flushed
  /// directly into the reconnected socket instead of paying for an HTTPS
  /// recovery round trip.
  final int maxLiveFlushBytes;

  /// Cap on the audio buffered while disconnected. When full, newly captured
  /// audio is dropped (with a logged warning) and the transcript for that
  /// part of the outage window is lost.
  final int maxBufferBytes;

  /// Content type used for HTTPS gap recovery uploads. When `null` it is
  /// derived automatically: `audio/raw;rate=<sampleRate>` when
  /// [LiveTranscriptionOptions.encoding] and
  /// [LiveTranscriptionOptions.sampleRate] are set, `audio/wav` otherwise.
  final String? audioContentType;

  /// How long a graceful [DeepgramLiveClient.close] waits for an in-flight
  /// HTTPS gap recovery to finish so its recovered transcripts are still
  /// delivered. Mirrors the production service this pattern was ported from.
  final Duration maxCloseWait;
}
