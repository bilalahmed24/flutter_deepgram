/// Options for Deepgram text-to-speech: `/v1/speak` (Aura and Aura-2
/// voices) and `/v2/speak` (Flux TTS).
library;

/// Audio encodings accepted by the Deepgram TTS APIs.
enum TtsEncoding {
  /// Uncompressed 16-bit PCM — commonly used for telephony and audio
  /// processing. One of the three streaming-compatible encodings.
  linear16('linear16'),

  /// μ-law companded audio — commonly used in US telephony. One of the
  /// three streaming-compatible encodings.
  mulaw('mulaw'),

  /// A-law companded audio — commonly used in international telephony.
  /// One of the three streaming-compatible encodings.
  alaw('alaw'),

  /// Opus, delivered inside an Ogg container on the batch endpoint.
  /// REST-only.
  opus('opus'),

  /// Free Lossless Audio Codec. REST-only.
  flac('flac'),

  /// Advanced Audio Coding. REST-only.
  aac('aac'),

  /// MP3 — the batch endpoint's default encoding. REST-only.
  mp3('mp3');

  /// Creates an encoding constant.
  const TtsEncoding(this.wireName);

  /// The value sent on the wire (query-parameter value).
  final String wireName;
}

/// Container (file wrapper) for batch text-to-speech output.
enum TtsContainer {
  /// No container — raw encoded bytes.
  none('none'),

  /// WAV container — the default for linear16, mulaw, and alaw output.
  wav('wav'),

  /// Ogg container — the default for Opus output.
  ogg('ogg');

  /// Creates a container constant.
  const TtsContainer(this.wireName);

  /// The value sent on the wire (query-parameter value).
  final String wireName;
}

/// HTTP method by which a text-to-speech callback request is delivered.
enum TtsCallbackMethod {
  /// HTTP POST — the default.
  post('POST'),

  /// HTTP PUT.
  put('PUT');

  /// Creates a callback-method constant.
  const TtsCallbackMethod(this.wireName);

  /// The value sent on the wire (query-parameter value).
  final String wireName;
}

/// Options for `POST /v1/speak` and `WSS /v1/speak` — Aura and Aura-2
/// voices.
///
/// Every field is optional; `null` means "let the server decide". The
/// server-side defaults are: model `aura-asteria-en`, encoding `mp3`
/// (REST) or `linear16` (WebSocket), container `wav`, `sample_rate` 24000,
/// `bit_rate` 48000, and `speed` 1.
///
/// The same object serves both transports; fields that only make sense on
/// REST ([container], [bitRate], [callback], [callbackMethod], [timeout])
/// are ignored by the WebSocket endpoint.
class SpeakOptions {
  /// Creates options for `/v1/speak`.
  const SpeakOptions({
    this.model,
    this.encoding,
    this.container,
    this.sampleRate,
    this.bitRate,
    this.speed,
    this.tag,
    this.mipOptOut,
    this.timeout,
    this.callback,
    this.callbackMethod,
  });

  /// TTS model (voice) ID — wire key `model`. The server default is
  /// `aura-asteria-en`; see the `DeepgramVoices` catalog in voices.dart
  /// for every accepted value.
  final String? model;

  /// Output audio encoding — wire key `encoding`. The WebSocket accepts
  /// only [TtsEncoding.linear16], [TtsEncoding.mulaw], and
  /// [TtsEncoding.alaw]; the REST endpoint additionally accepts opus,
  /// flac, aac, and mp3.
  final TtsEncoding? encoding;

  /// Output file wrapper — wire key `container` (REST only).
  /// [TtsContainer.none] returns raw encoded bytes.
  final TtsContainer? container;

  /// Output sample rate in Hz — wire key `sample_rate`. One of 8000,
  /// 16000, 24000 (the default), 32000, or 48000; availability depends on
  /// the encoding.
  final int? sampleRate;

  /// Output bitrate in bits per second — wire key `bit_rate` (REST only).
  /// The default is 48000; valid ranges depend on the encoding.
  final int? bitRate;

  /// Speaking-rate multiplier — wire key `speed`. Aura-2 accepts 0.7
  /// through 1.5 (default 1); not yet supported in all languages.
  final double? speed;

  /// Usage-reporting tags — rendered as repeated `tag=` query keys.
  final List<String>? tag;

  /// Opts the request out of the Deepgram Model Improvement Program —
  /// wire key `mip_opt_out`, rendered as `'true'`/`'false'`. Review the
  /// pricing impacts before enabling this.
  final bool? mipOptOut;

  /// Optional processing timeout — wire key `timeout`, serialized as whole
  /// milliseconds.
  final Duration? timeout;

