import 'dart:async';
import 'package:flutter/material.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:dashboard_flutter/services/socket_service.dart';

/// A thin, semi-transparent status bar displayed at the top of the screen.
///
/// Shows the current time, CPU temperature, and 12V battery voltage.
/// Uses the existing temperature and status channels directly since
/// these are system-level metrics outside the composable page system.
class StatusBar extends StatefulWidget {
  const StatusBar({super.key});

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  String _time = _formatTime();
  String _date = _formatDate();
  double _temperature = 0.0;
  String _twelveVoltBattery = '0.0';
  Timer? _clockTimer;

  PhoenixChannel? _tempChannel;
  PhoenixChannel? _statusChannel;

  static String _formatTime() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
  }

  static String _formatDate() {
    final now = DateTime.now();
    return '${now.day.toString().padLeft(2, '0')}/'
        '${now.month.toString().padLeft(2, '0')}/'
        '${now.year}';
  }

  @override
  void initState() {
    super.initState();

    // Update clock every second
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _time = _formatTime();
          _date = _formatDate();
        });
      }
    });

    final socket = SocketService.socket;

    _tempChannel = socket.addChannel(
      topic: 'temperature',
      parameters: {'interval': 1000},
    );
    _statusChannel = socket.addChannel(
      topic: 'status',
      parameters: {'interval': 50},
    );

    socket.openStream.listen((_) {
      _tempChannel?.join();
      _statusChannel?.join();
    });

    if (socket.isOpen) {
      _tempChannel?.join();
      _statusChannel?.join();
    }

    _tempChannel?.messages.listen((event) {
      if (event.topic == 'temperature' &&
          event.payload != null &&
          event.payload!.containsKey('temperature')) {
        if (mounted) {
          setState(() {
            _temperature = (event.payload!['temperature'] as num).toDouble();
          });
        }
      }
    });

    _statusChannel?.messages.listen((event) {
      if (event.topic == 'status' &&
          event.payload != null &&
          event.payload!.containsKey('attributes')) {
        if (mounted) {
          setState(() {
            _twelveVoltBattery =
                event.payload!['attributes']['twelveVoltBatteryStatus']
                    ?.toString() ??
                    '0.0';
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _tempChannel?.leave();
    _statusChannel?.leave();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
            '${_temperature.toStringAsFixed(1)}\u00B0C',
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
            '${_twelveVoltBattery}V',
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
