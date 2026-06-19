import 'dart:async';
import 'package:flutter/material.dart';
import 'package:dashboard_flutter/services/metrics_service.dart';

/// A thin, semi-transparent status bar displayed at the top of the screen.
///
/// Shows the current time, CPU temperature, and 12V battery voltage.
/// Uses MetricsService to subscribe to time settings, temperature, and
/// vehicle metrics via the composable WebSocket channel.
class StatusBar extends StatefulWidget {
  final String vehicleModule;

  const StatusBar({super.key, required this.vehicleModule});

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
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

    // Subscribe to time settings, temperature, and vehicle metrics
    _metricsService.subscribe(_timeSettingsModule, 'time_format');
    _metricsService.subscribe(_timeSettingsModule, 'date_format');
    _metricsService.subscribe(_temperatureModule, 'temperature');
    _metricsService.subscribe(_vehicleModule, 'twelve_volt_battery_status');

    _metricsService.addListener(_onMetricsUpdate);

    // Update clock every second
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
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Color(0x99000000),
      ),
      child: Row(
        children: [
          // Time + date on the left
          Text(
            _time,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontFamily: 'Lato',
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _date,
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 12,
              fontFamily: 'Lato',
              decoration: TextDecoration.none,
            ),
          ),
          const Spacer(),
          // System info on the right
          const Icon(Icons.memory, color: Colors.grey, size: 14),
          const SizedBox(width: 4),
          Text(
            tempStr,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFamily: 'Lato',
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(width: 16),
          const Icon(Icons.battery_std, color: Colors.grey, size: 14),
          const SizedBox(width: 4),
          Text(
            batteryStr,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFamily: 'Lato',
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }
}
