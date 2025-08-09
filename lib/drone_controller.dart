import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:web_socket_channel/io.dart';
import 'constants.dart';

class DroneController {
  final Logger log = Logger('DroneController');
  final Function(String, bool, [double? angle, bool? led]) onStatusChanged;
  IOWebSocketChannel? _channel;
  Timer? _reconnectTimer;
  Timer? _controlTimer;
  int _retries = 0;
  final int maxRetries = 5;
  bool _isWebSocketConnected = false;
  String connectionStatus = 'Disconnected';
  double _lastThrottle = 0.0;
  double _lastYaw = 0.0;
  double _lastForward = 0.0;
  double _lastLateral = 0.0;
  double _lastSpeed = 0.0;

  DroneController({required this.onStatusChanged});

  void _updateStatus(String status, bool connected, [double? angle, bool? led]) {
    _isWebSocketConnected = connected;
    connectionStatus = status;
    onStatusChanged(status, connected, angle, led);
  }

  Future<void> connect() async {
    if (_isWebSocketConnected) {
      log.info('Already connected, skipping connect attempt');
      return;
    }

    _channel?.sink.close();
    _channel = null;
    _reconnectTimer?.cancel();

    String trimmedIP = AppConfig.droneIP.trim();
    log.info('Attempting connection to ws://$trimmedIP:${AppConfig.websocketPort} (Retry $_retries/$maxRetries)');
    try {
      _updateStatus('Connecting...', false);
      _channel = IOWebSocketChannel.connect(
        Uri.parse('ws://$trimmedIP:${AppConfig.websocketPort}'),
        pingInterval: const Duration(seconds: 5),
        connectTimeout: const Duration(seconds: 10),
      );

      log.info('Connection initiated');

      _channel!.stream.listen(
            (data) {
          log.info('Data received: $data');
          try {
            var response = jsonDecode(data);
            if (response['status'] == 'received' || response['status'] == 'ok') {
              _updateStatus('Connected', true, response['angle']?.toDouble(), response['led']);
            } else if (response['status'] == 'error') {
              _updateStatus('Error: ${response['message']}', true);
            }
          } catch (e) {
            log.severe('解析消息失敗: $e');
          }
        },
        onDone: () {
          log.warning('WebSocket closed: ${_channel?.closeCode} ${_channel?.closeReason}');
          _updateStatus('Disconnected', false);
          _scheduleReconnect();
        },
        onError: (error, stackTrace) {
          log.severe('WebSocket stream error: $error', error, stackTrace);
          _updateStatus('Error: WebSocket stream error: $error', false);
          _scheduleReconnect();
        },
        cancelOnError: true,
      );

      await Future.delayed(const Duration(milliseconds: 500));
      if (_channel != null && connectionStatus == 'Connecting...') {
        _updateStatus('Connected', true);
      }
    } catch (e, stackTrace) {
      log.severe('WebSocket connect error: $e', e, stackTrace);
      _updateStatus('Error: Failed to connect to WebSocket: $e', false);
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_retries >= maxRetries) {
      _updateStatus('Error: Max retries reached', false);
      return;
    }
    _retries++;
    log.info('Scheduling reconnect attempt in 5 seconds');
    _reconnectTimer = Timer(const Duration(seconds: 5), connect);
  }

  void sendCommand(String action) {
    if (!_isWebSocketConnected || _channel == null) {
      log.warning('Cannot send command: WebSocket not connected');
      return;
    }
    final message = jsonEncode({'type': 'command', 'action': action});
    _channel!.sink.add(message);
    log.info('Sent command: $message');
  }

  void sendLedCommand(String action) {
    if (!_isWebSocketConnected || _channel == null) {
      log.warning('Cannot send LED command: WebSocket not connected');
      return;
    }
    final message = jsonEncode({'type': 'command', 'action': action});
    _channel!.sink.add(message);
    log.info('Sent LED command: $message');
  }

  void sendServoSpeed(double speed) {
    if (!_isWebSocketConnected || _channel == null) {
      log.warning('無法發送伺服速度：WebSocket未連線');
      return;
    }
    if ((speed - _lastSpeed).abs() > 0.01) {
      final message = jsonEncode({'type': 'servo_speed', 'speed': speed.clamp(-1.0, 1.0)});
      _channel!.sink.add(message);
      log.info('發送伺服速度：${(speed * 100).toStringAsFixed(1)}%');
      _lastSpeed = speed;
    }
  }

  void sendServoAngle(double angle) {
    if (!_isWebSocketConnected || _channel == null) {
      log.warning('Cannot send servo angle: WebSocket not connected');
      return;
    }
    // Align with server protocol: use 'servo_control' and clamp to [-45, 90]
    final message = jsonEncode({'type': 'servo_control', 'angle': angle.clamp(-45.0, 90.0)});
    _channel!.sink.add(message);
    log.info('Sent servo angle: ${angle.toStringAsFixed(1)}°');
  }

  void requestServoAngle() {
    if (!_isWebSocketConnected || _channel == null) {
      log.warning('Cannot request servo angle: WebSocket not connected');
      return;
    }
    final message = jsonEncode({'type': 'request_angle'});
    _channel!.sink.add(message);
    log.info('Requested servo angle');
  }

  void startSendingControl(double throttle, double yaw, double forward, double lateral) {
    _controlTimer?.cancel();
    _controlTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (!_isWebSocketConnected || _channel == null) {
        timer.cancel();
        return;
      }
      const threshold = 0.05;
      if ((throttle - _lastThrottle).abs() > threshold ||
          (yaw - _lastYaw).abs() > threshold ||
          (forward - _lastForward).abs() > threshold ||
          (lateral - _lastLateral).abs() > threshold) {
        final message = jsonEncode({
          'type': 'control',
          'throttle': throttle.clamp(-1.0, 1.0),
          'yaw': yaw.clamp(-1.0, 1.0),
          'forward': forward.clamp(-1.0, 1.0),
          'lateral': lateral.clamp(-1.0, 1.0),
        });
        _channel!.sink.add(message);
        _lastThrottle = throttle;
        _lastYaw = yaw;
        _lastForward = forward;
        _lastLateral = lateral;
      }
    });
  }

  void stopSendingControl() {
    _controlTimer?.cancel();
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _controlTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _retries = 0;
    _updateStatus('Disconnected', false);
  }

  void dispose() {
    disconnect();
  }
}