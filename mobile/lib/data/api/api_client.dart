import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config.dart';

/// Error returned by the backend (non-2xx). [code] is the `code` field of the
/// error body when present (e.g. `INSUFFICIENT_POINTS`).
class ApiException implements Exception {
  const ApiException(this.status, [this.code]);

  final int status;
  final String? code;

  @override
  String toString() => 'ApiException($status${code == null ? '' : ', $code'})';
}

/// Thin JSON client for the central API (contract v2).
///
/// Network errors (no connection, timeout) surface as non-[ApiException]
/// exceptions, so callers can tell "server unavailable" from "server said no".
class ApiClient {
  ApiClient({
    required this.baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client();

  static const deviceKey = 'api_device_id';
  static const tokenKey = 'api_token';

  final String baseUrl;
  final Duration timeout;
  final http.Client _client;
  String? _token;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<dynamic> get(String path, {bool auth = false}) =>
      _send('GET', path, auth: auth);

  /// Raw bytes (e.g. a thumbnail), authenticated. [pathOrUrl] may be absolute.
  Future<List<int>> getBytes(String pathOrUrl, {bool retried = false}) async {
    final uri = pathOrUrl.startsWith('http') ? Uri.parse(pathOrUrl) : _uri(pathOrUrl);
    final res = await _client.get(uri,
        headers: {'Authorization': 'Bearer ${await _ensureToken()}'}).timeout(timeout);
    if (res.statusCode == 401 && !retried) {
      await _clearToken();
      return getBytes(pathOrUrl, retried: true);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) throw ApiException(res.statusCode);
    return res.bodyBytes;
  }

  Future<dynamic> post(String path, {Object? body, bool auth = false}) =>
      _send('POST', path, body: body, auth: auth);

  Future<dynamic> _send(String method, String path,
      {Object? body, bool auth = false, bool retried = false}) async {
    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (auth) headers['Authorization'] = 'Bearer ${await _ensureToken()}';
    final uri = _uri(path);
    final encoded = body == null ? null : jsonEncode(body);
    final res = await (method == 'GET'
            ? _client.get(uri, headers: headers)
            : _client.post(uri, headers: headers, body: encoded))
        .timeout(timeout);

    if (res.statusCode == 401 && auth && !retried) {
      await _clearToken();
      return _send(method, path, body: body, auth: auth, retried: true);
    }
    return _decode(res.statusCode, res.bodyBytes);
  }

  /// `multipart/form-data` POST (e.g. a catch photo). Authenticated by
  /// default; re-authenticates once on 401 (the request is rebuilt).
  Future<dynamic> postMultipart(
    String path, {
    Map<String, String> fields = const {},
    List<MultipartPart> files = const [],
    bool auth = true,
    Duration uploadTimeout = const Duration(seconds: 30),
  }) =>
      _sendMultipart(path, fields, files, auth, uploadTimeout, false);

  Future<dynamic> _sendMultipart(String path, Map<String, String> fields,
      List<MultipartPart> files, bool auth, Duration limit, bool retried) async {
    final req = http.MultipartRequest('POST', _uri(path))
      ..headers['Accept'] = 'application/json'
      ..fields.addAll(fields);
    if (auth) req.headers['Authorization'] = 'Bearer ${await _ensureToken()}';
    for (final f in files) {
      req.files.add(http.MultipartFile.fromBytes(f.field, f.bytes,
          filename: f.filename, contentType: MediaType.parse(f.contentType)));
    }
    final res = await http.Response.fromStream(await _client.send(req)).timeout(limit);
    if (res.statusCode == 401 && auth && !retried) {
      await _clearToken();
      return _sendMultipart(path, fields, files, auth, limit, true);
    }
    return _decode(res.statusCode, res.bodyBytes);
  }

  static dynamic _decode(int status, List<int> bytes) {
    final text = utf8.decode(bytes);
    final decoded = text.isEmpty ? null : _tryDecode(text);
    if (status < 200 || status >= 300) {
      final code = decoded is Map ? decoded['code']?.toString() : null;
      throw ApiException(status, code);
    }
    return decoded;
  }

  static dynamic _tryDecode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  Future<String> _ensureToken() async {
    if (_token != null) return _token!;
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(tokenKey);
    if (_token != null) return _token!;
    var deviceId = prefs.getString(deviceKey);
    if (deviceId == null) {
      deviceId = uuidV4();
      await prefs.setString(deviceKey, deviceId);
    }
    final json = await post('/auth/anonymous', body: {'deviceId': deviceId})
        as Map<String, dynamic>;
    final token = json['token'] as String;
    _token = token;
    await prefs.setString(tokenKey, token);
    return token;
  }

  Future<void> _clearToken() async {
    _token = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(tokenKey);
  }
}

/// One file part of a multipart request.
class MultipartPart {
  const MultipartPart(this.field, this.bytes,
      {required this.filename, this.contentType = 'image/jpeg'});

  final String field;
  final List<int> bytes;
  final String filename;
  final String contentType;
}

/// Random UUID v4 (device id).
String uuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// True for "server unreachable" failures (as opposed to an API error).
bool isNetworkError(Object e) => e is! ApiException;

final apiClientProvider =
    Provider<ApiClient>((ref) => ApiClient(baseUrl: apiBaseUrl));

/// true when, in API mode, the server could not be reached and local data is shown.
final serverUnavailableProvider = StateProvider<bool>((ref) => false);
