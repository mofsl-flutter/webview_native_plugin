import 'dart:convert';
import 'dart:io';

import '../config/endpoints.dart';

/// Outcome of an access-token request.
class TokenResult {
  /// Creates a result.
  const TokenResult({
    required this.ok,
    required this.statusCode,
    required this.rawBody,
    required this.totalMicros,
    this.token,
    this.connectMicros,
    this.error,
  });

  /// Whether a token was obtained.
  final bool ok;

  /// HTTP status, or 0 when the request never completed.
  final int statusCode;

  /// Response body exactly as received.
  ///
  /// Always retained: when the response shape changes you need the evidence, not an exception.
  final String rawBody;

  /// Total request duration.
  final int totalMicros;

  /// The JWT, when [ok].
  final String? token;

  /// Time until the request headers were sent.
  final int? connectMicros;

  /// Failure description, when not [ok].
  final String? error;
}

/// Claims decoded from a JWT payload.
class JwtClaims {
  /// Creates a claims view.
  const JwtClaims(this.raw);

  /// Decoded payload.
  final Map<String, Object?> raw;

  /// Subject / client code.
  String? get uniqueName => raw['unique_name']?.toString();

  /// Role.
  String? get role => raw['role']?.toString();

  /// Application id.
  String? get appId => raw['appid']?.toString();

  /// Issued-at instant.
  DateTime? get issuedAt => _time('iat');

  /// Not-before instant.
  DateTime? get notBefore => _time('nbf');

  /// Expiry instant.
  DateTime? get expiresAt => _time('exp');

  /// Time left before expiry, or null when unknown.
  Duration? get remaining {
    final DateTime? exp = expiresAt;
    if (exp == null) return null;
    return exp.difference(DateTime.now());
  }

  DateTime? _time(String key) {
    final Object? v = raw[key];
    if (v is num) {
      return DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000);
    }
    return null;
  }

  /// Decodes the payload of [jwt], or returns null when it cannot be read.
  ///
  /// The payload segment is unpadded base64url, which the strict decoder rejects — hence the
  /// normalisation. Never throws: the caller shows "undecodable" plus the raw value instead.
  static JwtClaims? decode(String jwt) {
    final List<String> parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final String json =
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final Object? decoded = jsonDecode(json);
      if (decoded is Map) return JwtClaims(Map<String, Object?>.from(decoded));
      return null;
    } on Object {
      return null;
    }
  }
}

/// Fetches access tokens.
///
/// Uses `dart:io` directly rather than a package: this is two plain GETs, and `HttpClient`
/// exposes connect time separately from the response wait, which the harness reports.
class TokenApi {
  /// Requests a token for [clientCode].
  Future<TokenResult> fetch({
    required String clientCode,
    required String userType,
    required String appId,
  }) async {
    final Stopwatch sw = Stopwatch()..start();
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final Uri uri = Uri.parse(kTokenBase).replace(
        queryParameters: <String, String>{
          'clientCode': clientCode,
          'userType': userType,
        },
      );
      final HttpClientRequest req = await client.getUrl(uri);
      req.headers.set('accept', 'application/json');
      req.headers.set('X-Api-Version', '4.0');
      req.headers.set('AppId', appId);
      final int connectMicros = sw.elapsedMicroseconds;

      final HttpClientResponse res = await req.close();
      final String body = await res.transform(utf8.decoder).join();
      final int totalMicros = sw.elapsedMicroseconds;

      if (res.statusCode != 200) {
        return TokenResult(
          ok: false,
          statusCode: res.statusCode,
          rawBody: body,
          totalMicros: totalMicros,
          connectMicros: connectMicros,
          error: 'HTTP ${res.statusCode}',
        );
      }

      // The body is a bare JSON string - a quoted JWT, not an object.
      final Object? decoded = jsonDecode(body);
      if (decoded is! String || decoded.isEmpty) {
        return TokenResult(
          ok: false,
          statusCode: res.statusCode,
          rawBody: body,
          totalMicros: totalMicros,
          connectMicros: connectMicros,
          error: 'Expected a bare JSON string, got ${decoded.runtimeType}',
        );
      }

      return TokenResult(
        ok: true,
        statusCode: res.statusCode,
        rawBody: body,
        totalMicros: totalMicros,
        connectMicros: connectMicros,
        token: decoded,
      );
    } on Object catch (e) {
      return TokenResult(
        ok: false,
        statusCode: 0,
        rawBody: '',
        totalMicros: sw.elapsedMicroseconds,
        error: e.toString(),
      );
    } finally {
      client.close(force: true);
    }
  }
}
