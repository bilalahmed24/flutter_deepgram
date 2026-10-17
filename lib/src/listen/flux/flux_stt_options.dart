/// Options for turn-based Flux speech-to-text over the `/v2/listen`
/// WebSocket.
///
/// See the API reference:
/// https://developers.deepgram.com/reference/speech-to-text/listen-flux
library;

import '../live/live_options.dart' show LiveEncoding;

/// Query parameters for a `/v2/listen` Flux transcription session.
class FluxSttOptions {
  /// Creates a Flux options bundle.
  const FluxSttOptions({
    this.model = 'flux-general-en',
    this.languageHints,
    this.encoding,
    this.sampleRate,
    this.eotThreshold,
    this.eagerEotThreshold,
    this.eotTimeoutMs,
    this.keyterms,
    this.numerals,
    this.tag,
    this.extra,
    this.mipOptOut,
  });

  /// Flux model: `flux-general-en` (English) or `flux-general-multi`
  /// (multilingual). Defaults to `flux-general-en`.
  final String model;

  /// BCP-47 language hints biasing language detection. Only valid with the
  /// `flux-general-multi` model. Sent as repeated `language_hint` query keys.
  final List<String>? languageHints;

  /// Required when streaming raw (uncontainerized) audio, together with
  /// [sampleRate]. Flux supports a subset of [LiveEncoding]:
  /// `linear16`, `linear32`, `mulaw`, `alaw`, `opus`, and `ogg-opus`.
  final LiveEncoding? encoding;

  /// Sample rate in Hz. Required together with [encoding].
  final int? sampleRate;

  /// End-of-turn confidence threshold, between `0.5` and `1.0`.
  /// When `null` the server default (`0.7`) applies.
  final double? eotThreshold;

  /// Eager end-of-turn threshold. When set, `EagerEndOfTurn` and
  /// `TurnResumed` events are emitted, letting an agent start preparing a
  /// reply before the turn is fully settled.
  final double? eagerEotThreshold;

  /// Milliseconds of speech after which the turn is force-ended. When
  /// `null` the server default (5000 ms) applies.
  final int? eotTimeoutMs;

  /// Key term prompting. Sent as repeated `keyterm` query keys; plain terms
  /// only (no weights or intensifiers).
  final List<String>? keyterms;

  /// Convert written numbers to numerals.
  final bool? numerals;

  /// Tags for usage reporting. Sent as repeated `tag` query keys.
  final List<String>? tag;

  /// Arbitrary key-value pairs echoed in API responses for downstream
  /// processing.
  final Map<String, String>? extra;

  /// Opt out of the Deepgram Model Improvement Program.
  final bool? mipOptOut;

  /// Builds the query parameters for the WebSocket URI.
  ///
  /// Null fields are omitted, booleans render as `true`/`false`, and list
  /// fields ([languageHints], [keyterms], [tag]) render as repeated query
  /// keys.
  Map<String, dynamic> toQuery() {
    final query = <String, dynamic>{'model': model};
    if (languageHints != null && languageHints!.isNotEmpty) {
      query['language_hint'] = languageHints;
    }
    if (encoding != null) {
      query['encoding'] = encoding!.wireName;
    }
    if (sampleRate != null) {
      query['sample_rate'] = sampleRate.toString();
    }
    if (eotThreshold != null) {
      query['eot_threshold'] = eotThreshold.toString();
    }
    if (eagerEotThreshold != null) {
      query['eager_eot_threshold'] = eagerEotThreshold.toString();
    }
    if (eotTimeoutMs != null) {
      query['eot_timeout_ms'] = eotTimeoutMs.toString();
    }
    if (keyterms != null && keyterms!.isNotEmpty) {
      query['keyterm'] = keyterms;
    }
    if (numerals != null) {
      query['numerals'] = numerals! ? 'true' : 'false';
    }
    if (tag != null && tag!.isNotEmpty) {
      query['tag'] = tag;
    }
    if (mipOptOut != null) {
      query['mip_opt_out'] = mipOptOut! ? 'true' : 'false';
    }
    if (extra != null) {
      query.addAll(extra!);
    }
    return query;
  }
}

/// A `Configure` message for the Flux session: mid-stream updates of turn
/// thresholds, keyterms, language hints, and numeral formatting.
class FluxConfigure {
  /// Creates a configure message. Every field is optional; omitted (null)
  /// fields are not sent and keep their current server-side value.
  const FluxConfigure({
    this.eotThreshold,
    this.eagerEotThreshold,
    this.eotTimeoutMs,
    this.keyterms,
    this.languageHints,
    this.numerals,
  });

  /// Updated end-of-turn confidence threshold (`0.5`–`1.0`).
  final double? eotThreshold;

  /// Updated eager end-of-turn threshold.
  final double? eagerEotThreshold;

  /// Updated end-of-turn timeout in milliseconds.
  final int? eotTimeoutMs;

  /// Replaces the current keyterms. An empty list clears them.
  final List<String>? keyterms;

  /// Replaces the current language hints (only valid with
  /// `flux-general-multi`). An empty list clears them.
  final List<String>? languageHints;

  /// Toggles numeral formatting for transcripts emitted after this update.
  final bool? numerals;

  /// Builds the JSON payload of the `Configure` message.
  ///
  /// Null fields are omitted; the `thresholds` object is only included when
  /// at least one threshold is present.
  Map<String, dynamic> toJson() {
    final payload = <String, dynamic>{'type': 'Configure'};
    final thresholds = <String, dynamic>{};
    if (eotThreshold != null) {
      thresholds['eot_threshold'] = eotThreshold;
    }
    if (eagerEotThreshold != null) {
      thresholds['eager_eot_threshold'] = eagerEotThreshold;
    }
    if (eotTimeoutMs != null) {
      thresholds['eot_timeout_ms'] = eotTimeoutMs;
    }
    if (thresholds.isNotEmpty) {
      payload['thresholds'] = thresholds;
    }
    if (keyterms != null) {
      payload['keyterms'] = keyterms;
    }
    if (languageHints != null) {
      payload['language_hints'] = languageHints;
    }
    if (numerals != null) {
      payload['numerals'] = numerals;
    }
    return payload;
  }
}