  /// URL that receives the synthesized audio asynchronously (REST only) —
  /// wire key `callback`.
  final String? callback;

  /// HTTP method for callback delivery (REST only) — wire key
  /// `callback_method`. Defaults to POST server-side.
  final TtsCallbackMethod? callbackMethod;

  /// Serializes these options into query parameters, omitting null
  /// fields.
  ///
  /// Booleans are rendered as the strings `'true'`/`'false'`; [tag] is
  /// rendered as repeated `tag=` keys (the query builder expands
  /// iterables); [timeout] is rendered as whole milliseconds.
  Map<String, dynamic> toQuery() {
    final effectiveModel = model;
    final effectiveEncoding = encoding;
    final effectiveContainer = container;
    final effectiveTags = tag;
    final effectiveMipOptOut = mipOptOut;
    final effectiveTimeout = timeout;
    final effectiveCallback = callback;
    final effectiveCallbackMethod = callbackMethod;
    return <String, dynamic>{
      'model': ?effectiveModel,
      if (effectiveEncoding != null) 'encoding': effectiveEncoding.wireName,
      if (effectiveContainer != null) 'container': effectiveContainer.wireName,
      if (sampleRate != null) 'sample_rate': sampleRate,
      if (bitRate != null) 'bit_rate': bitRate,
      if (speed != null) 'speed': speed,
      if (effectiveTags != null && effectiveTags.isNotEmpty)
        'tag': effectiveTags,
      if (effectiveMipOptOut != null)
        'mip_opt_out': effectiveMipOptOut ? 'true' : 'false',
      if (effectiveTimeout != null) 'timeout': effectiveTimeout.inMilliseconds,
      'callback': ?effectiveCallback,
      if (effectiveCallbackMethod != null)
        'callback_method': effectiveCallbackMethod.wireName,
    };
  }
}

/// Options for `WSS /v2/speak` (Flux TTS streaming) and `POST /v2/speak`
/// (Flux TTS batch) — model strings follow the format
/// `flux-{voice}-{language}`, e.g. `flux-alexis-en`.
class FluxTtsOptions {
  /// Creates options for `/v2/speak`. [model] is required; see the
  /// `DeepgramVoices.flux` catalog in voices.dart for every available
  /// Flux voice.
  const FluxTtsOptions({
    required this.model,
    this.encoding = TtsEncoding.linear16,
    this.sampleRate,
    this.expressivity,
    this.tag,
    this.mipOptOut,
    this.timeout,
  });

  /// The Flux TTS model, in the format `flux-{voice}-{language}` — for
  /// example `flux-alexis-en`.
  final String model;

  /// Output audio encoding. The streaming WebSocket emits raw
  /// (non-containerized) audio, so only [TtsEncoding.linear16],
  /// [TtsEncoding.mulaw], and [TtsEncoding.alaw] are accepted there; the
  /// batch endpoint accepts every [TtsEncoding].
  final TtsEncoding encoding;

  /// Output sample rate in Hz — wire key `sample_rate`. With linear16:
  /// 8000, 16000, 24000 (the default), 32000, 44100, or 48000; with
  /// mulaw/alaw: 8000 or 16000.
  final int? sampleRate;

  /// Expressive register on a calm-to-animated axis — wire key
  /// `expressivity`. Whole numbers from -2 to 2; `0` (the default) is the
  /// voice's tuned baseline.
  final int? expressivity;

  /// Usage-reporting tags — rendered as repeated `tag=` query keys.
  final List<String>? tag;

  /// Opts the session out of the Deepgram Model Improvement Program —
  /// wire key `mip_opt_out`, rendered as `'true'`/`'false'`.
  final bool? mipOptOut;

  /// Optional processing timeout — wire key `timeout`, serialized as whole
  /// milliseconds.
  final Duration? timeout;

  /// Serializes these options into query parameters, omitting null
  /// fields (the model and encoding are always present).
  Map<String, dynamic> toQuery() {
    final effectiveTags = tag;
    final effectiveMipOptOut = mipOptOut;
    final effectiveTimeout = timeout;
    return <String, dynamic>{
      'model': model,
      'encoding': encoding.wireName,
      if (sampleRate != null) 'sample_rate': sampleRate,
      if (expressivity != null) 'expressivity': expressivity,
      if (effectiveTags != null && effectiveTags.isNotEmpty)
        'tag': effectiveTags,
      if (effectiveMipOptOut != null)
        'mip_opt_out': effectiveMipOptOut ? 'true' : 'false',
      if (effectiveTimeout != null) 'timeout': effectiveTimeout.inMilliseconds,
    };
  }
}
