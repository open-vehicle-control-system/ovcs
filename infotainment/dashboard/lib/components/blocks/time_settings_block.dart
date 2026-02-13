import 'package:flutter/material.dart';
import 'package:dashboard_flutter/models/block_config.dart';
import 'package:dashboard_flutter/services/metrics_service.dart';
import 'package:dashboard_flutter/services/action_service.dart';

/// Renders time settings: timezone picker, time format toggle, date format toggle.
/// Reads current values from MetricsService, triggers actions via ActionService.
class TimeSettingsBlock extends StatelessWidget {
  final BlockConfig block;
  final MetricsService metricsService;

  const TimeSettingsBlock({
    super.key,
    required this.block,
    required this.metricsService,
  });

  static const List<String> _timeFormats = ['24h', '12h'];
  static const List<String> _dateFormats = ['DD/MM/YYYY', 'MM/DD/YYYY', 'YYYY-MM-DD'];

  static const List<String> _timezones = [
    'UTC',
    'Europe/London',
    'Europe/Paris',
    'Europe/Berlin',
    'Europe/Madrid',
    'Europe/Rome',
    'Europe/Amsterdam',
    'Europe/Brussels',
    'Europe/Zurich',
    'Europe/Vienna',
    'Europe/Stockholm',
    'Europe/Oslo',
    'Europe/Helsinki',
    'Europe/Athens',
    'Europe/Bucharest',
    'Europe/Moscow',
    'America/New_York',
    'America/Chicago',
    'America/Denver',
    'America/Los_Angeles',
    'America/Anchorage',
    'Pacific/Honolulu',
    'America/Toronto',
    'America/Vancouver',
    'America/Mexico_City',
    'America/Sao_Paulo',
    'America/Argentina/Buenos_Aires',
    'Asia/Tokyo',
    'Asia/Shanghai',
    'Asia/Hong_Kong',
    'Asia/Singapore',
    'Asia/Seoul',
    'Asia/Kolkata',
    'Asia/Dubai',
    'Australia/Sydney',
    'Australia/Melbourne',
    'Pacific/Auckland',
  ];

  String _getMetricValue(String key, String fallback) {
    for (final metric in block.metrics) {
      if (metric.key == key) {
        final value = metricsService.getValue(metric.module, metric.key);
        if (value != null) return value.toString();
      }
    }
    return fallback;
  }

  ActionRef? _getAction(String actionName) {
    for (final action in block.actions) {
      if (action.action == actionName) return action;
    }
    return null;
  }

  void _setTimezone(String timezone) {
    final action = _getAction('set_timezone');
    if (action != null) {
      ActionService.triggerAction(action.module, action.action, {'timezone': timezone});
    }
  }

  void _setTimeFormat(String timeFormat) {
    final action = _getAction('set_time_format');
    if (action != null) {
      ActionService.triggerAction(action.module, action.action, {'time_format': timeFormat});
    }
  }

  void _setDateFormat(String dateFormat) {
    final action = _getAction('set_date_format');
    if (action != null) {
      ActionService.triggerAction(action.module, action.action, {'date_format': dateFormat});
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentTimezone = _getMetricValue('timezone', 'UTC');
    final currentTimeFormat = _getMetricValue('time_format', '24h');
    final currentDateFormat = _getMetricValue('date_format', 'DD/MM/YYYY');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Timezone picker (left half)
        Expanded(
          flex: 1,
          child: _buildTimezoneSection(currentTimezone),
        ),
        const SizedBox(width: 20),
        // Time format + Date format (right half)
        Expanded(
          flex: 1,
          child: Column(
            children: [
              Expanded(
                child: _buildToggleSection(
                  'Time Format',
                  _timeFormats,
                  currentTimeFormat,
                  _setTimeFormat,
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: _buildToggleSection(
                  'Date Format',
                  _dateFormats,
                  currentDateFormat,
                  _setDateFormat,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTimezoneSection(String currentTimezone) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Timezone',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0x20FFFFFF),
              borderRadius: BorderRadius.circular(16),
            ),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _timezones.length,
              itemBuilder: (context, index) {
                final tz = _timezones[index];
                final isSelected = tz == currentTimezone;
                return GestureDetector(
                  onTap: () => _setTimezone(tz),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0x40FFFFFF) : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      tz,
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white60,
                        fontSize: 14,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildToggleSection(
    String label,
    List<String> options,
    String currentValue,
    void Function(String) onSelect,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Row(
            children: options.map((option) {
              final isSelected = option == currentValue;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: GestureDetector(
                    onTap: () => onSelect(option),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0x40FFFFFF)
                            : const Color(0x20FFFFFF),
                        borderRadius: BorderRadius.circular(16),
                        border: isSelected
                            ? Border.all(color: Colors.white30, width: 1)
                            : null,
                      ),
                      child: Text(
                        option,
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.white60,
                          fontSize: 16,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}
