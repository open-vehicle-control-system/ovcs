import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:dashboard_flutter/services/socket_service.dart';

/// Centralized metrics service that manages a single WebSocket channel
/// and dispatches metric updates to subscribers.
///
/// Replaces the old pattern where each widget independently created
/// its own channel subscription.
class MetricsService extends ChangeNotifier {
  static final MetricsService _instance = MetricsService._internal();
  factory MetricsService() => _instance;

  PhoenixChannel? _channel;
  bool _joined = false;
  final Map<String, dynamic> _metrics = {};
  final Set<String> _subscribedKeys = {};
  StreamSubscription? _messageSubscription;
  StreamSubscription? _openSubscription;

  MetricsService._internal();

  /// Get the current value for a metric identified by module + key.
  dynamic getValue(String module, String key) {
    return _metrics['$module:$key'];
  }

  /// Subscribe to a metric. Sends subscribe message to the backend
  /// and starts receiving updates for this module+key pair.
  void subscribe(String module, String key) {
    final metricKey = '$module:$key';
    if (_subscribedKeys.contains(metricKey)) return;
    _subscribedKeys.add(metricKey);

    _ensureChannel();
    if (_joined) {
      _channel?.push('subscribe', {'module': module, 'key': key});
    }
  }

  /// Unsubscribe from a metric.
  void unsubscribe(String module, String key) {
    final metricKey = '$module:$key';
    if (!_subscribedKeys.contains(metricKey)) return;
    _subscribedKeys.remove(metricKey);
    _metrics.remove(metricKey);

    if (_joined) {
      _channel?.push('unsubscribe', {'module': module, 'key': key});
    }
  }

  void _ensureChannel() {
    if (_channel != null) return;

    final socket = SocketService.socket;
    _channel = socket.addChannel(
      topic: 'metrics',
      parameters: {'interval': 50},
    );

    _openSubscription = socket.openStream.listen((_) {
      _joinChannel();
    });

    // If socket is already open, join immediately
    if (socket.isConnected) {
      _joinChannel();
    }

    _messageSubscription = _channel?.messages.listen((event) {
      if (event.topic == 'metrics' && event.payload != null) {
        final data = event.payload!['data'] as List<dynamic>?;
        if (data != null) {
          for (final metric in data) {
            final module = metric['module'] as String;
            final key = metric['key'] as String;
            final value = metric['value'];
            _metrics['$module:$key'] = value;
          }
          notifyListeners();
        }
      }
    });
  }

  void _joinChannel() {
    if (_joined) return;
    _channel?.join().future.then((_) {
      _joined = true;
      // Re-subscribe to all previously registered metrics
      for (final metricKey in _subscribedKeys) {
        final parts = metricKey.split(':');
        _channel?.push('subscribe', {'module': parts[0], 'key': parts[1]});
      }
    });
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _openSubscription?.cancel();
    _channel?.leave();
    _channel = null;
    _joined = false;
    super.dispose();
  }
}
