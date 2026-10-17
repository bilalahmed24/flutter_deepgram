/// REST text-to-speech: `POST /v1/speak` (Aura / Aura-2 voices) and
/// `POST /v2/speak` (Flux TTS batch).
///
/// Re-exports [SpeakOptions] and [FluxTtsOptions] so that importers of
/// this library can construct the options its methods accept.
library;

import '../core/deepgram_config.dart';
import '../core/deepgram_exception.dart';
import '../core/http/http_engine.dart';
import 'speak_options.dart';

export 'speak_options.dart';

/// Synthesizes speech from text over the Deepgram REST API.
///
/// ```dart
/// final bytes = await deepgram.tts.speak(
///   'Hello, welcome to Deepgram!',
///   options: const SpeakOptions(model: DeepgramVoices.aura2ThaliaEn),
/// );
/// ```
///
/// Failures surface as typed [DeepgramException] subtypes; retries,
/// backoff, and cancellation are handled by the shared HTTP engine.
class TtsClient {
  /// Creates a TTS client bound to the shared [http] engine.
  TtsClient({required HttpEngine http, required DeepgramConfig config})
    : _http = http;

  final HttpEngine _http;

  /// The maximum number of characters accepted per request by the speak
  /// endpoints (Aura-2 and Aura-1 models). The server rejects longer text
  /// with a 413; this client rejects it up front with a
  /// [DeepgramBadRequestException].
  static const int maxTextLength = 2000;

  /// Synthesizes speech with an Aura or Aura-2 voice (`POST /v1/speak`)
  /// and returns the complete audio bytes.
  ///
  /// Use [speakStream] instead when you want to start playback while the
  /// audio is still downloading.
  Future<List<int>> speak(
    String text, {
    SpeakOptions? options,
    HttpCancelToken? cancelToken,
  }) {
    _validateText(text);
    return _http.postForBytes(
      '/v1/speak',
      body: <String, dynamic>{'text': text},
      query: options?.toQuery(),
      cancelToken: cancelToken,
    );
  }

  /// Synthesizes speech with an Aura or Aura-2 voice and returns the
  /// response body as a byte stream, for progressive playback while the
  /// audio downloads.
  Future<Stream<List<int>>> speakStream(
    String text, {
    SpeakOptions? options,
    HttpCancelToken? cancelToken,
  }) {
    _validateText(text);
    return _http.postForByteStream(
      '/v1/speak',
      body: <String, dynamic>{'text': text},
      query: options?.toQuery(),
      cancelToken: cancelToken,
    );
  }

  /// Synthesizes speech with a Flux TTS voice (`POST /v2/speak`) and
  /// returns the complete audio bytes.
  Future<List<int>> speakFlux(
    String text, {
    FluxTtsOptions? options,
    HttpCancelToken? cancelToken,
  }) {
    _validateText(text);
    return _http.postForBytes(
      '/v2/speak',
      body: <String, dynamic>{'text': text},
      query: options?.toQuery(),
      cancelToken: cancelToken,
    );
  }

  /// Synthesizes speech with a Flux TTS voice and returns the response
  /// body as a byte stream, for progressive playback while the audio
  /// downloads.
  Future<Stream<List<int>>> speakFluxStream(
    String text, {
    FluxTtsOptions? options,
    HttpCancelToken? cancelToken,
  }) {
    _validateText(text);
    return _http.postForByteStream(
      '/v2/speak',
      body: <String, dynamic>{'text': text},
      query: options?.toQuery(),
      cancelToken: cancelToken,
    );
  }

  /// Rejects text longer than [maxTextLength] before hitting the network.
  ///
  /// `String.length` counts UTF-16 code units, which matches the server's
  /// character count for Basic Multilingual Plane text (every Aura and
  /// Aura-2 language); astral code points (e.g. some emoji) count as two.
  void _validateText(String text) {
    if (text.length > maxTextLength) {
      throw DeepgramBadRequestException(
        'Text exceeds the $maxTextLength character limit for the speak '
        'endpoints (got ${text.length} characters). Split the text into '
        'multiple requests.',
      );
    }
  }
}
