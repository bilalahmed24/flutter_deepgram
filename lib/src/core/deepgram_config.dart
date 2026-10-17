/// Global configuration for the [DeepgramClient]: credentials, endpoints,
/// regional routing, retry policy, and timeouts.
library;

import 'deepgram_logger.dart';

/// Deepgram processing regions.
///
/// See https://developers.deepgram.com/reference/regional-endpoints.
enum DeepgramRegion {
  /// Default global endpoint (`api.deepgram.com` / `agent.deepgram.com`).
  global('api.deepgram.com', 'agent.deepgram.com'),

  /// European Union — data never leaves the EU.
  eu('api.eu.deepgram.com', 'api.eu.deepgram.com'),

  /// Australia.
  au('api.au.deepgram.com', 'api.au.deepgram.com'),

  /// India.
  india('api.in.deepgram.com', 'api.in.deepgram.com');

  const DeepgramRegion(this.restHost, this.agentHost);

  /// Host used for REST and WebSocket API calls (except the Voice Agent).
  final String restHost;

  /// Host used for the Voice Agent WebSocket.
  final String agentHost;
}

/// Immutable configuration object shared by every sub-client.
///
/// Provide either [apiKey], or [jwt], or set a token provider on the client.
class DeepgramConfig {
  /// Creates a configuration.
  const DeepgramConfig({
    this.apiKey,
    this.jwt,
    this.baseUrl = 'api.deepgram.com',
    this.agentBaseUrl = 'agent.deepgram.com',
    this.useTls = true,
    this.requestTimeout = const Duration(seconds: 60),
    this.connectTimeout = const Duration(seconds: 15),
    this.maxRetries = 3,
    this.retryBaseDelay = const Duration(milliseconds: 500),
    this.retryMaxDelay = const Duration(seconds: 10),
    this.probeUrl,
    this.logger,
  }) : assert(
          apiKey != null || jwt != null,
          'Provide an apiKey or a jwt (or use DeepgramClient.withTokenProvider).',
        );

  /// Creates a configuration pointing at a [DeepgramRegion].
  factory DeepgramConfig.region(
    DeepgramRegion region, {
    String? apiKey,
    String? jwt,
    Duration requestTimeout = const Duration(seconds: 60),
    Duration connectTimeout = const Duration(seconds: 15),
    int maxRetries = 3,
    Duration retryBaseDelay = const Duration(milliseconds: 500),
    Duration retryMaxDelay = const Duration(seconds: 10),
    String? probeUrl,
    DeepgramLogger? logger,
  }) {
    return DeepgramConfig(
      apiKey: apiKey,
      jwt: jwt,
      baseUrl: region.restHost,
      agentBaseUrl: region.agentHost,
      requestTimeout: requestTimeout,
      connectTimeout: connectTimeout,
      maxRetries: maxRetries,
      retryBaseDelay: retryBaseDelay,
      retryMaxDelay: retryMaxDelay,
      probeUrl: probeUrl,
      logger: logger,
    );
  }

  /// Deepgram API key (`Authorization: Token <apiKey>`).
  final String? apiKey;

  /// A pre-issued JSON Web Token (`Authorization: Bearer <jwt>`).
  final String? jwt;

  /// Host for REST + media WebSockets. Default: `api.deepgram.com`.
  final String baseUrl;

  /// Host for the Voice Agent WebSocket. Default: `agent.deepgram.com`.
  final String agentBaseUrl;

  /// Whether to use TLS (`https` / `wss`). Should stay `true` in production.
  final bool useTls;

  /// Default timeout for REST requests (scaled up automatically for large
  /// audio uploads).
  final Duration requestTimeout;

  /// Timeout for establishing WebSocket connections.
  final Duration connectTimeout;

  /// Maximum number of retries for idempotent REST requests.
  final int maxRetries;

  /// Base delay for the exponential retry backoff.
  final Duration retryBaseDelay;

  /// Upper bound for the exponential retry backoff.
  final Duration retryMaxDelay;

  /// URL used by the connectivity probe to distinguish "internet is down"
  /// from "Deepgram is down". Defaults to the REST base URL.
  final String? probeUrl;

  /// Optional logger shared by every component.
  final DeepgramLogger? logger;

