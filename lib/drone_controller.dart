import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:web_socket_channel/io.dart';
import 'constants.dart';

class DroneController {
  final Logger log = Logger('DroneController');
  final Function(String, bool, [double?]) onStatusChanged;
  IOWebSocketChannel? _channel;
  Timer? _reconnectTimer;
  Timer? _controlTimer;
  int _retries = 0;
  final int maxRetries = 5;
  bool _isWebSocketConnected = false;
  String connectionStatus = 'Disconnected';

  DroneController({required this.onStatusChanged});

  void _updateStatus(String status, bool connected, [double? angle]) {
    _isWebSocketConnected = connected;
    connectionStatus = status;
    onStatusChanged(status, connected, angle);
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
          var response = jsonDecode(data);
          if (response['status'] == 'received') {
            _updateStatus('Connected', true, response['angle']?.toDouble());
          } else if (response['status'] == 'error') {
            _updateStatus('Error: ${response['message']}', true);
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

  void sendServoControl(double angle) {
    if (!_isWebSocketConnected || _channel == null) {
      log.warning('Cannot send servo control: WebSocket not connected');
      return;
    }
    final message = jsonEncode({'type': 'servo_control', 'angle': angle});
    _channel!.sink.add(message);
    log.info('Sent servo control: $message');
  }

  void startSendingControl(double throttle, double yaw, double forward, double lateral) {
    _controlTimer?.cancel();
    _controlTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!_isWebSocketConnected || _channel == null) {
        timer.cancel();
        return;
      }
      final message = jsonEncode({
        'type': 'control',
        'throttle': throttle,
        'yaw': yaw,
        'forward': forward,
        'lateral': lateral,
      });
      _channel!.sink.add(message);
      // log.debug('Sent control: $message');
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