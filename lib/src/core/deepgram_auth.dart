/// Credential management: API keys, JWTs, temporary token grants, and
/// automatic token refresh via a user-supplied provider.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'deepgram_config.dart';
import 'deepgram_exception.dart';

/// Signature of a callback that supplies a fresh JWT when needed.
///
/// Use this with `DeepgramClient.withTokenProvider` to integrate with your
/// own backend that mints short-lived Deepgram tokens.
typedef DeepgramTokenProvider = Future<String> Function();

/// Holds credentials and produces `Authorization` header values.
///
/// Precedence: explicit [DeepgramConfig.jwt] beats a token provider; an API
/// key is used directly. When a token provider is set, the produced JWT is
/// cached and refreshed through the provider on demand.
class DeepgramAuth {
  /// Creates auth bound to the given [DeepgramConfig].
  DeepgramAuth(this._config, {DeepgramTokenProvider? tokenProvider})
    : _tokenProvider = tokenProvider;

  final DeepgramConfig _config;
  final DeepgramTokenProvider? _tokenProvider;

  String? _cachedJwt;

  /// True when the configuration uses an API key directly.
  bool get usesApiKey => _config.apiKey != null;

  /// True when the configuration uses a static JWT.
  bool get usesStaticJwt => _config.jwt != null;

  /// True when tokens are minted through a provider.
  bool get usesTokenProvider => _tokenProvider != null;

  /// Returns the raw credential (API key or JWT), preferring a provider.
  Future<String> token() async {
    final cached = _cachedJwt;
    if (cached != null && cached.isNotEmpty) return cached;
    final provider = _tokenProvider;
    if (provider != null) {
      return provider();
    }
    final jwt = _config.jwt;
    if (jwt != null && jwt.isNotEmpty) return jwt;
    final apiKey = _config.apiKey;
    if (apiKey != null && apiKey.isNotEmpty) return apiKey;
    throw const DeepgramAuthException(
      'No Deepgram credentials configured. Provide an apiKey, a jwt, or a '
      'token provider.',
    );
  }

  /// Returns the value for the `Authorization` header.
  ///
  /// API keys become `Token <key>`; JWTs become `Bearer <jwt>`.
  Future<String> authorizationHeader() async {
    final credential = await token();
    final apiKey = _config.apiKey;
    final usesApiKey =
        apiKey != null &&
        apiKey.isNotEmpty &&
        (_cachedJwt == null || _cachedJwt!.isEmpty) &&
        (_config.jwt == null || _config.jwt!.isEmpty) &&
        _tokenProvider == null;
    return usesApiKey ? 'Token $credential' : 'Bearer $credential';
  }

  /// Requests a temporary JSON Web Token from `POST /v1/auth/grant`.
  ///
  /// The token carries `usage::write` permission for the core voice APIs and
  /// expires after [ttl] (default 30 s, matching Deepgram's default). Requires
  /// an API key with Member or higher authorization.
  ///
  /// Returns a record with the JWT and its TTL in seconds.
  Future<({String accessToken, double? expiresIn})> grantTemporaryToken({
    Duration ttl = const Duration(seconds: 30),
  }) async {
    final apiKey = _config.apiKey;
    if (apiKey == null) {
      throw const DeepgramAuthException(
        'grantTemporaryToken requires an API key (not a JWT or provider).',
      );
    }
    final uri = _config.restUri('/v1/auth/grant');
    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Authorization': 'Token $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'ttl_seconds': ttl.inSeconds}),
          )
          .timeout(_config.requestTimeout);
      if (response.statusCode != 200) {
        throw _mapError(response.statusCode, response.body);
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> ||
          decoded['access_token'] is! String) {
        throw const DeepgramServerException(
          'Malformed grant response from Deepgram.',
        );
      }
      final expiresIn = decoded['expires_in'];
      return (
        accessToken: decoded['access_token'] as String,
        expiresIn: expiresIn is num ? expiresIn.toDouble() : null,
      );
    } on DeepgramException {
      rethrow;
    } on TimeoutException {
      throw const DeepgramTimeoutException('Token grant request timed out.');
    } on http.ClientException catch (e) {
      throw DeepgramNetworkException(
        'Token grant transport failure.',
        cause: e,
      );
    } on FormatException {
      throw const DeepgramServerException(
        'The token grant endpoint returned a non-JSON body.',
      );
    }
  }

  /// Mints a fresh temporary token and caches it for [authorizationHeader].
  ///
  /// This switches this client to Bearer authentication with an auto-renewing
  /// short-lived token — recommended for browser deployments.
  Future<void> useTemporaryTokens() async {
    final grant = await grantTemporaryToken();
    _cachedJwt = grant.accessToken;
  }

  DeepgramException _mapError(int statusCode, String body) {
    String? message;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        for (final key in const ['err_msg', 'message', 'reason']) {
          final value = decoded[key];
          if (value is String && value.isNotEmpty) {
            message = value;
            break;
          }
        }
      }
    } catch (_) {
      // Body was not JSON — fall through to the generic message.
    }
    final fallback = 'Token grant failed with HTTP $statusCode.';
    switch (statusCode) {
      case 401:
      case 403:
        return DeepgramAuthException(message ?? fallback);
      default:
        return DeepgramServerException(message ?? fallback);
    }
  }
}
