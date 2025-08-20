import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:latlong2/latlong.dart';
import 'package:logging/logging.dart';

// 導入重構後的模組
import '../controllers/drone_controller.dart';
import '../models/drone_status.dart';
import '../models/control_values.dart';
import '../services/location_service.dart';
import '../services/recoding_service.dart';
import '../services/viedo_stream_service.dart';
import '../utils/control_utils.dart';
import '../utils/animation_utils.dart';
import '../widgets/dialogs/recoding_option_dialog.dart';
import '../widgets/maps/drone_mini_map.dart';
import '../widgets/ui/top_status_bar.dart';
import '../widgets/ui/bottom_control_area.dart';
import '../widgets/ui/servo_slider.dart';
import '../widgets/dialogs/menu_dialog.dart';
import '../constants.dart';
import '../main.dart';
import 'drone_display_only_page.dart';
import 'home.dart';

class DroneJoystickPage extends StatefulWidget {
  const DroneJoystickPage({super.key});

  @override
  State<DroneJoystickPage> createState() => _DroneJoystickPageState();
}

class _DroneJoystickPageState extends State<DroneJoystickPage>
    with TickerProviderStateMixin {
  final Logger log = Logger('DroneJoystickPage');

  // Controllers and Services
  late final DroneController _droneController;
  late final VideoStreamService _videoService;
  late final RecordingService _recordingService;
  late final LocationService _locationService;

  // Animation Controllers
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // State Models
  DroneStatus _droneStatus = DroneStatus();
  ControlValues _controlValues = ControlValues();

  // UI State
  Uint8List? _currentFrame;
  LatLng? _dronePosition;
  String selectedMode = '顯示加控制';
  String droneIP = AppConfig.droneIP;
  DateTime? _lastServoUiUpdate;

  // Timers
  Timer? _debounceTimer;
  Timer? _controlDebounceTimer;
  Timer? _anglePollTimer;

  // Subscriptions
  StreamSubscription? _frameSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _recordingSubscription;
  StreamSubscription? _messageSubscription;
  StreamSubscription? _locationSubscription;

  @override
  void initState() {
    super.initState();
    _initializeSystemUI();
    _initializeServices();
    _initializeAnimations();
    _setupSubscriptions();
    _connectServices();
    _startLocationTracking();
  }

  void _initializeSystemUI() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _initializeServices() {
    _droneController = DroneController(onStatusChanged: _onDroneStatusChanged);
    _videoService = VideoStreamService();
    _recordingService = RecordingService();
    _locationService = LocationService();
  }

  void _initializeAnimations() {
    _pulseController = AnimationUtils.createPulseController(this);
    _pulseAnimation = AnimationUtils.createPulseAnimation(_pulseController);
    _pulseController.repeat(reverse: true);
  }

  void _setupSubscriptions() {
    // Video stream subscription
    _frameSubscription = _videoService.frameStream.listen((frame) {
      setState(() {
        _currentFrame = frame;
      });
    });

    // Connection subscription
    _connectionSubscription = _videoService.connectionStream.listen((connected) {
      setState(() {
        _droneStatus = _droneStatus.copyWith(isCameraConnected: connected);
      });
    });

    // Recording subscription
    _recordingSubscription = _recordingService.recordingStream.listen((recording) {
      setState(() {
        _droneStatus = _droneStatus.copyWith(isRecording: recording);
      });
    });

    // Recording message subscription
    _messageSubscription = _recordingService.messageStream.listen((message) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    });

    // Location subscription
    _locationSubscription = _locationService.locationStream.listen((location) {
      setState(() {
        _dronePosition = location;
      });
    });
  }

  void _connectServices() {
    _droneController.connect();
    _videoService.connect();

    // Periodic servo angle polling
    _anglePollTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_droneStatus.isWebSocketConnected) {
        _droneController.requestServoAngle();
      }
    });
  }

  void _startLocationTracking() async {
    final currentLocation = await _locationService.getCurrentLocation();
    if (currentLocation != null) {
      setState(() {
        _dronePosition = currentLocation;
      });
    }
    _locationService.startLocationTracking();
  }

  void _onDroneStatusChanged(String status, bool connected, [double? angle, bool? led]) {
    setState(() {
      _droneStatus = _droneStatus.copyWith(isWebSocketConnected: connected);

      if (angle != null && angle >= -45.0 && angle <= 90.0) {
        if (!_droneStatus.isDraggingServo) {
          final now = DateTime.now();
          if (_lastServoUiUpdate == null ||
              now.difference(_lastServoUiUpdate!).inMilliseconds > 150) {
            final current = _droneStatus.servoAngle ?? 0.0;
            final filtered = current + (angle - current) * 0.2;
            _droneStatus = _droneStatus.copyWith(
              servoAngle: double.parse(filtered.toStringAsFixed(2)),
            );
            _lastServoUiUpdate = now;
          }
        }
      }

      if (led != null) {
        _droneStatus = _droneStatus.copyWith(ledEnabled: led);
      }
    });

    log.info('WebSocket 狀態: $status, 連線: $connected');
    if (led != null) {
      log.info('LED 狀態更新: $led');
    }
  }

  void _updateControlValues(JoystickMode mode, double x, double y) {
    _controlDebounceTimer?.cancel();
    _controlDebounceTimer = Timer(const Duration(milliseconds: 25), () {
      setState(() {
        double inX = ControlUtils.applyDeadzone(x);
        double inY = ControlUtils.applyDeadzone(-y); // y軸反向

        inX = ControlUtils.applyExpo(inX, expo: 0.35);
        inY = ControlUtils.applyExpo(inY, expo: 0.35);

        if (mode == JoystickMode.all) {
          // 根據是左搖桿還是右搖桿來決定控制哪個軸
          // 這裡需要根據實際UI佈局調整
          _controlValues = _controlValues.copyWith(
            throttle: inY,
            yaw: inX,
          );
        } else {
          _controlValues = _controlValues.copyWith(
            forward: inY,
            lateral: inX,
          );
        }

        // 平滑控制值
        const smoothing = 0.25;
        _controlValues = _controlValues.copyWith(
          smoothedThrottle: ControlUtils.lerp(_controlValues.smoothedThrottle, _controlValues.throttle, smoothing),
          smoothedYaw: ControlUtils.lerp(_controlValues.smoothedYaw, _controlValues.yaw, smoothing),
          smoothedForward: ControlUtils.lerp(_controlValues.smoothedForward, _controlValues.forward, smoothing),
          smoothedLateral: ControlUtils.lerp(_controlValues.smoothedLateral, _controlValues.lateral, smoothing),
        );

        if (_droneStatus.isWebSocketConnected) {
          _droneController.startSendingControl(
            _controlValues.smoothedThrottle,
            _controlValues.smoothedYaw,
            _controlValues.smoothedForward,
            _controlValues.smoothedLateral,
          );
        } else {
          _droneController.stopSendingControl();
        }
      });
    });
  }

  void _updateServoAngle(double newAngle) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 60), () {
      setState(() {
        final clampedAngle = ControlUtils.clampAngle(newAngle);
        if ((clampedAngle - (_droneStatus.servoAngle ?? 0.0)).abs() > 0.5) {
          _droneStatus = _droneStatus.copyWith(servoAngle: clampedAngle);
          if (_droneStatus.isWebSocketConnected) {
            _droneController.sendServoAngle(_droneStatus.servoAngle!);
            log.info('更新伺服角度：${_droneStatus.servoAngle!.toStringAsFixed(1)}°');
          }
        }
      });
    });
  }

  // Event Handlers
  void _handleBackPressed() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const Home()),
            (route) => false,
      );
      log.info('已跳轉到 Home 頁面');
    }
  }

  void _handleWebSocketPressed() {
    if (!_droneStatus.isWebSocketConnected) {
      _droneController.connect();
    }
  }

  void _handleCameraPressed() {
    if (_droneStatus.isCameraConnected) {
      _videoService.disconnect();
    } else {
      _videoService.connect();
    }
  }

  void _handleLedPressed() {
    if (_droneStatus.isWebSocketConnected) {
      _droneController.sendLedCommand('LED_TOGGLE');
      log.info('發送 LED 切換指令');
    } else {
      log.warning('WebSocket未連線，LED指令未發送');
    }
  }

  void _handleMenuPressed() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return MenuDialog(
          selectedMode: selectedMode,
          aiRecognitionEnabled: _droneStatus.aiRecognitionEnabled,
          aiRescueEnabled: _droneStatus.aiRescueEnabled,
          droneIP: droneIP,
          onModeChanged: _onModeChanged,
          onAiRecognitionChanged: _onAiRecognitionChanged,
          onAiRescueChanged: _onAiRescueChanged,
          onDroneIPChanged: _onDroneIPChanged,
          ledButton: _buildLedButton(),
        );
      },
    );
  }

  void _onModeChanged(String mode) {
    setState(() {
      selectedMode = mode;
    });
    if (mode == '僅顯示') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const DroneDisplayOnlyPage()),
      );
    }
  }

  void _onAiRecognitionChanged(bool enabled) {
    setState(() {
      _droneStatus = _droneStatus.copyWith(aiRecognitionEnabled: enabled);
    });
  }

  void _onAiRescueChanged(bool enabled) {
    setState(() {
      _droneStatus = _droneStatus.copyWith(aiRescueEnabled: enabled);
    });
  }

  void _onDroneIPChanged(String ip) {
    setState(() {
      droneIP = ip;
      AppConfig.droneIP = ip;
    });
    _droneController.disconnect();
    _droneController.connect();
    _videoService.disconnect();
    _videoService.connect();
  }

  void _handleRecordingPressed() {
    if (_droneStatus.isRecording) {
      _recordingService.stopRecording();
    } else {
      _recordingService.startRecording();
    }
  }

  void _handleRecordingOptionsPressed() {
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.3),
      builder: (BuildContext context) {
        return const RecordingOptionsDialog();
      },
    );
  }

  void _handleServoTap() {
    if (!_droneStatus.isWebSocketConnected) return;
    setState(() {
      _droneStatus = _droneStatus.copyWith(servoAngle: 0.0);
    });
    _droneController.sendServoAngle(0.0);
    log.info('伺服角度歸零');
  }

  void _handleServoPanStart(DragStartDetails details) {
    if (!_droneStatus.isWebSocketConnected) return;
    setState(() {
      _droneStatus = _droneStatus.copyWith(isDraggingServo: true);
    });
    log.info('開始拖拽伺服控制');
  }

  void _handleServoPanUpdate(DragUpdateDetails details) {
    if (!_droneStatus.isWebSocketConnected || !_droneStatus.isDraggingServo) return;

    setState(() {
      double sensitivity = 0.5;
      double newAngle = (_droneStatus.servoAngle ?? 0.0) - details.delta.dy * sensitivity;
      _droneStatus = _droneStatus.copyWith(
        servoAngle: ControlUtils.clampAngle(newAngle),
      );
    });

    _updateServoAngle(_droneStatus.servoAngle!);
  }

  void _handleServoPanEnd(DragEndDetails details) {
    setState(() {
      _droneStatus = _droneStatus.copyWith(isDraggingServo: false);
    });
    log.info('結束拖拽伺服控制');
  }

  void _handleArmPressed() {
    _droneController.sendCommand('ARM');
  }

  void _handleDisarmPressed() {
    _droneController.sendCommand('DISARM');
  }

  void _resetJoystickValues({bool throttleYaw = false, bool forwardLateral = false}) {
    setState(() {
      if (throttleYaw) {
        _controlValues = _controlValues.copyWith(throttle: 0.0, yaw: 0.0);
        if (_droneStatus.isWebSocketConnected) {
          _controlValues = _controlValues.copyWith(
            smoothedThrottle: ControlUtils.lerp(_controlValues.smoothedThrottle, 0, 0.6),
            smoothedYaw: ControlUtils.lerp(_controlValues.smoothedYaw, 0, 0.6),
          );
        }
      }
      if (forwardLateral) {
        _controlValues = _controlValues.copyWith(forward: 0.0, lateral: 0.0);
        if (_droneStatus.isWebSocketConnected) {
          _controlValues = _controlValues.copyWith(
            smoothedForward: ControlUtils.lerp(_controlValues.smoothedForward, 0, 0.6),
            smoothedLateral: ControlUtils.lerp(_controlValues.smoothedLateral, 0, 0.6),
          );
        }
      }

      if (_droneStatus.isWebSocketConnected) {
        _droneController.startSendingControl(
          _controlValues.smoothedThrottle,
          _controlValues.smoothedYaw,
          _controlValues.smoothedForward,
          _controlValues.smoothedLateral,
        );
      }
    });
  }

  Widget _buildLedButton() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _droneStatus.ledEnabled
            ? Colors.yellow.withOpacity(0.3)
            : Colors.grey.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        Icons.lightbulb,
        color: _droneStatus.ledEnabled ? Colors.yellow : Colors.grey,
        size: 20,
      ),
    );
  }

  Widget _buildVideoStream() {
    return _currentFrame != null
        ? Transform.rotate(
      angle: math.pi,
      child: Image.memory(
        _currentFrame!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => Container(
          color: Colors.black,
          child: const Center(
            child: Text(
              '視訊解碼錯誤',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
      ),
    )
        : Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _pulseAnimation.value,
                  child: const CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    strokeWidth: 3,
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    // Cancel timers
    _debounceTimer?.cancel();
    _controlDebounceTimer?.cancel();
    _anglePollTimer?.cancel();

    // Dispose animations
    _pulseController.dispose();

    // Cancel subscriptions
    _frameSubscription?.cancel();
    _connectionSubscription?.cancel();
    _recordingSubscription?.cancel();
    _messageSubscription?.cancel();
    _locationSubscription?.cancel();

    // Dispose services
    _droneController.dispose();
    _videoService.dispose();
    _recordingService.dispose();
    _locationService.dispose();

    // Reset system UI
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video Stream
            _buildVideoStream(),

            // Black overlay
            Container(color: Colors.black.withOpacity(0.1)),

            // Servo Slider
            ServoSlider(
              isWebSocketConnected: _droneStatus.isWebSocketConnected,
              servoAngle: _droneStatus.servoAngle,
              isDraggingServo: _droneStatus.isDraggingServo,
              onPanStart: _handleServoPanStart,
              onPanUpdate: _handleServoPanUpdate,
              onPanEnd: _handleServoPanEnd,
              onTap: _handleServoTap,
            ),

            // Top Status Bar
            TopStatusBar(
              isWebSocketConnected: _droneStatus.isWebSocketConnected,
              isCameraConnected: _droneStatus.isCameraConnected,
              isStreamLoaded: _droneStatus.isStreamLoaded,
              ledEnabled: _droneStatus.ledEnabled,
              pulseAnimation: _pulseAnimation,
              onBackPressed: _handleBackPressed,
              onWebSocketPressed: _handleWebSocketPressed,
              onCameraPressed: _handleCameraPressed,
              onLedPressed: _handleLedPressed,
              onMenuPressed: _handleMenuPressed,
            ),

            // Bottom Control Area
            BottomControlArea(
              isWebSocketConnected: _droneStatus.isWebSocketConnected,
              throttle: _controlValues.throttle,
              yaw: _controlValues.yaw,
              forward: _controlValues.forward,
              lateral: _controlValues.lateral,
              onJoystickUpdate: _updateControlValues,
              onThrottleYawEnd: () => _resetJoystickValues(throttleYaw: true),
              onForwardLateralEnd: () => _resetJoystickValues(forwardLateral: true),
              onArmPressed: _handleArmPressed,
              onDisarmPressed: _handleDisarmPressed,
            ),

            // Mini Map
            Positioned(
              left: 20,
              bottom: MediaQuery.of(context).size.height * 0.55,
              child: DroneMiniMap(
                dronePosition: _dronePosition,
                onTap: () {
                  // TODO: 點擊後可以切換成全螢幕地圖
                },
              ),
            ),

            // Recording Controls
            Positioned(
              right: 20,
              top: (MediaQuery.of(context).size.height - 60) / 2 - 50,
              child: IconButton(
                onPressed: _handleRecordingOptionsPressed,
                icon: const Icon(Icons.movie, color: Colors.white, size: 30),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withOpacity(0.3),
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(10),
                ),
                tooltip: '錄影選項',
              ),
            ),

            Positioned(
              right: 20,
              top: (MediaQuery.of(context).size.height - 60) / 2,
              child: RecordButton(
                isRecording: _droneStatus.isRecording,
                onTap: _handleRecordingPressed,
              ),
            ),
          ],
        ),
      ),
    );
  }
}