/// HTTP test doubles: an [http.Client] that serves queued responses.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Thrown by [QueueHttpClient] when a test forgets to enqueue a response.
class NoResponseQueued implements Exception {
  @override
  String toString() =>
      'NoResponseQueued: the test did not enqueue enough '
      'responses for the requests the SDK made.';
}

/// Record of a streamed request captured by [QueueHttpClient].
class StreamedRequestRecord {
  StreamedRequestRecord({
    required this.method,
    required this.url,
    required this.headers,
    required this.bodyBytes,
  });

  final String method;

  final Uri url;

  final Map<String, String> headers;

  final List<int> bodyBytes;
}

/// An [http.Client] that serves queued responses in FIFO order.
///
/// The SDK's [HttpEngine] goes through [send], so both the convenience
/// methods and `Client.send` land in the same queue. Audio uploads (the
/// pre-recorded API) are streamed; their bodies are captured into
/// [StreamedRequestRecord]s for assertions.
class QueueHttpClient implements http.Client {
  final List<_Queued> _queue = [];

  /// Plain requests received, in order.
  final List<http.Request> requests = [];

  /// Streamed requests received, in order.
  final List<StreamedRequestRecord> streamedRequests = [];

  int _served = 0;

  /// Enqueues a JSON response (any encodable object).
  void enqueueJson(
    Object body, {
    int status = 200,
    Map<String, String> headers = const {},
  }) {
    _queue.add(
      _Queued(
        respond: (request) => http.Response(
          body is String ? body : jsonEncode(body),
          status,
          headers: headers,
          request: request,
        ),
      ),
    );
  }

  /// Enqueues a response built by [builder] (full control).
  void enqueueRaw(http.Response Function(http.Request request) builder) {
    _queue.add(_Queued(respond: builder));
  }

  /// Enqueues a byte-array response (for TTS audio).
  void enqueueBytes(List<int> bytes, {int status = 200}) {
    _queue.add(
      _Queued(
        respond: (request) =>
            http.Response.bytes(bytes, status, request: request),
      ),
    );
  }

  /// Enqueues an exception to be thrown instead of responding.
  void enqueueError(Object error) {
    _queue.add(_Queued(error: error));
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final next = _queue.length > _served ? _queue[_served] : null;
    _served++;
    if (next == null) {
      throw NoResponseQueued();
    }
    if (next.error != null) {
      throw next.error!;
    }

    // Capture the request for assertions.
    if (request is http.Request) {
      requests.add(request);
    } else {
      final bytes = await request.finalize().toBytes();
      streamedRequests.add(
        StreamedRequestRecord(
          method: request.method,
          url: request.url,
          headers: Map<String, String>.from(request.headers),
          bodyBytes: bytes,
        ),
      );
    }

    final response = next.respond!(
      http.Request(request.method, request.url)
        ..headers.addAll(request.headers),
    );
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }

  @override
  Future<http.Response> head(Uri url, {Map<String, String>? headers}) async {
    return _respondSimple('HEAD', url, headers);
  }

  @override
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) async {
    return _respondSimple('GET', url, headers);
  }

  @override
  Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    return _respondSimple('POST', url, headers, body);
  }

  @override
  Future<http.Response> put(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    return _respondSimple('PUT', url, headers, body);
  }

  @override
  Future<http.Response> patch(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    return _respondSimple('PATCH', url, headers, body);
  }

  @override
  Future<http.Response> delete(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    return _respondSimple('DELETE', url, headers, body);
  }

  @override
  Future<String> read(Uri url, {Map<String, String>? headers}) async {
    final response = await get(url, headers: headers);
    return response.body;
  }

  @override
  Future<Uint8List> readBytes(Uri url, {Map<String, String>? headers}) async {
    final response = await get(url, headers: headers);
    return response.bodyBytes;
  }

  @override
  void close() {}

  Future<http.Response> _respondSimple(
    String method,
    Uri url,
    Map<String, String>? headers, [
    Object? body,
  ]) async {
    final request = http.Request(method, url)
      ..headers.addAll(headers ?? const {});
    if (body != null) {
      request.body = body is String ? body : body.toString();
    }
    requests.add(request);
    final next = _queue.length > _served ? _queue[_served] : null;
    _served++;
    if (next == null) {
      throw NoResponseQueued();
    }
    if (next.error != null) {
      throw next.error!;
    }
    return next.respond!(request);
  }
}

class _Queued {
  _Queued({this.respond, this.error});

  final http.Response Function(http.Request request)? respond;

  final Object? error;
}
