/// Resilient HTTP engine for all Deepgram REST endpoints.
///
/// Features ported from production Flutter deployments of the Deepgram API:
///
/// * Automatic retries with exponential backoff + jitter on 429/5xx and
///   transient network failures.
/// * `Retry-After` header respected on 429 responses.
/// * Payload-scaled timeouts for audio uploads (base timeout + ~2 s per MB)
///   so a multi-minute recording never dies on a fixed default.
/// * Per-request [HttpCancelToken]s.
/// * Typed exception mapping for every Deepgram error shape.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../deepgram_auth.dart';
import '../deepgram_config.dart';
import '../deepgram_exception.dart';

/// A cancellation token, inspired by Dio's `CancelToken`. Cancels the single
/// request (or stream download) it is passed to.
class HttpCancelToken {
  String? _reason;
  final Completer<void> _completer = Completer<void>();

  /// Whether [cancel] has been called.
  bool get isCancelled => _completer.isCompleted;

  /// The reason the request was cancelled, if any.
  String? get reason => _reason;

  /// A future that completes when this token is cancelled.
  Future<void> get whenCancelled => _completer.future;

  /// Cancels the request associated with this token.
  void cancel([String? reason]) {
    _reason = reason ?? 'cancelled';
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// The result of a JSON REST call: the decoded body plus selected headers.
class JsonApiResult {
  /// Creates a [JsonApiResult].
  const JsonApiResult({required this.body, this.requestId});

  /// Decoded JSON body. Always a `Map<String, dynamic>` for successful
  /// Deepgram responses.
  final Map<String, dynamic> body;

  /// Deepgram request id (`x-request-id` header), when present.
  final String? requestId;
}

/// Describes a retryable HTTP failure.
class _RetryableFailure {
  const _RetryableFailure(this.statusCode, {this.retryAfter});

  final int statusCode;
  final Duration? retryAfter;
}

/// The resilient REST engine used by every sub-client.
class HttpEngine {
  /// Creates an engine bound to [config], obtaining credentials from [auth].
  ///
  /// [client] is injectable for testing; production callers omit it and a
  /// default `http.Client()` is created (and closed by [close]).
  HttpEngine({
    required DeepgramConfig config,
    required DeepgramAuth auth,
    http.Client? client,
  }) : _config = config,
       _auth = auth,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final DeepgramConfig _config;
  final DeepgramAuth _auth;
  final http.Client _client;
  final bool _ownsClient;
  final math.Random _random = math.Random();

  bool _closed = false;

  /// Closes the underlying HTTP client.
  ///
  /// Any in-flight or subsequent request throws a [StateError]. If the
  /// [http.Client] was injected by the caller it is NOT closed — the owner
  /// remains responsible for it.
  void close() {
    _closed = true;
    if (_ownsClient) {
      _client.close();
    }
  }

  // ---------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------

  /// Performs a GET and decodes a JSON object response.
  Future<JsonApiResult> getJson(
    String path, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    HttpCancelToken? cancelToken,
  }) {
    return _runJson(
      () async => _client.get(
        _config.restUri(path, query),
        headers: await _headers(extra: headers),
      ),
      cancelToken: cancelToken,
    );
  }

  /// Performs a POST with a JSON body and decodes a JSON object response.
  Future<JsonApiResult> postJson(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    HttpCancelToken? cancelToken,
  }) {
    return _runJson(
      () async => _client.post(
        _config.restUri(path, query),
        headers: await _headers(extra: headers, jsonBody: body != null),
        body: body == null ? null : jsonEncode(body),
      ),
      cancelToken: cancelToken,
    );
  }

