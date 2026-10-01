import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

/// Thin REST client for the Go backend.
/// Override the server with:  flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8080
class Api {
  static String get baseUrl {
    const fromEnv = String.fromEnvironment('API_BASE_URL');
    if (fromEnv.isNotEmpty) return fromEnv;
    // Android emulator reaches the host machine through 10.0.2.2
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8080';
    }
    return 'http://localhost:8080';
  }

  static String? staffToken;
  static Map<String, dynamic>? staff;

  static void logout() {
    staffToken = null;
    staff = null;
  }

  static Future<dynamic> _send(String method, String path,
      {Object? body, bool auth = false}) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (auth && staffToken != null) 'Authorization': 'Bearer $staffToken',
    };
    http.Response res;
    try {
      if (method == 'POST') {
        res = await http
            .post(uri, headers: headers, body: jsonEncode(body ?? {}))
            .timeout(const Duration(seconds: 10));
      } else {
        res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 10));
      }
    } catch (_) {
      throw ApiException('Cannot reach the server at $baseUrl');
    }
    final dynamic data = res.body.isEmpty ? null : jsonDecode(res.body);
    if (res.statusCode >= 400) {
      final msg = (data is Map && data['error'] != null)
          ? data['error'].toString()
          : 'Request failed (${res.statusCode})';
      throw ApiException(msg);
    }
    return data;
  }

  static Future<dynamic> get(String path, {bool auth = false}) =>
      _send('GET', path, auth: auth);

  static Future<dynamic> post(String path, {Object? body, bool auth = false}) =>
      _send('POST', path, body: body, auth: auth);

  // ---- visitor ----
  static Future<List<dynamic>> departments() async =>
      (await get('/api/departments')) as List<dynamic>;

  static Future<Map<String, dynamic>> createToken(int deptId, String name, String phone) async =>
      Map<String, dynamic>.from(await post('/api/tokens',
          body: {'department_id': deptId, 'visitor_name': name, 'phone': phone}));

  static Future<Map<String, dynamic>> token(int id) async =>
      Map<String, dynamic>.from(await get('/api/tokens/$id'));

  static Future<Map<String, dynamic>> cancelToken(int id) async =>
      Map<String, dynamic>.from(await post('/api/tokens/$id/cancel'));

  // ---- staff ----
  static Future<void> login(String user, String pass) async {
    final data = await post('/api/auth/login', body: {'username': user, 'password': pass});
    staffToken = data['token'] as String;
    staff = Map<String, dynamic>.from(data['staff'] as Map);
  }
}
