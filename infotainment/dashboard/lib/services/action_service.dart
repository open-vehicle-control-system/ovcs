import 'dart:convert';
import 'package:http/http.dart' as http;

/// Service to trigger actions on the backend (generic replacement for
/// the hardcoded gear-selector endpoint).
class ActionService {
  static const String _baseUrl = 'http://localhost:4001';

  static Future<void> triggerAction(String module, String action, [Map<String, dynamic>? params]) async {
    final body = <String, dynamic>{
      'module': module,
      'action': action,
    };
    if (params != null) {
      body.addAll(params);
    }
    await http.post(
      Uri.parse('$_baseUrl/api/actions'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: jsonEncode(body),
    );
  }
}
