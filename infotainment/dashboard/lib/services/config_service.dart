import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:dashboard_flutter/models/vehicle_config.dart';
import 'package:dashboard_flutter/models/page_config.dart';
import 'package:dashboard_flutter/models/block_config.dart';

/// Service to fetch composable configuration from the infotainment API.
class ConfigService {
  static const String _baseUrl = 'http://localhost:4001';

  static Future<VehicleConfig> fetchVehicle() async {
    final response = await http.get(Uri.parse('$_baseUrl/api/vehicle'));
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return VehicleConfig.fromJson(json['data'] as Map<String, dynamic>);
  }

  static Future<List<PageConfig>> fetchPages() async {
    final response = await http.get(Uri.parse('$_baseUrl/api/vehicle/pages'));
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final data = json['data'] as List<dynamic>;
    return data.map((p) => PageConfig.fromJson(p as Map<String, dynamic>)).toList();
  }

  static Future<List<BlockConfig>> fetchBlocks(String pageId) async {
    final response = await http.get(Uri.parse('$_baseUrl/api/vehicle/pages/$pageId/blocks'));
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final data = json['data'] as List<dynamic>;
    return data.map((b) => BlockConfig.fromJson(b as Map<String, dynamic>)).toList();
  }
}