  /// Performs a PUT with a JSON body and decodes a JSON object response.
  Future<JsonApiResult> putJson(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    HttpCancelToken? cancelToken,
  }) {
    return _runJson(
      () async => _client.put(
        _config.restUri(path, query),
        headers: await _headers(extra: headers, jsonBody: body != null),
        body: body == null ? null : jsonEncode(body),
      ),
      cancelToken: cancelToken,
    );
  }

  /// Performs a PATCH with a JSON body and decodes a JSON object response.
  Future<JsonApiResult> patchJson(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    HttpCancelToken? cancelToken,
  }) {
    return _runJson(
      () async => _client.patch(
        _config.restUri(path, query),
        headers: await _headers(extra: headers, jsonBody: body != null),
        body: body == null ? null : jsonEncode(body),
      ),
      cancelToken: cancelToken,
    );
  }

  /// Performs a DELETE and decodes a JSON object response (may be empty).
  Future<JsonApiResult> deleteJson(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    HttpCancelToken? cancelToken,
  }) {
    return _runJson(
      () async => _client.delete(
        _config.restUri(path, query),
        headers: await _headers(extra: headers, jsonBody: body != null),
        body: body == null ? null : jsonEncode(body),
      ),
      cancelToken: cancelToken,
    );
  }

  /// Uploads raw audio/video bytes to a JSON endpoint (e.g. pre-recorded
  /// transcription) and decodes the response.
  ///
  /// The timeout is scaled to the payload: base timeout + ~2 s per MB.
  Future<JsonApiResult> postAudio(
    String path, {
    required List<int> audio,
    required String contentType,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    HttpCancelToken? cancelToken,
  }) {
    return _runJson(
      () async => _client.post(
        _config.restUri(path, query),
        headers: await _headers(
          extra: {...?headers, 'Content-Type': contentType},
        ),
        body: audio,
      ),
      timeout: _scaledAudioTimeout(audio.length),
      cancelToken: cancelToken,
    );
  }

  /// POSTs to an endpoint that streams raw audio bytes back (e.g. `/v1/speak`)
  /// and returns the collected bytes.
  Future<List<int>> postForBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    HttpCancelToken? cancelToken,
  }) async {
    final stream = await postForByteStream(
      path,
      body: body,
      query: query,
      headers: headers,
      cancelToken: cancelToken,
    );
    final chunks = <int>[];
    await for (final chunk in stream) {
      chunks.addAll(chunk);
    }
    return chunks;
  }

  /// POSTs to an endpoint that streams raw audio bytes back and returns the
  /// response body as a byte stream — use for playback-as-you-download.
  Future<Stream<List<int>>> postForByteStream(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    HttpCancelToken? cancelToken,
  }) async {
    if (_closed) {
      throw StateError('HttpEngine is closed.');
    }
    final uri = _config.restUri(path, query);
    var attempt = 0;
    while (true) {
      _checkCancelled(cancelToken);
      try {
        final request = http.Request('POST', uri)
          ..headers.addAll(
            await _headers(
              extra: {'Content-Type': 'application/json', ...?headers},
            ),
          );
        if (body != null) request.body = jsonEncode(body);
        final response = await _client
            .send(request)
            .timeout(_config.requestTimeout)
            .then((http.StreamedResponse streamed) async {
              if (streamed.statusCode >= 400) {
                // Drain the error body so the socket can be reused.
                final errorBody = await streamed.stream.bytesToString();
                throw _mapStatusFromParts(
                  streamed.statusCode,
                  errorBody,
                  streamed.headers['retry-after'],
                  requestId: streamed.headers['x-request-id'],
                );
              }
              return streamed;
            });
        return response.stream.map((chunk) {
          _checkCancelled(cancelToken);
          return chunk;
        });
      } on DeepgramException {
        rethrow;
      } on TimeoutException {
        attempt++;
        if (attempt > _config.maxRetries) {
          throw DeepgramTimeoutException(
            'Request to $uri timed out after '
            '${_config.requestTimeout.inSeconds}s.',
          );
        }
        await _waitBackoff(attempt, cancelToken: cancelToken);
      } on http.ClientException catch (e) {
        attempt++;
        if (attempt > _config.maxRetries) {
          throw DeepgramNetworkException('HTTP transport failure.', cause: e);
        }
        await _waitBackoff(attempt, cancelToken: cancelToken);
      }
    }
  }

  // ---------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------

  /// Base timeout + ~2 s per MB — long recordings must not die on a fixed
  /// default timeout.
  Duration _scaledAudioTimeout(int byteLength) {
    final perMb = ((byteLength / (1024 * 1024)) * 2).round();
    return _config.requestTimeout + Duration(seconds: perMb);
  }

  Future<Map<String, String>> _headers({
    Map<String, String>? extra,
    bool jsonBody = false,
  }) async {
    final auth = await _auth.authorizationHeader();
    return {
      'Authorization': auth,
      // Only set when a body is actually sent: a Content-Type on a bodyless
      // request confuses some proxies, and `package:http` would default a
      // JSON body to `text/plain`.
      if (jsonBody) 'Content-Type': 'application/json',
      ...?extra,
    };
  }

  Future<JsonApiResult> _runJson(
    Future<http.Response> Function() attempt, {
    Duration? timeout,
    HttpCancelToken? cancelToken,
  }) async {
    final response = await _runWithRetries(
      attempt,
      timeout: timeout ?? _config.requestTimeout,
      cancelToken: cancelToken,
    );
    return JsonApiResult(
      body: _decodeJsonMap(response.body),
      requestId: response.headers['x-request-id'],
    );
  }

  Future<http.Response> _runWithRetries(
    Future<http.Response> Function() attempt, {
    required Duration timeout,
    HttpCancelToken? cancelToken,
  }) async {
    if (_closed) {
      throw StateError('HttpEngine is closed.');
    }
    var attemptIndex = 0;
    while (true) {
      _checkCancelled(cancelToken);
      try {
        final response = await attempt().timeout(timeout);
        final retryable = _inspect(response);
        if (retryable == null) {
          if (response.statusCode >= 400) {
            // Non-retryable client error: map to a typed exception.
            throw _mapStatus(response, retryAfter: null);
          }
          return response;
        }
        // Retryable status (429 / 5xx).
        attemptIndex++;
        if (attemptIndex > _config.maxRetries) {
          throw _mapStatus(response, retryAfter: retryable.retryAfter);
        }
        await _waitBackoff(
          attemptIndex,
          retryAfter: retryable.retryAfter,
          cancelToken: cancelToken,
        );
      } on DeepgramException {
        rethrow;
      } on TimeoutException {
        attemptIndex++;
        if (attemptIndex > _config.maxRetries) {
          throw DeepgramTimeoutException(
            'Request timed out after ${timeout.inSeconds}s.',
          );
        }
        await _waitBackoff(attemptIndex, cancelToken: cancelToken);
      } on http.ClientException catch (e) {
        attemptIndex++;
        if (attemptIndex > _config.maxRetries) {
          throw DeepgramNetworkException('HTTP transport failure.', cause: e);
        }
        await _waitBackoff(attemptIndex, cancelToken: cancelToken);
      }
    }
  }

  /// Returns a retryable failure description, or `null` when [response] is
  /// either successful or a non-retryable client error.
  _RetryableFailure? _inspect(http.Response response) {
    if (response.statusCode == 429) {
      return _RetryableFailure(
        429,
        retryAfter: _parseRetryAfterSeconds(response.headers['retry-after']),
      );
    }
    if (response.statusCode >= 500) {
      return _RetryableFailure(response.statusCode);
    }
    return null;
  }

  DeepgramException _mapStatus(
    http.Response response, {
    required Duration? retryAfter,
  }) {
    return _mapStatusFromParts(
      response.statusCode,
      response.body,
      response.headers['retry-after'],
      retryAfterOverride: retryAfter,
      requestId: response.headers['x-request-id'],
    );
  }

  DeepgramException _mapStatusFromParts(
    int statusCode,
    String body,
    String? retryAfterHeader, {
    Duration? retryAfterOverride,
    String? requestId,
  }) {
    final decoded = _tryDecode(body);
    final message = _extractErrorMessage(decoded) ?? 'HTTP $statusCode.';
    final effectiveRequestId =
        _extractString(decoded, 'request_id') ?? requestId;
    final code = _extractString(decoded, 'err_code');
    final retryAfter =
        retryAfterOverride ?? _parseRetryAfterSeconds(retryAfterHeader);
    switch (statusCode) {
      case 400:
        return DeepgramBadRequestException(
          message,
          requestId: effectiveRequestId,
          code: code,
        );
      case 401:
      case 403:
        return DeepgramAuthException(
          message,
          requestId: effectiveRequestId,
          code: code,
        );
      case 402:
        return DeepgramQuotaException(
          message,
          requestId: effectiveRequestId,
          code: code,
        );
      case 404:
        return DeepgramNotFoundException(
          message,
          requestId: effectiveRequestId,
          code: code,
        );
      case 429:
        return DeepgramRateLimitException(
          message,
          retryAfter: retryAfter,
          requestId: effectiveRequestId,
          code: code,
        );
      default:
        if (statusCode >= 500) {
          return DeepgramServerException(
            message,
            requestId: effectiveRequestId,
            code: code,
          );
        }
        return DeepgramException(
          message,
          requestId: effectiveRequestId,
          code: code,
        );
    }
  }

  Future<void> _waitBackoff(
    int attempt, {
    Duration? retryAfter,
    HttpCancelToken? cancelToken,
  }) async {
    final delay = retryAfter ?? _backoffDelay(attempt);
    final completer = Completer<void>();
    final timer = Timer(delay, () {
      if (!completer.isCompleted) completer.complete();
    });
    StreamSubscription<void>? cancelSub;
    if (cancelToken != null) {
      cancelSub = cancelToken.whenCancelled.asStream().listen((_) {
        timer.cancel();
        if (!completer.isCompleted) completer.complete();
      });
    }
    await completer.future;
    await cancelSub?.cancel();
    _checkCancelled(cancelToken);
  }

  Duration _backoffDelay(int attempt) {
    final exponential = _config.retryBaseDelay * (1 << math.min(attempt, 16));
    final capped = exponential > _config.retryMaxDelay
        ? _config.retryMaxDelay
        : exponential;
    final jitterMs = _random.nextInt(math.max(1, capped.inMilliseconds ~/ 2));
    return capped + Duration(milliseconds: jitterMs);
  }

  void _checkCancelled(HttpCancelToken? cancelToken) {
    if (cancelToken != null && cancelToken.isCancelled) {
      throw DeepgramException('Request cancelled: ${cancelToken.reason}');
    }
  }

  Duration? _parseRetryAfterSeconds(String? value) {
    if (value == null) return null;
    final seconds = double.tryParse(value);
    if (seconds == null) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  Map<String, dynamic> _decodeJsonMap(String body) {
    final decoded = _tryDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{};
  }

  dynamic _tryDecode(String body) {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}

String? _extractErrorMessage(dynamic decoded) {
  if (decoded is! Map) return null;
  for (final key in const ['err_msg', 'message', 'reason', 'error']) {
    final value = decoded[key];
    if (value is String && value.isNotEmpty) return value;
    if (value is Map && value['message'] is String) {
      return value['message'] as String;
    }
  }
  return null;
}

String? _extractString(dynamic decoded, String key) {
  if (decoded is! Map) return null;
  final value = decoded[key];
  if (value is String && value.isNotEmpty) return value;
  return null;
}
