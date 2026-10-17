/// REST client for Deepgram's pre-recorded (batch) speech-to-text API,
/// `POST https://api.deepgram.com/v1/listen`.
library;

import '../../core/deepgram_config.dart';
import '../../core/deepgram_exception.dart';
import '../../core/http/http_engine.dart';
import '../stt_models.dart';
import 'prerecorded_options.dart';

/// Transcribes audio that has already been recorded.
///
/// Two request styles are supported:
///
/// * [transcribeFromUrl] — Deepgram fetches publicly reachable media (the
///   `url=` query-parameter form).
/// * [transcribeBytes] — raw audio/video bytes are uploaded directly,
///   including raw PCM with an `audio/raw;rate=16000` content type.
///
/// There is deliberately no `transcribeFromFile` method: reading files would
/// require `dart:io`, which is unavailable on the web. Read the file into
/// bytes and pass them to [transcribeBytes] instead:
///
/// ```dart
/// final bytes = File('audio.wav').readAsBytesSync();
/// final result = await deepgram.prerecorded.transcribeBytes(
///   bytes,
///   contentType: 'audio/wav',
///   options: const PrerecordedOptions(smartFormat: true),
/// );
/// ```
class PrerecordedClient {
  /// Creates a pre-recorded transcription client.
  PrerecordedClient({required HttpEngine http, required DeepgramConfig config})
    : _http = http,
      _config = config;

  static const String _listenPath = '/v1/listen';

  final HttpEngine _http;
  final DeepgramConfig _config;

  /// Transcribes audio hosted at a public [url].
  ///
  /// The request is sent with an empty body and the media URL carried in the
  /// `url` query parameter. [options] covers every documented `POST
  /// /v1/listen` query parameter, and [cancelToken] cancels the in-flight
  /// request.
  ///
  /// Throws [DeepgramBadRequestException] when [url] is empty; network,
  /// authentication, quota, and server failures are thrown as the
  /// corresponding [DeepgramException] subtypes by the shared HTTP engine.
  Future<PrerecordedTranscriptionResult> transcribeFromUrl(
    String url, {
    PrerecordedOptions? options,
    HttpCancelToken? cancelToken,
  }) async {
    if (url.isEmpty) {
      throw const DeepgramBadRequestException('url must not be empty.');
    }
    _config.logger?.debug('PrerecordedClient: transcribing remote media.');
    final query = (options ?? const PrerecordedOptions()).toQuery();
    query['url'] = url;
    final result = await _http.postJson(
      _listenPath,
      body: null,
      query: query,
      cancelToken: cancelToken,
    );
    return _parse(result.body);
  }

  /// Transcribes raw audio or video [audio] bytes.
  ///
  /// [contentType] must describe the payload — for example `audio/wav`,
  /// `audio/mpeg`, `video/mp4`, or `audio/raw;rate=16000` for raw PCM (the
  /// rate must match the bytes sent). [options] covers every documented
  /// `POST /v1/listen` query parameter, and [cancelToken] cancels the
  /// in-flight request. Upload timeouts scale automatically with payload
  /// size.
  ///
  /// Throws [DeepgramBadRequestException] when [audio] is empty; network,
  /// authentication, quota, and server failures are thrown as the
  /// corresponding [DeepgramException] subtypes by the shared HTTP engine.
  Future<PrerecordedTranscriptionResult> transcribeBytes(
    List<int> audio, {
    String contentType = 'audio/wav',
    PrerecordedOptions? options,
    HttpCancelToken? cancelToken,
  }) async {
    if (audio.isEmpty) {
      throw const DeepgramBadRequestException(
        'audio must not be empty; use transcribeFromUrl for remote media.',
      );
    }
    _config.logger?.debug(
      'PrerecordedClient: transcribing ${audio.length} bytes.',
    );
    final query = (options ?? const PrerecordedOptions()).toQuery();
    final result = await _http.postAudio(
      _listenPath,
      audio: audio,
      contentType: contentType,
      query: query,
      cancelToken: cancelToken,
    );
    return _parse(result.body);
  }

  /// Decodes a successful response body, converting any unexpected parse
  /// failure into a typed [DeepgramException].
  PrerecordedTranscriptionResult _parse(Map<String, dynamic> body) {
    try {
      return PrerecordedTranscriptionResult.fromJson(body);
    } catch (e) {
      throw DeepgramException(
        'Failed to parse pre-recorded transcription response: $e',
        requestId: _extractRequestId(body),
        code: 'response_parse_error',
      );
    }
  }

  static String? _extractRequestId(Map<String, dynamic> body) {
    final metadata = body['metadata'];
    if (metadata is Map<dynamic, dynamic>) {
      final id = metadata['request_id'];
      if (id is String) {
        return id;
      }
    }
    final topLevel = body['request_id'];
    return topLevel is String ? topLevel : null;
  }
}