  /// The REST scheme (`https` or `http`).
  String get restScheme => useTls ? 'https' : 'http';

  /// The WebSocket scheme (`wss` or `ws`).
  String get wsScheme => useTls ? 'wss' : 'ws';

  /// Builds a REST URI for [path] (e.g. `/v1/listen`).
  Uri restUri(String path, [Map<String, dynamic>? query]) {
    return _buildUri(
        scheme: restScheme, host: baseUrl, path: path, query: query);
  }

  /// Builds a WebSocket URI for [path] on the media host.
  Uri wsUri(String path, [Map<String, dynamic>? query]) {
    return _buildUri(scheme: wsScheme, host: baseUrl, path: path, query: query);
  }

  /// Builds a WebSocket URI for [path] on the Voice Agent host.
  Uri agentWsUri(String path, [Map<String, dynamic>? query]) {
    return _buildUri(
        scheme: wsScheme, host: agentBaseUrl, path: path, query: query);
  }

  /// Returns a copy with the given fields replaced.
  DeepgramConfig copyWith({
    String? apiKey,
    String? jwt,
    String? baseUrl,
    String? agentBaseUrl,
    bool? useTls,
    Duration? requestTimeout,
    Duration? connectTimeout,
    int? maxRetries,
    Duration? retryBaseDelay,
    Duration? retryMaxDelay,
    String? probeUrl,
    DeepgramLogger? logger,
  }) {
    return DeepgramConfig(
      apiKey: apiKey ?? this.apiKey,
      jwt: jwt ?? this.jwt,
      baseUrl: baseUrl ?? this.baseUrl,
      agentBaseUrl: agentBaseUrl ?? this.agentBaseUrl,
      useTls: useTls ?? this.useTls,
      requestTimeout: requestTimeout ?? this.requestTimeout,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      maxRetries: maxRetries ?? this.maxRetries,
      retryBaseDelay: retryBaseDelay ?? this.retryBaseDelay,
      retryMaxDelay: retryMaxDelay ?? this.retryMaxDelay,
      probeUrl: probeUrl ?? this.probeUrl,
      logger: logger ?? this.logger,
    );
  }

  /// The URL used by the connectivity probe.
  String get effectiveProbeUrl =>
      probeUrl ?? Uri(scheme: restScheme, host: baseUrl, path: '/').toString();

  static Uri _buildUri({
    required String scheme,
    required String host,
    required String path,
    Map<String, dynamic>? query,
  }) {
    // `host` may carry an explicit port (`host:port`), which is useful for
    // proxies, self-hosted gateways, and local testing. IPv6 forms like
    // `[::1]:9000` are handled too.
    var effectiveHost = host;
    int? port;
    if (host.startsWith('[')) {
      // IPv6 literal: [::1] or [::1]:port
      final close = host.indexOf(']');
      if (close >= 0) {
        effectiveHost = host.substring(0, close + 1);
        final rest = host.substring(close + 1);
        if (rest.startsWith(':')) {
          final parsed = int.tryParse(rest.substring(1));
          if (parsed != null) port = parsed;
        }
      }
    } else {
      final colon = host.lastIndexOf(':');
      // A single colon means host:port; multiple colons without brackets
      // would be a bare IPv6 literal, which has no port suffix.
      if (colon > 0 && host.indexOf(':') == colon) {
        final parsed = int.tryParse(host.substring(colon + 1));
        if (parsed != null) {
          effectiveHost = host.substring(0, colon);
          port = parsed;
        }
      }
    }
    if (query == null || query.isEmpty) {
      return Uri(scheme: scheme, host: effectiveHost, port: port, path: path);
    }
    final parts = <String>[];
    query.forEach((key, value) {
      if (value == null) return;
      if (value is Iterable) {
        for (final item in value) {
          parts.add(
            '${Uri.encodeQueryComponent(key)}='
            '${Uri.encodeQueryComponent(item.toString())}',
          );
        }
      } else {
        parts.add(
          '${Uri.encodeQueryComponent(key)}='
          '${Uri.encodeQueryComponent(value.toString())}',
        );
      }
    });
    return Uri(
      scheme: scheme,
      host: effectiveHost,
      port: port,
      path: path,
      query: parts.join('&'),
    );
  }
}
