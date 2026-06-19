import 'dart:async';
import 'package:flutter/material.dart';
import 'package:dashboard_flutter/models/vehicle_config.dart';
import 'package:dashboard_flutter/services/metrics_service.dart';

/// A vertical sidebar displayed on the left side of the screen.
///
/// Shows the current time, date, CPU temperature, 12V battery voltage,
/// and a launcher button at the bottom. Replaces the old horizontal StatusBar.
class SideBar extends StatefulWidget {
  final String vehicleModule;
  final SidebarConfig sidebarConfig;
  final VoidCallback onLauncherPressed;

  const SideBar({
    super.key,
    required this.vehicleModule,
    required this.sidebarConfig,
    required this.onLauncherPressed,
  });

  @override
  State<SideBar> createState() => _SideBarState();
}

class _SideBarState extends State<SideBar> {
  final MetricsService _metricsService = MetricsService();
  Timer? _clockTimer;

  static const String _timeSettingsModule =
      'Elixir.InfotainmentCore.TimeSettings';
  static const String _temperatureModule =
      'Elixir.InfotainmentCore.Temperature';
  late final String _vehicleModule;

  String _time = '';
  String _date = '';

  @override
  void initState() {
    super.initState();
    _vehicleModule = widget.vehicleModule;

    _metricsService.subscribe(_timeSettingsModule, 'time_format');
    _metricsService.subscribe(_timeSettingsModule, 'date_format');
    _metricsService.subscribe(_temperatureModule, 'temperature');
    _metricsService.subscribe(_vehicleModule, 'twelve_volt_battery_status');

    _metricsService.addListener(_onMetricsUpdate);

    _updateClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateClock();
    });
  }

  void _onMetricsUpdate() {
    if (mounted) {
      setState(() {
        _updateClock();
      });
    }
  }

  void _updateClock() {
    final now = DateTime.now();
    final timeFormat = _metricsService
            .getValue(_timeSettingsModule, 'time_format')
            ?.toString() ??
        '24h';
    final dateFormat = _metricsService
            .getValue(_timeSettingsModule, 'date_format')
            ?.toString() ??
        'DD/MM/YYYY';

    setState(() {
      _time = _formatTime(now, timeFormat);
      _date = _formatDate(now, dateFormat);
    });
  }

  String _formatTime(DateTime now, String format) {
    if (format == '12h') {
      final hour =
          now.hour == 0 ? 12 : (now.hour > 12 ? now.hour - 12 : now.hour);
      final amPm = now.hour >= 12 ? 'PM' : 'AM';
      return '${hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')} $amPm';
    }
    return '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
  }

  String _formatDate(DateTime now, String format) {
    switch (format) {
      case 'MM/DD/YYYY':
        return '${now.month.toString().padLeft(2, '0')}/'
            '${now.day.toString().padLeft(2, '0')}/'
            '${now.year}';
      case 'YYYY-MM-DD':
        return '${now.year}-'
            '${now.month.toString().padLeft(2, '0')}-'
            '${now.day.toString().padLeft(2, '0')}';
      default: // DD/MM/YYYY
        return '${now.day.toString().padLeft(2, '0')}/'
            '${now.month.toString().padLeft(2, '0')}/'
            '${now.year}';
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _metricsService.removeListener(_onMetricsUpdate);
    _metricsService.unsubscribe(_timeSettingsModule, 'time_format');
    _metricsService.unsubscribe(_timeSettingsModule, 'date_format');
    _metricsService.unsubscribe(_temperatureModule, 'temperature');
    _metricsService.unsubscribe(_vehicleModule, 'twelve_volt_battery_status');
    super.dispose();
  }

  Color _parseSidebarColor() {
    final colorStr = widget.sidebarConfig.backgroundColor;
    if (colorStr != null && colorStr.length >= 6) {
      final value = int.tryParse(colorStr, radix: 16);
      if (value != null) {
        // If 8 chars, it includes alpha; otherwise default to full opacity
        if (colorStr.length == 8) {
          return Color(value);
        }
        return Color(0xFF000000 | value);
      }
    }
    return const Color(0xCC1F2937);
  }

  @override
  Widget build(BuildContext context) {
    final temperatureRaw =
        _metricsService.getValue(_temperatureModule, 'temperature');
    final temperature = temperatureRaw is num
        ? temperatureRaw
        : num.tryParse(temperatureRaw?.toString() ?? '');
    final tempStr = temperature != null
        ? '${temperature.toStringAsFixed(1)}\u00B0C'
        : '0.0\u00B0C';
    final twelveVolt =
        _metricsService.getValue(_vehicleModule, 'twelve_volt_battery_status');
    final batteryStr = twelveVolt != null ? '${twelveVolt}V' : '0.0V';

    return Container(
      width: widget.sidebarConfig.width,
      decoration: BoxDecoration(
        color: _parseSidebarColor(),
        border: const Border(
          right: BorderSide(
            color: Color(0x33FFFFFF),
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 16),
          // Clock
          Text(
            _time,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              fontFamily: 'Lato',
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 4),
          // Date
          Text(
            _date,
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 11,
              fontFamily: 'Lato',
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 24),
          // Divider
          Container(
            width: 40,
            height: 1,
            color: const Color(0x33FFFFFF),
          ),
          const SizedBox(height: 24),
          // CPU Temperature
          const Icon(Icons.memory, color: Colors.grey, size: 18),
          const SizedBox(height: 4),
          Text(
            tempStr,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFamily: 'Lato',
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 16),
          // 12V Battery
          const Icon(Icons.battery_std, color: Colors.grey, size: 18),
          const SizedBox(height: 4),
          Text(
            batteryStr,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFamily: 'Lato',
              decoration: TextDecoration.none,
            ),
          ),
          const Spacer(),
          // Launcher button at the bottom
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: GestureDetector(
              onTap: widget.onLauncherPressed,
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0x33FFFFFF),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0x33FFFFFF),
                    width: 1,
                  ),
                ),
                child: const Icon(
                  Icons.apps_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
