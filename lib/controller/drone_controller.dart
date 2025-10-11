import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:logging/logging.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as status;
import '../../constants.dart';

enum ConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  error,
}

class DroneStatus {
  final ConnectionState connectionState;
  final String message;
  final double? servoAngle;
  final bool? ledState;
  final DateTime timestamp;

  DroneStatus({
    required this.connectionState,
    required this.message,
    this.servoAngle,
    this.ledState,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isConnected => connectionState == ConnectionState.connected;
  
  @override
  String toString() => 'DroneStatus(state: $connectionState, message: $message, angle: $servoAngle, led: $ledState)';
}

class ControlValues {
  final double throttle;
  final double yaw;
  final double forward;
  final double lateral;

  const ControlValues({
    required this.throttle,
    required this.yaw,
    required this.forward,
    required this.lateral,
  });

  ControlValues clamp() => ControlValues(
    throttle: throttle.clamp(-1.0, 1.0),
    yaw: yaw.clamp(-1.0, 1.0),
    forward: forward.clamp(-1.0, 1.0),
    lateral: lateral.clamp(-1.0, 1.0),
  );

  bool differenceExceeds(ControlValues other, double threshold) {
    return (throttle - other.throttle).abs() > threshold ||
           (yaw - other.yaw).abs() > threshold ||
           (forward - other.forward).abs() > threshold ||
           (lateral - other.lateral).abs() > threshold;
  }

  @override
  String toString() => 'Control(t:${throttle.toStringAsFixed(2)}, y:${yaw.toStringAsFixed(2)}, f:${forward.toStringAsFixed(2)}, l:${lateral.toStringAsFixed(2)})';
}

class DroneController {
  final Logger log = Logger('DroneController');
  
  // Callbacks
  final Function(DroneStatus) onStatusChanged;
  final Function(String message, {bool isError})? onLogMessage;
  
  // WebSocket
  IOWebSocketChannel? _channel;
  Timer? _reconnectTimer;
  Timer? _controlTimer;
  Timer? _heartbeatTimer;
  Timer? _servoCommandTimer;
  Timer? _connectionTimeoutTimer;
  
  // Connection state
  ConnectionState _connectionState = ConnectionState.disconnected;
  int _retries = 0;
  int _consecutiveFailures = 0;
  final int maxRetries = 10;
  final int maxConsecutiveFailures = 5;
  
  // Control state
  ControlValues _lastControl = const ControlValues(throttle: 0, yaw: 0, forward: 0, lateral: 0);
  double _lastServoAngle = 0.0;
  double _currentServoAngle = 0.0;
  bool _currentLedState = false;
  
  // Configuration
  static const Duration controlInterval = Duration(milliseconds: 100);
  static const Duration heartbeatInterval = Duration(seconds: 30);
  static const Duration reconnectDelay = Duration(seconds: 3);
  static const Duration connectTimeout = Duration(seconds: 10);
  static const Duration connectionCheckDelay = Duration(seconds: 2);
  static const Duration servoCommandDelay = Duration(milliseconds: 100);
  static const double controlThreshold = 0.02;
  
  // Connection health tracking
  DateTime _lastMessageTime = DateTime.now();
  static const Duration connectionTimeoutThreshold = Duration(seconds: 45);

  DroneController({
    required this.onStatusChanged,
    this.onLogMessage,
  });

  // Getters
  bool get isConnected => _connectionState == ConnectionState.connected;
  ConnectionState get connectionState => _connectionState;
  double get currentServoAngle => _currentServoAngle;
  bool get currentLedState => _currentLedState;
  String get connectionInfo => '${AppConfig.droneIP}:${AppConfig.websocketPort}';

  void _logMessage(String message, {bool isError = false}) {
    if (isError) {
      log.severe(message);
    } else {
      log.info(message);
    }
    onLogMessage?.call(message, isError: isError);
  }

  void _updateStatus(ConnectionState state, String message, {double? angle, bool? led}) {
    _connectionState = state;
    
    if (angle != null) _currentServoAngle = angle;
    if (led != null) _currentLedState = led;
    
    final status = DroneStatus(
      connectionState: state,
      message: message,
      servoAngle: _currentServoAngle,
      ledState: _currentLedState,
    );
    
    _logMessage('Status: $status');
    onStatusChanged(status);
  }

  Future<void> connect() async {
    // 如果已經連線成功，則不重新連線
    if (isConnected) {
      _logMessage('Already connected, skipping connect attempt');
      return;
    }
    
    _logMessage('Initiating connection (Attempt ${_retries + 1}/${maxRetries + 1})');
    _updateStatus(ConnectionState.connecting, 'Connecting to $connectionInfo...');
    
    await disconnect();
    
    final trimmedIP = AppConfig.droneIP.trim();
    final uri = 'ws://$trimmedIP:${AppConfig.websocketPort}';
    
    _logMessage('Connecting to $uri');
    
    try {
      // Cancel any existing connection timeout timer
      _connectionTimeoutTimer?.cancel();
      
      // Create connection with proper configuration
      _channel = IOWebSocketChannel.connect(
        Uri.parse(uri),
        pingInterval: const Duration(seconds: 30),  // Increased ping interval
        connectTimeout: connectTimeout,
      );

      // Set up a connection timeout timer
      _connectionTimeoutTimer = Timer(connectTimeout, () {
        if (_connectionState == ConnectionState.connecting) {
          _logMessage('Connection timeout after ${connectTimeout.inSeconds} seconds', isError: true);
          _handleConnectionError('Connection timeout');
        }
      });
      
      _setupWebSocketListeners();
      
      // Wait for connection to establish
      await Future.delayed(connectionCheckDelay);
      
      if (_connectionState == ConnectionState.connecting) {
        // Check if we're actually connected
        if (_channel != null) {
          _updateStatus(ConnectionState.connected, 'Connected to $connectionInfo');
          _retries = 0;
          _consecutiveFailures = 0;
          _startHeartbeat();
          
          // Cancel the connection timeout timer since we're connected
          _connectionTimeoutTimer?.cancel();
          
          // Request initial status
          _requestStatus();
        } else {
          _handleConnectionError('Connection failed - channel is null');
        }
      }
      
    } catch (e, stackTrace) {
      // Cancel the connection timeout timer on error
      _connectionTimeoutTimer?.cancel();
      _logMessage('Connection failed: $e', isError: true);
      log.severe('Connection error details', e, stackTrace);
      _handleConnectionError('Failed to connect: $e');
    }
  }

  void _setupWebSocketListeners() {
    _channel!.stream.listen(
      _handleWebSocketMessage,
      onDone: _handleWebSocketClosed,
      onError: _handleWebSocketError,
      cancelOnError: false,
    );
  }

  void _handleWebSocketMessage(dynamic data) {
    try {
      // Update last message time
      _lastMessageTime = DateTime.now();
      
      final response = jsonDecode(data.toString());
      _logMessage('Received: $response');
      
      // Reset consecutive failures on successful message
      _consecutiveFailures = 0;
      
      // Cancel connection timeout timer if still active
      _connectionTimeoutTimer?.cancel();
      
      final status = response['status'];
      final message = response['message'];
      final angle = response['angle']?.toDouble();
      final led = response['led'];
      
      switch (status) {
        case 'received':
        case 'ok':
          if (_connectionState != ConnectionState.connected) {
            _updateStatus(ConnectionState.connected, 'Connected and operational');
          }
          // Always update LED state if it's present (even if null)
          if (angle != null || led != null) {
            _updateStatus(_connectionState, 'Status updated', angle: angle, led: led);
          }
          break;
          
        case 'error':
          // Don't treat command errors as critical connection errors
          if (message != null && (message.contains('status_request') || message.contains('未知消息類型'))) {
            _logMessage('Status request not supported by server (this is OK)', isError: false);
          } else if (message != null && message.contains('REQUEST_SERVO_ANGLE')) {
            _logMessage('REQUEST_SERVO_ANGLE command not supported (this is OK)', isError: false);
          } else if (message != null && message.contains('led_control')) {
            _logMessage('LED command format error (this is OK)', isError: false);
          } else {
            _logMessage('Server error: $message', isError: true);
          }
          // Even on error, update LED state if provided
          if (led != null) {
            _updateStatus(_connectionState, 'Status updated with error', angle: angle, led: led);
          }
          break;
          
        default:
          _logMessage('Unknown response status: $status');
          break;
      }
      
    } catch (e) {
      _logMessage('Failed to parse server response: $e', isError: true);
    }
  }

  void _handleWebSocketClosed() {
    final closeCode = _channel?.closeCode;
    final closeReason = _channel?.closeReason;
    _logMessage('WebSocket closed: $closeCode $closeReason');
    
    // Cancel all timers
    _stopHeartbeat();
    _connectionTimeoutTimer?.cancel();
    
    _updateStatus(ConnectionState.disconnected, 'Connection closed');
    
    // Don't auto-reconnect if it was a clean close
    if (closeCode != status.goingAway && closeCode != status.normalClosure) {
      _scheduleReconnect('Connection closed unexpectedly with code $closeCode: $closeReason');
    }
  }

  void _handleWebSocketError(error, stackTrace) {
    _consecutiveFailures++;
    _logMessage('WebSocket error: $error', isError: true);
    log.severe('WebSocket error details', error, stackTrace);
    
    // Cancel connection timeout timer on error
    _connectionTimeoutTimer?.cancel();
    
    _stopHeartbeat();
    
    // Don't immediately mark as error for minor issues
    if (_consecutiveFailures < maxConsecutiveFailures) {
      _logMessage('Minor WebSocket error, will retry...', isError: false);
      _scheduleReconnect('WebSocket error: $error');
    } else {
      _handleConnectionError('Connection error: $error');
    }
  }

  void _handleConnectionError(String error) {
    _consecutiveFailures++;
    _logMessage('Connection error ($_consecutiveFailures consecutive): $error', isError: _consecutiveFailures >= 3);
    
    // Cancel connection timeout timer
    _connectionTimeoutTimer?.cancel();
    
    // Only mark as error state after multiple consecutive failures
    if (_consecutiveFailures >= 3) {
      _updateStatus(ConnectionState.error, error);
    }
    
    if (_consecutiveFailures >= maxConsecutiveFailures) {
      _logMessage('Too many consecutive failures, extending retry delay', isError: true);
    }
    
    _scheduleReconnect(error);
  }

  void _scheduleReconnect(String reason) {
    // Cancel any existing reconnect timer
    _reconnectTimer?.cancel();
    
    if (_retries >= maxRetries) {
      _updateStatus(ConnectionState.error, 'Max retry attempts reached. Manual reconnection required.');
      return;
    }
    
    _retries++;
    _updateStatus(ConnectionState.reconnecting, 'Reconnecting in ${reconnectDelay.inSeconds}s... ($reason)');
    
    // Exponential backoff with maximum limit
    Duration delay;
    if (_consecutiveFailures >= maxConsecutiveFailures) {
      delay = Duration(seconds: reconnectDelay.inSeconds * 5);
    } else if (_consecutiveFailures >= maxConsecutiveFailures ~/ 2) {
      delay = Duration(seconds: reconnectDelay.inSeconds * 3);
    } else if (_retries > maxRetries ~/ 2) {
      delay = Duration(seconds: reconnectDelay.inSeconds * 2);
    } else {
      delay = reconnectDelay;
    }
    
    // Cap the maximum delay to prevent excessively long waits
    if (delay.inSeconds > 30) {
      delay = const Duration(seconds: 30);
    }
    
    // Add some jitter to prevent thundering herd
    final jitter = Duration(milliseconds: (delay.inMilliseconds * (0.1 * (math.Random().nextDouble() - 0.5))).toInt());
    final finalDelay = delay + jitter;
    
    _logMessage('Scheduled reconnect in ${finalDelay.inSeconds} seconds');
    _reconnectTimer = Timer(finalDelay, connect);
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (timer) {
      if (!isConnected) {
        timer.cancel();
        return;
      }
      
      // Check connection health
      final timeSinceLastMessage = DateTime.now().difference(_lastMessageTime);
      if (timeSinceLastMessage > connectionTimeoutThreshold) {
        _logMessage('Connection appears stale (no messages for ${timeSinceLastMessage.inSeconds}s), triggering reconnect', isError: true);
        _scheduleReconnect('Connection stale');
        return;
      }
      
      _requestStatus();
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _requestStatus() {
    _sendMessage({
      'type': 'status_request',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    }, logMessage: false);
  }

  bool _sendMessage(Map<String, dynamic> message, {bool logMessage = true}) {
    if (!isConnected || _channel == null) {
      if (logMessage) {
        _logMessage('Cannot send message: not connected', isError: true);
      }
      return false;
    }

    try {
      final jsonMessage = jsonEncode(message);
      _channel!.sink.add(jsonMessage);
      
      if (logMessage) {
        _logMessage('Sent: $message');
      }
      return true;
    } catch (e) {
      _logMessage('Failed to send message: $e', isError: true);
      return false;
    }
  }

  // Public control methods
  bool sendCommand(String action) {
    return _sendMessage({
      'type': 'command',
      'action': action,
    });
  }

  bool sendLedCommand(String action) {
    return _sendMessage({
      'type': 'command',
      'action': action,
    });
  }

  bool sendServoAngle(double angle) {
    final clampedAngle = angle.clamp(-45.0, 90.0);
    // Increase threshold to reduce unnecessary updates and jitter
    if ((clampedAngle - _lastServoAngle).abs() < 1.0) {
      return true; // Skip if change is too small
    }
    
    // Prevent flooding servo commands
    if (_servoCommandTimer?.isActive ?? false) {
      return false; // Skip if we're still waiting from previous command
    }
    
    _lastServoAngle = clampedAngle;
    final result = _sendMessage({
      'type': 'servo_control',
      'angle': clampedAngle,
    });
    
    // Set timer to prevent next command until delay has passed
    _servoCommandTimer = Timer(servoCommandDelay, () {});
    
    return result;
  }

  bool sendServoSpeed(double speed) {
    // Convert speed to angle change
    final angleChange = speed * 2.0; // Adjust multiplier as needed
    final newAngle = (_currentServoAngle + angleChange).clamp(-45.0, 90.0);
    return sendServoAngle(newAngle);
  }

  void startContinuousControl(double throttle, double yaw, double forward, double lateral) {
    final control = ControlValues(
      throttle: throttle,
      yaw: yaw,
      forward: forward,
      lateral: lateral,
    ).clamp();

    if (_controlTimer == null) {
      // Start new control timer
      _controlTimer = Timer.periodic(controlInterval, (timer) {
        _sendControlUpdate();
      });
    }

    // Update control values if they've changed significantly
    if (control.differenceExceeds(_lastControl, controlThreshold)) {
      _lastControl = control;
    }
  }

  void _sendControlUpdate() {
    if (!isConnected) {
      stopContinuousControl();
      return;
    }

    _sendMessage({
      'type': 'control',
      'throttle': _lastControl.throttle,
      'yaw': _lastControl.yaw,
      'forward': _lastControl.forward,
      'lateral': _lastControl.lateral,
    }, logMessage: false);
  }

  void stopContinuousControl() {
    _controlTimer?.cancel();
    _controlTimer = null;
    
    // Send neutral control values
    if (isConnected) {
      _sendMessage({
        'type': 'control',
        'throttle': 0.0,
        'yaw': 0.0,
        'forward': 0.0,
        'lateral': 0.0,
      });
    }
    
    _lastControl = const ControlValues(throttle: 0, yaw: 0, forward: 0, lateral: 0);
  }

  // Emergency stop
  void emergencyStop() {
    stopContinuousControl();
    sendCommand('DISARM');
    _logMessage('EMERGENCY STOP ACTIVATED', isError: true);
  }

  void dispose() {
    _logMessage('Disposing DroneController...');
    disconnect();
    _servoCommandTimer?.cancel(); // Cancel servo command timer
  }

  Future<void> disconnect() async {
    _logMessage('Disconnecting...');
    
    // Cancel all timers
    _reconnectTimer?.cancel();
    _controlTimer?.cancel();
    _heartbeatTimer?.cancel();
    _servoCommandTimer?.cancel();
    _connectionTimeoutTimer?.cancel();
    
    // Close WebSocket
    if (_channel != null) {
      try {
        await _channel!.sink.close(status.normalClosure, 'Normal closure');
      } catch (e) {
        _logMessage('Error during disconnect: $e');
      }
      _channel = null;
    }
    
    // Reset state
    _retries = 0;
    _consecutiveFailures = 0;
    _lastControl = const ControlValues(throttle: 0, yaw: 0, forward: 0, lateral: 0);
    
    _updateStatus(ConnectionState.disconnected, 'Disconnected');
  }

  void resetConnection() {
    _retries = 0;
    _consecutiveFailures = 0;
    connect();
  }

  // Add method to check connection health
  bool isConnectionHealthy() {
    if (!isConnected) return false;
    
    final timeSinceLastMessage = DateTime.now().difference(_lastMessageTime);
    return timeSinceLastMessage < connectionTimeoutThreshold;
  }

  // Add method to force reconnect
  void forceReconnect() {
    _logMessage('Forcing reconnection...');
    _consecutiveFailures = 0;
    _retries = 0;
    connect();
  }

  // Utility methods
  String getConnectionSummary() {
    return '''
Connection: $connectionInfo
State: $_connectionState
Retries: $_retries/$maxRetries
Consecutive Failures: $_consecutiveFailures
Servo Angle: ${_currentServoAngle.toStringAsFixed(1)}°
LED State: ${_currentLedState ? 'ON' : 'OFF'}
''';
  }
}