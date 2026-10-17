/// Typed exception hierarchy for every failure mode the Deepgram APIs can
/// produce, so callers can `switch` on the concrete type instead of parsing
/// error strings.
library;

/// Base class for all errors thrown by the flutter_deepgram SDK.
class DeepgramException implements Exception {
  /// Creates a [DeepgramException].
  const DeepgramException(this.message, {this.requestId, this.code});

  /// Human-readable description of the failure.
  final String message;

  /// Deepgram request id, when the server provided one (`request_id` field of
  /// the error body or the `x-request-id` response header).
  final String? requestId;

  /// Machine-readable error code (`err_code` field), when present.
  final String? code;

  @override
  String toString() {
    final sb = StringBuffer('DeepgramException: $message');
    if (code != null) sb.write(' (code: $code)');
    if (requestId != null) sb.write(' (request_id: $requestId)');
    return sb.toString();
  }
}

/// The API key or token was missing, malformed, expired, or unauthorized.
class DeepgramAuthException extends DeepgramException {
  /// Creates a [DeepgramAuthException].
  const DeepgramAuthException(super.message, {super.requestId, super.code});
}

/// The request was syntactically invalid (HTTP 400 / validation error).
class DeepgramBadRequestException extends DeepgramException {
  /// Creates a [DeepgramBadRequestException].
  const DeepgramBadRequestException(
    super.message, {
    super.requestId,
    super.code,
  });
}

/// The referenced resource does not exist (HTTP 404).
class DeepgramNotFoundException extends DeepgramException {
  /// Creates a [DeepgramNotFoundException].
  const DeepgramNotFoundException(super.message, {super.requestId, super.code});
}

/// The account is out of credit / quota for this operation.
class DeepgramQuotaException extends DeepgramException {
  /// Creates a [DeepgramQuotaException].
  const DeepgramQuotaException(super.message, {super.requestId, super.code});
}

/// Deepgram is throttling the client (HTTP 429).
class DeepgramRateLimitException extends DeepgramException {
  /// Creates a [DeepgramRateLimitException].
  const DeepgramRateLimitException(
    super.message, {
    this.retryAfter,
    super.requestId,
    super.code,
  });

  /// Parsed `Retry-After` header, when the server sent one.
  final Duration? retryAfter;
}

/// Deepgram failed to process the request (HTTP 5xx).
class DeepgramServerException extends DeepgramException {
  /// Creates a [DeepgramServerException].
  const DeepgramServerException(super.message, {super.requestId, super.code});
}

/// The transport layer failed before Deepgram could answer (DNS, TCP, TLS).
class DeepgramNetworkException extends DeepgramException {
  /// Creates a [DeepgramNetworkException].
  const DeepgramNetworkException(super.message, {Object? cause})
    : _cause = cause;

  final Object? _cause;

  /// The underlying transport error, when captured.
  Object? get cause => _cause;

  @override
  String toString() {
    final inner = _cause == null ? '' : ' (cause: $_cause)';
    return 'DeepgramNetworkException: $message$inner';
  }
}

/// A request or connection attempt exceeded its configured timeout.
class DeepgramTimeoutException extends DeepgramException {
  /// Creates a [DeepgramTimeoutException].
  const DeepgramTimeoutException(super.message);
}

/// A WebSocket-level failure: refused upgrade, abnormal close, or protocol
/// error.
class DeepgramWebSocketException extends DeepgramException {
  /// Creates a [DeepgramWebSocketException].
  const DeepgramWebSocketException(
    super.message, {
    this.closeCode,
    this.closeReason,
    super.requestId,
    super.code,
  });

  /// The WebSocket close code, when the connection was closed with one.
  final int? closeCode;

  /// The WebSocket close reason, when the connection was closed with one.
  final String? closeReason;

  @override
  String toString() {
    final sb = StringBuffer('DeepgramWebSocketException: $message');
    if (closeCode != null) {
      sb.write(' (closeCode: $closeCode');
      if (closeReason != null && closeReason!.isNotEmpty) {
        sb.write(', closeReason: $closeReason');
      }
      sb.write(')');
    }
    return sb.toString();
  }
}

/// Raised when an operation is attempted on a session that is already closed
/// or disposed.
class DeepgramStateException extends DeepgramException {
  /// Creates a [DeepgramStateException].
  const DeepgramStateException(super.message);
}
