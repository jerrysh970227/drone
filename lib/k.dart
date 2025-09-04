import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:latlong2/latlong.dart' as latLng;
import 'package:logging/logging.dart';
import 'drone_controller.dart';
import 'constants.dart';
import 'Photo_mode_setting.dart';
import 'drone_display_only_page.dart';
import 'main.dart';

class DroneJoystickPage extends StatefulWidget {
  const DroneJoystickPage({super.key});

  @override
  State<DroneJoystickPage> createState() => _DroneJoystickPageState();
}

class _DroneJoystickPageState extends State<DroneJoystickPage>
    with TickerProviderStateMixin {
  bool _flashlightEnabled = false;
  bool _aiRecognitionEnabled = false;
  bool _aiRescueEnabled = false;
  bool _ledEnabled = false;
  bool _useSliderControl = false; // 控制伺服馬達方式（false: 螢幕滑動, true: 滑桿）
  final Logger log = Logger('DroneJoystickPage');
  late final DroneController _controller;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  String selectedMode = '顯示加控制';
  String droneIP = AppConfig.droneIP;
  double throttle = 0.0;
  double yaw = 0.0;
  double forward = 0.0;
  double lateral = 0.0;

  // 平滑後的控制值
  double _smoothedThrottle = 0.0;
  double _smoothedYaw = 0.0;
  double _smoothedForward = 0.0;
  double _smoothedLateral = 0.0;
  double? _servoAngle = 0.0;
  bool _isDraggingServo = false;
  bool isCameraConnected = false;
  bool isStreamLoaded = false;
  bool isWebSocketConnected = false;
  bool isRecording = false;
  Uint8List? _currentFrame;
  List<int> _buffer = [];
  Socket? _socket;
  StreamSubscription? _socketSubscription;
  Timer? _debounceTimer; // 伺服用
  Timer? _controlDebounceTimer; // 控制用
  Timer? _anglePollTimer;
  DateTime? _lastServoUiUpdate;
  LatLng? dronePosition;
  bool isFullScreen = false;
  late AnimationController _fullScreenController;
  late Animation<double> _fullScreenAnimation;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    ));

    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat(reverse: true);

    _fullScreenController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fullScreenAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fullScreenController, curve: Curves.easeInOut),
    );

    _controller = DroneController(
      onStatusChanged: (status, connected, [angle, led, gpsData]) {
        setState(() {
          isWebSocketConnected = connected;
          log.info('WebSocket 狀態: $status, 連線: $connected');
          if (angle != null && angle >= -45.0 && angle <= 90.0) {
            if (!_isDraggingServo) {
              final now = DateTime.now();
              if (_lastServoUiUpdate == null ||
                  now.difference(_lastServoUiUpdate!).inMilliseconds > 150) {
                final current = _servoAngle ?? 0.0;
                final filtered = current + (angle - current) * 0.2;
                _servoAngle = double.parse(filtered.toStringAsFixed(2));
                _lastServoUiUpdate = now;
              }
            }
          }
          if (led != null) {
            _ledEnabled = led;
            log.info('LED 狀態更新: $_ledEnabled');
          }
          // GPS 數據處理（如果需要的話）
          if (gpsData != null) {
            log.info('GPS 數據接收: $gpsData');
          }
        });
      },
    );
    _controller.connect();
    _connectToStream();

    _anglePollTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (isWebSocketConnected) {
        _controller.requestServoAngle();
      }
    });
    _getCurrentLocation();
  }

  void _connectToStream() async {
    if (_socket != null) return;
    setState(() {
      isStreamLoaded = true;
      isCameraConnected = false;
    });
    try {
      _socket = await Socket.connect(
        AppConfig.droneIP,
        AppConfig.videoPort,
        timeout: const Duration(seconds: 10), // 增加超時時間
      );
      log.info('成功連接到視訊串流：${AppConfig.droneIP}:${AppConfig.videoPort}');
      _socketSubscription = _socket!.listen(
            (data) {
          try {
            _buffer.addAll(data);
            int start, end;
            while ((start = _findJpegStart(_buffer)) != -1 &&
                (end = _findJpegEnd(_buffer, start)) != -1) {
              final frame = _buffer.sublist(start, end + 2);
              _buffer = _buffer.sublist(end + 2);
              setState(() {
                _currentFrame = Uint8List.fromList(frame);
                isCameraConnected = true;
              });
            }
            if (_buffer.length > 500000) {
              _buffer = _buffer.sublist(_buffer.length - 250000);
              log.warning('緩衝區過大，已裁剪至 ${_buffer.length} 位元組');
            }
          } catch (e) {
            log.severe('處理串流數據時出錯：$e');
          }
        },
        onError: (error) {
          log.severe('串流錯誤：$error');
          setState(() {
            isCameraConnected = false;
            isStreamLoaded = false;
          });
          _disconnectFromStream();
          _scheduleStreamReconnect();
        },
        onDone: () {
          log.warning('串流已關閉');
          setState(() {
            isCameraConnected = false;
            isStreamLoaded = false;
          });
          _disconnectFromStream();
          _scheduleStreamReconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      setState(() {
        isStreamLoaded = false;
        isCameraConnected = false;
      });
      log.severe('連線失敗：$e');
      _scheduleStreamReconnect();
    }
  }

  void _scheduleStreamReconnect() {
    Timer(const Duration(seconds: 10), () {
      if (!isStreamLoaded) {
        log.info('嘗試重新連線到視訊串流...');
        _connectToStream();
      }
    });
  }

  void _disconnectFromStream() {
    _socketSubscription?.cancel();
    _socket?.close();
    _socket = null;
    _socketSubscription = null;
    _buffer.clear();
    setState(() {
      isStreamLoaded = false;
      isCameraConnected = false;
      _currentFrame = null;
    });
  }

  int _findJpegStart(List<int> data) {
    for (int i = 0; i < data.length - 1; i++) {
      if (data[i] == 0xFF && data[i + 1] == 0xD8) return i;
    }
    return -1;
  }

  int _findJpegEnd(List<int> data, int start) {
    for (int i = start; i < data.length - 1; i++) {
      if (data[i] == 0xFF && data[i + 1] == 0xD9) return i;
    }
    return -1;
  }

  void startRecording() async {
    try {
      final uri = Uri.parse('http://$droneIP:8770/video/start');
      final res = await http.post(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        setState(() {
          isRecording = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('開始錄影')),
        );
      } else {
        log.severe('開始錄影失敗: ${res.body}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('開始錄影失敗: ${res.statusCode}')),
        );
      }
    } catch (e) {
      log.severe('無法開始錄影: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('錄影失敗: $e')),
      );
    }
  }

  void stopRecording() async {
    try {
      final uri = Uri.parse('http://$droneIP:8770/video/stop');
      final res = await http.post(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        setState(() {
          isRecording = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('停止錄影')),
        );
      } else {
        log.severe('停止錄影失敗: ${res.body}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('停止錄影失敗: ${res.statusCode}')),
        );
      }
    } catch (e) {
      log.severe('無法停止錄影: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('停止錄影失敗: $e')),
      );
    }
  }

  Future<void> takePhoto() async {
    try {
      final uri = Uri.parse('http://$droneIP:8770/photo');
      final res = await http.post(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已拍照')),
        );
      } else {
        log.severe('拍照失敗: ${res.body}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('拍照失敗: ${res.statusCode}')),
        );
      }
    } catch (e) {
      log.severe('拍照錯誤: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('拍照錯誤: $e')),
      );
    }
  }

  double _applyDeadzone(double v, {double dz = 0.06}) {
    if (v.abs() < dz) return 0.0;
    final sign = v.isNegative ? -1.0 : 1.0;
    final mag = ((v.abs() - dz) / (1 - dz)).clamp(0.0, 1.0);
    return sign * mag;
  }

  double _applyExpo(double v, {double expo = 0.3}) {
    return v * (1 - expo) + v * v * v * expo;
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  void _updateControlValues(JoystickMode mode, double x, double y) {
    _controlDebounceTimer?.cancel();
    _controlDebounceTimer = Timer(const Duration(milliseconds: 25), () {
      setState(() {
        double inX = x;
        double inY = -y;
        inX = _applyDeadzone(inX);
        inY = _applyDeadzone(inY);
        inX = _applyExpo(inX, expo: 0.35);
        inY = _applyExpo(inY, expo: 0.35);
        if (mode == JoystickMode.all) {
          throttle = inY;
          yaw = inX;
        } else {
          forward = inY;
          lateral = inX;
        }
        const smoothing = 0.25;
        _smoothedThrottle = _lerp(_smoothedThrottle, throttle, smoothing);
        _smoothedYaw = _lerp(_smoothedYaw, yaw, smoothing);
        _smoothedForward = _lerp(_smoothedForward, forward, smoothing);
        _smoothedLateral = _lerp(_smoothedLateral, lateral, smoothing);
        if (isWebSocketConnected) {
          _controller.startSendingControl(
            _smoothedThrottle,
            _smoothedYaw,
            _smoothedForward,
            _smoothedLateral,
          );
        } else {
          _controller.stopSendingControl();
        }
      });
    });
  }

  void _updateServoAngle(double newAngle) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 60), () {
      setState(() {
        final clampedAngle = newAngle.clamp(-45.0, 90.0);
        if ((clampedAngle - (_servoAngle ?? 0.0)).abs() > 0.5) {
          log.info('【伺服指令】即將送出角度: $clampedAngle');
          _servoAngle = clampedAngle;
          if (isWebSocketConnected) {
            _controller.sendServoAngle(_servoAngle!);
            log.info('【伺服指令】已送出角度: ${_servoAngle!.toStringAsFixed(1)}°');
          } else {
            log.warning('【伺服指令】WebSocket未連線，指令未送出');
          }
        }
      });
    });
  }

  void _toggleLed() {
    if (isWebSocketConnected) {
      _controller.sendLedCommand('LED_TOGGLE');
      log.info('發送 LED 切換指令');
    } else {
      log.warning('WebSocket未連線，LED指令未發送');
    }
  }

  void _showMenuDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext dialogContext) {
        String selectedMenu = '設定';
        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 400,
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(dialogContext).size.height * 0.95,
              ),
              margin: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.5),
                borderRadius: const BorderRadius.all(Radius.circular(20)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: 10,
                    offset: const Offset(-5, 0),
                  ),
                ],
              ),
              child: StatefulBuilder(
                builder: (BuildContext innerContext, StateSetter innerSetState) {
                  return Stack(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height: 75,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16.0,
                                vertical: 8.0,
                              ),
                              children: [
                                _MenuItem(
                                  icon: Icons.settings,
                                  title: '設定',
                                  isSelected: selectedMenu == '設定',
                                  onTap: () {
                                    innerSetState(() {
                                      selectedMenu = '設定';
                                    });
                                  },
                                ),
                                _MenuItem(
                                  icon: Icons.info,
                                  title: '資訊',
                                  isSelected: selectedMenu == '資訊',
                                  onTap: () {
                                    innerSetState(() {
                                      selectedMenu = '資訊';
                                    });
                                  },
                                ),
                                _MenuItem(
                                  icon: Icons.help,
                                  title: '幫助',
                                  isSelected: selectedMenu == '幫助',
                                  onTap: () {
                                    innerSetState(() {
                                      selectedMenu = '幫助';
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 16.0),
                            height: 1.0,
                            color: Colors.white.withOpacity(0.3),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(12.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (selectedMenu == '設定')
                                    ..._buildSettingsUI(
                                      innerContext,
                                      selectedMode,
                                          (mode) {
                                        innerSetState(() {
                                          selectedMode = mode;
                                        });
                                        setState(() {
                                          selectedMode = mode;
                                        });
                                        if (mode == '僅顯示') {
                                          Navigator.pushReplacement(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) =>
                                              const DroneDisplayOnlyPage(),
                                            ),
                                          );
                                        }
                                      },
                                      innerSetState,
                                    ),
                                  if (selectedMenu == '資訊')
                                    ..._buildInfoUI(innerContext),
                                  if (selectedMenu == '幫助')
                                    ..._buildHelpUI(innerContext),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: IconButton(
                          icon: const Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 20,
                          ),
                          onPressed: () {
                            Navigator.of(innerContext).pop();
                          },
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black.withOpacity(0.3),
                            shape: const CircleBorder(),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _MenuItem({
    required IconData icon,
    required String title,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashColor: Colors.white.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: isSelected ? Colors.white : Colors.white70,
                size: 28,
              ),
              const SizedBox(height: 4),
              Text(
                title,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white70,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                ),
              ),
              if (isSelected)
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  height: 2,
                  width: 20,
                  color: Colors.white,
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSettingsUI(
      BuildContext context,
      String selectedMode,
      Function(String) onModeChanged,
      StateSetter innerSetState,
      ) {
    return [
      const Text(
        '設定',
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 8),
      ListTile(
        leading: const Icon(Icons.adjust, color: Colors.white),
        title: const Text('手電筒', style: TextStyle(color: Colors.white)),
        trailing: _buildLedButton(),
      ),
      ListTile(
        leading: const Icon(Icons.add, color: Colors.white),
        title: const Text('手勢拍照', style: TextStyle(color: Colors.white)),
      ),
      ListTile(
        leading: const Icon(Icons.photo_camera, color: Colors.white),
        title: const Text('AI 辨識', style: TextStyle(color: Colors.white)),
        trailing: Switch(
          value: _aiRecognitionEnabled,
          onChanged: (bool value) {
            innerSetState(() {
              _aiRecognitionEnabled = value;
            });
            setState(() {
              _aiRecognitionEnabled = value;
            });
          },
        ),
      ),
      ListTile(
        leading: const Icon(Icons.data_saver_on, color: Colors.white),
        title: const Text('AI 搜救', style: TextStyle(color: Colors.white)),
        trailing: Switch(
          value: _aiRescueEnabled,
          onChanged: (bool value) {
            innerSetState(() {
              _aiRescueEnabled = value;
            });
            setState(() {
              _aiRescueEnabled = value;
            });
          },
        ),
      ),
      ListTile(
        leading: const Icon(Icons.settings_input_antenna, color: Colors.white),
        title: const Text('伺服控制方式', style: TextStyle(color: Colors.white)),
        trailing: Switch(
          value: _useSliderControl,
          onChanged: (bool value) {
            innerSetState(() {
              _useSliderControl = value;
            });
            setState(() {
              _useSliderControl = value;
            });
            log.info('伺服控制方式切換為: ${_useSliderControl ? "滑桿" : "螢幕滑動"}');
          },
        ),
      ),
      const Text(
        '模式選擇',
        style: TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8.0,
        children: [
          _ModeOption(
            label: '顯示加控制',
            isSelected: selectedMode == '顯示加控制',
            onTap: () => onModeChanged('顯示加控制'),
          ),
          _ModeOption(
            label: '僅顯示',
            isSelected: selectedMode == '僅顯示',
            onTap: () => onModeChanged('僅顯示'),
          ),
          _ModeOption(
            label: '協同作業',
            isSelected: selectedMode == '協同作業',
            onTap: () => onModeChanged('協同作業'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      TextField(
        decoration: const InputDecoration(
          labelText: 'Drone IP',
          labelStyle: TextStyle(color: Colors.white),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.white),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.blue),
          ),
        ),
        style: const TextStyle(color: Colors.white),
        controller: TextEditingController(text: droneIP),
        onChanged: (value) {
          innerSetState(() {
            droneIP = value;
          });
          setState(() {
            droneIP = value;
            AppConfig.droneIP = value;
          });
          _controller.disconnect();
          _controller.connect();
          _disconnectFromStream();
          _connectToStream();
        },
      ),
    ];
  }

  List<Widget> _buildInfoUI(BuildContext dialogContext) {
    return [
      const Text(
        '應用資訊',
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 8),
      const ListTile(
        leading: Icon(Icons.info_outline, color: Colors.white),
        title: Text('版本號: 2.4.6.8', style: TextStyle(color: Colors.white)),
      ),
      const ListTile(
        leading: Icon(Icons.person, color: Colors.white),
        title: Text('開發者: drone Team', style: TextStyle(color: Colors.white)),
      ),
      ListTile(
        leading: const Icon(Icons.email, color: Colors.white),
        title: const Text('聯繫我們', style: TextStyle(color: Colors.white)),
        onTap: () {
          showDialog(
            context: dialogContext,
            builder: (context) => AlertDialog(
              title: const Text('聯繫我們'),
              content: const Text('請發送郵件至: jerrysh0227@gmail.com'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('關閉'),
                ),
              ],
            ),
          );
        },
      ),
    ];
  }

  List<Widget> _buildHelpUI(BuildContext dialogContext) {
    return [
      const Text(
        '幫助與支援',
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 8),
      const ListTile(
        leading: Icon(Icons.book, color: Colors.white),
        title: Text('使用手冊', style: TextStyle(color: Colors.white)),
      ),
      ListTile(
        leading: const Icon(Icons.question_answer, color: Colors.white),
        title: const Text('常見問題', style: TextStyle(color: Colors.white)),
        onTap: () {
          showDialog(
            context: dialogContext,
            builder: (context) => AlertDialog(
              title: const Text('常見問題'),
              content: const Text('Q: 如何連線無人機?\nA: 請確保分享開啟且IP位址正確。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('關閉'),
                ),
              ],
            ),
          );
        },
      ),
      const ListTile(
        leading: Icon(Icons.support, color: Colors.white),
        title: Text('技術支援', style: TextStyle(color: Colors.white)),
      ),
    ];
  }

  Widget _buildTopStatusBar() {
    return Positioned(
      top: 0,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.6),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: () async {
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
              },
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withOpacity(0.15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.all(10),
              ),
              icon: const Icon(
                Icons.arrow_back_ios_new,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            _buildConnectionButton(
              icon: isWebSocketConnected
                  ? Icons.wifi_rounded
                  : Icons.wifi_off_rounded,
              isConnected: isWebSocketConnected,
              onPressed: () {
                if (!isWebSocketConnected) _controller.connect();
              },
              tooltip: 'WebSocket連線',
            ),
            const SizedBox(width: 8),
            _buildConnectionButton(
              icon: isCameraConnected
                  ? Icons.videocam_rounded
                  : Icons.videocam_off_rounded,
              isConnected: isCameraConnected,
              onPressed: () {
                if (isStreamLoaded)
                  _disconnectFromStream();
                else
                  _connectToStream();
              },
              tooltip: '視訊串流',
            ),
            const SizedBox(width: 8),
            _buildLedButton(),
            const SizedBox(width: 8),
            IconButton(
              onPressed: () {
                setState(() {
                  isFullScreen = !isFullScreen;
                });
                if (isFullScreen) {
                  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
                  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
                    statusBarColor: Colors.transparent,
                    systemNavigationBarColor: Colors.transparent,
                    systemNavigationBarDividerColor: Colors.transparent,
                  ));
                  _fullScreenController.forward();
                } else {
                  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
                  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
                    statusBarColor: Colors.transparent,
                    systemNavigationBarColor: Colors.transparent,
                    systemNavigationBarDividerColor: Colors.transparent,
                  ));
                  _fullScreenController.reverse();
                }
              },
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withOpacity(0.15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.all(10),
              ),
              icon: Icon(
                isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                color: Colors.white,
                size: 20,
              ),
            ),
            const Spacer(),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _showMenuDialog,
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withOpacity(0.15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.all(10),
              ),
              icon: const Icon(Icons.menu, color: Colors.white, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionButton({
    required IconData icon,
    required bool isConnected,
    required VoidCallback onPressed,
    required String tooltip,
  }) {
    Color activeColor = Colors.greenAccent.shade700;
    Color inactiveColor = Colors.redAccent.shade400;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isConnected
                  ? activeColor.withOpacity(0.25)
                  : inactiveColor.withOpacity(0.25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isConnected
                    ? activeColor.withOpacity(0.5)
                    : inactiveColor.withOpacity(0.5),
                width: 1.5,
              ),
            ),
            child: AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) => Transform.scale(
                scale: isConnected ? _pulseAnimation.value : 1.0,
                child: Icon(
                  icon,
                  color: isConnected ? activeColor : inactiveColor,
                  size: 22,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLedButton() {
    Color activeColor = Colors.yellow.shade600;
    Color inactiveColor = Colors.grey.shade600;
    return Tooltip(
      message: 'LED 控制',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _toggleLed,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _ledEnabled
                  ? activeColor.withOpacity(0.25)
                  : inactiveColor.withOpacity(0.25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _ledEnabled
                    ? activeColor.withOpacity(0.5)
                    : inactiveColor.withOpacity(0.5),
                width: 1.5,
              ),
            ),
            child: AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) => Transform.scale(
                scale: _ledEnabled ? _pulseAnimation.value : 1.0,
                child: Icon(
                  Icons.lightbulb,
                  color: _ledEnabled ? activeColor : inactiveColor,
                  size: 22,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildServoSlider() {
    if (_useSliderControl) {
      return Positioned(
        right: 80,
        top: 10,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.6),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isWebSocketConnected
                  ? Colors.blue.withOpacity(0.5)
                  : Colors.grey.withOpacity(0.5),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.camera_alt,
                    color: isWebSocketConnected ? Colors.white : Colors.grey,
                    size: 16,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    '雲台角度',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_servoAngle?.toStringAsFixed(1) ?? "0.0"}°',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Slider(
                value: _servoAngle ?? 0.0,
                min: -45.0,
                max: 90.0,
                divisions: 135,
                onChanged: isWebSocketConnected
                    ? (value) {
                  setState(() {
                    _servoAngle = value;
                  });
                  _updateServoAngle(value);
                }
                    : null,
                activeColor: Colors.blue,
                inactiveColor: Colors.grey,
              ),
            ],
          ),
        ),
      );
    } else {
      return Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () {
            if (!isWebSocketConnected) return;
            setState(() {
              _servoAngle = 0.0;
            });
            _controller.sendServoAngle(0.0);
            log.info('伺服角度歸零');
          },
          onPanStart: (details) {
            if (!isWebSocketConnected) return;
            setState(() {
              _isDraggingServo = true;
            });
            log.info('開始拖拽伺服控制');
          },
          onPanUpdate: (details) {
            if (!isWebSocketConnected || !_isDraggingServo) return;
            setState(() {
              double sensitivity = 0.5;
              _servoAngle = (_servoAngle ?? 0.0) - details.delta.dy * sensitivity;
              _servoAngle = _servoAngle!.clamp(-45.0, 90.0);
            });
            _updateServoAngle(_servoAngle!);
          },
          onPanEnd: (details) {
            setState(() {
              _isDraggingServo = false;
            });
            log.info('結束拖拽伺服控制');
          },
          child: Container(
            color: Colors.transparent,
            child: Stack(
              children: [
                Positioned(
                  right: 80,
                  top: 10,
                  child: AnimatedContainer(
                    duration: Duration(milliseconds: _isDraggingServo ? 150 : 300),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(_isDraggingServo ? 0.8 : 0.6),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isWebSocketConnected
                            ? (_isDraggingServo ? Colors.blue : Colors.blue.withOpacity(0.5))
                            : Colors.grey.withOpacity(0.5),
                        width: _isDraggingServo ? 2 : 1,
                      ),
                      boxShadow: _isDraggingServo
                          ? [
                        BoxShadow(
                          color: Colors.blue.withOpacity(0.3),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ]
                          : [],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.camera_alt,
                          color: isWebSocketConnected ? Colors.white : Colors.grey,
                          size: 16,
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          '雲台角度',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${_servoAngle?.toStringAsFixed(1) ?? "0.0"}°',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: _isDraggingServo ? 18 : 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_isDraggingServo)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black.withOpacity(0.1),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.7),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.blue.withOpacity(0.5),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.keyboard_arrow_up,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                  Text(
                                    '向上',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(width: 20),
                              Text(
                                '${_servoAngle?.toStringAsFixed(1)}°',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 20),
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.keyboard_arrow_down,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                  Text(
                                    '向下',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!isWebSocketConnected)
                  Positioned(
                    bottom: 50,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.8),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          '未連線 - 無法控制雲台',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
  }

  Widget _buildBottomControlArea() {
    return Positioned(
      bottom: 16,
      left: 110,
      right: 100,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildJoystickWithLabel(
            label: '油門/偏航',
            mode: JoystickMode.all,
            onUpdate: (x, y) => _updateControlValues(JoystickMode.all, x, y),
            onEnd: () {
              setState(() {
                throttle = yaw = 0;
                if (isWebSocketConnected) {
                  _smoothedThrottle = _lerp(_smoothedThrottle, 0, 0.6);
                  _smoothedYaw = _lerp(_smoothedYaw, 0, 0.6);
                  _controller.startSendingControl(
                    _smoothedThrottle,
                    _smoothedYaw,
                    _smoothedForward,
                    _smoothedLateral,
                  );
                }
              });
            },
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildActionButton(
                    Icons.flight_takeoff_rounded,
                    '啟動',
                    isWebSocketConnected
                        ? Colors.greenAccent.shade700
                        : Colors.grey.shade700,
                    isWebSocketConnected
                        ? () => _controller.sendCommand('ARM')
                        : null,
                  ),
                  const SizedBox(width: 10),
                  _buildActionButton(
                    Icons.flight_land_rounded,
                    '解除',
                    isWebSocketConnected
                        ? Colors.redAccent.shade400
                        : Colors.grey.shade700,
                    isWebSocketConnected
                        ? () => _controller.sendCommand('DISARM')
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 80),
            ],
          ),
          _buildJoystickWithLabel(
            label: '前進/橫移',
            mode: JoystickMode.all,
            onUpdate: (x, y) => _updateControlValues(JoystickMode.all, x, y),
            onEnd: () {
              setState(() {
                forward = lateral = 0;
                if (isWebSocketConnected) {
                  _smoothedForward = _lerp(_smoothedForward, 0, 0.6);
                  _smoothedLateral = _lerp(_smoothedLateral, 0, 0.6);
                  _controller.startSendingControl(
                    _smoothedThrottle,
                    _smoothedYaw,
                    _smoothedForward,
                    _smoothedLateral,
                  );
                }
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildJoystickWithLabel({
    required String label,
    required JoystickMode mode,
    required void Function(double, double) onUpdate,
    required VoidCallback onEnd,
  }) {
    double xValue = (label == '油門/偏航') ? yaw : lateral;
    double yValue = (label == '油門/偏航') ? throttle : forward;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            shadows: [
              Shadow(
                color: Colors.black87,
                blurRadius: 2,
                offset: Offset(1, 1),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          width: 160,
          height: 160,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5),
            borderRadius: BorderRadius.circular(80),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Joystick(
            stick: AnimatedJoystickStick(x: xValue, y: yValue),
            base: JoystickBase(mode: mode),
            listener: (details) => onUpdate(details.x, details.y),
            onStickDragEnd: onEnd,
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton(
      IconData icon,
      String label,
      Color color,
      VoidCallback? onTap,
      ) {
    bool isDisabled = onTap == null;
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: isDisabled ? Colors.grey.shade800 : color,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        elevation: 4,
        shadowColor: Colors.black.withOpacity(0.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22),
          const SizedBox(height: 5),
          Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  void _showRecordingOptionsDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.3),
      builder: (BuildContext dialogContext) {
        return const RecordingOptionsDialog();
      },
    );
  }

  Future<void> _getCurrentLocation() async {
    bool locationEnable;
    LocationPermission permission;

    locationEnable = await Geolocator.isLocationServiceEnabled();
    if (!locationEnable) {
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return;
    }

    Position position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    setState(() {
      dronePosition = latLng.LatLng(position.latitude, position.longitude);
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controlDebounceTimer?.cancel();
    _anglePollTimer?.cancel();
    _pulseController.dispose();
    _fullScreenController.dispose();
    _controller.dispose();
    _disconnectFromStream();
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
      body: GestureDetector(
        onDoubleTap: () {
          setState(() {
            isFullScreen = !isFullScreen;
          });
          if (isFullScreen) {
            SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
            SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
              systemNavigationBarDividerColor: Colors.transparent,
            ));
            _fullScreenController.forward();
          } else {
            SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
            SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
              systemNavigationBarDividerColor: Colors.transparent,
            ));
            _fullScreenController.reverse();
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _currentFrame != null
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
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                      ),
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
                            valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.white),
                            strokeWidth: 3,
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
            Container(color: Colors.black.withOpacity(0.1)),
            _buildServoSlider(),
            _buildTopStatusBar(),
            _buildBottomControlArea(),
            Positioned(
              left: 20,
              bottom: MediaQuery.of(context).size.height * 0.55,
              child: GestureDetector(
                onTap: () {
                  // TODO: 點擊後可以切換成全螢幕地圖
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: SizedBox(
                    width: 150,
                    height: 100,
                    child: FlutterMap(
                      options: MapOptions(
                        initialCenter:
                        dronePosition ?? const LatLng(23.016725, 120.232065),
                        initialZoom: 18,
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.all,
                        ),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.example.app',
                        ),
                        if (dronePosition != null)
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: dronePosition!,
                                width: 40,
                                height: 40,
                                child: const Icon(
                                  Icons.airplanemode_active,
                                  color: Colors.black,
                                  size: 30,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 20,
              top: (MediaQuery.of(context).size.height - 60) / 2 - 50,
              child: IconButton(
                onPressed: () {
                  _showRecordingOptionsDialog(context);
                },
                icon: const Icon(Icons.movie, color: Colors.white, size: 30),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withOpacity(0.3),
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(10),
                ),
                tooltip: '錄影選項',
              ),
            ),
            if (isFullScreen)
              Positioned(
                top: 100,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.fullscreen,
                        color: Colors.white,
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        '全螢幕模式',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Positioned(
              right: 20,
              top: (MediaQuery.of(context).size.height - 60) / 2 + 80,
              child: IconButton(
                onPressed: takePhoto,
                icon: const Icon(Icons.camera_alt, color: Colors.white, size: 28),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withOpacity(0.3),
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(12),
                ),
                tooltip: '拍照',
              ),
            ),
            Positioned(
              right: 20,
              top: (MediaQuery.of(context).size.height - 60) / 2,
              child: RecordButton(
                isRecording: isRecording,
                onTap: () {
                  if (!isRecording) {
                    startRecording();
                  } else {
                    stopRecording();
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AnimatedJoystickStick extends StatefulWidget {
  final double x;
  final double y;

  const AnimatedJoystickStick({super.key, required this.x, required this.y});

  @override
  _AnimatedJoystickStickState createState() => _AnimatedJoystickStickState();
}

class _AnimatedJoystickStickState extends State<AnimatedJoystickStick>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(AnimatedJoystickStick oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.x != 0 || widget.y != 0) &&
        (_scaleController.status == AnimationStatus.dismissed ||
            _scaleController.status == AnimationStatus.reverse)) {
      _scaleController.forward();
    } else if (widget.x == 0 &&
        widget.y == 0 &&
        (_scaleController.status == AnimationStatus.completed ||
            _scaleController.status == AnimationStatus.forward)) {
      _scaleController.reverse();
    }
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _scaleAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Container(
            width: 55,
            height: 55,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Colors.blueGrey.shade600, Colors.blueGrey.shade400],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 6,
                  offset: const Offset(2, 2),
                ),
              ],
            ),
            child: Center(
              child: Icon(
                Icons.control_camera_rounded,
                color: Colors.white.withOpacity(0.8),
                size: 24,
              ),
            ),
          ),
        );
      },
    );
  }
}

class JoystickCrosshairPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.2)
      ..strokeWidth = 1.0;

    double lineLength = size.width * 0.35;
    canvas.drawLine(
      Offset(center.dx - lineLength / 2, center.dy),
      Offset(center.dx + lineLength / 2, center.dy),
      paint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - lineLength / 2),
      Offset(center.dx, center.dy + lineLength / 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class JoystickBase extends StatelessWidget {
  final JoystickMode mode;

  const JoystickBase({super.key, this.mode = JoystickMode.all});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      height: 150,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            Colors.blueGrey.shade800.withOpacity(0.5),
            Colors.black.withOpacity(0.6),
          ],
          stops: const [0.7, 1.0],
          center: Alignment.center,
          radius: 0.9,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: Colors.blueGrey.shade900.withOpacity(0.9),
            spreadRadius: -5.0,
            blurRadius: 10.0,
          ),
        ],
      ),
      child: CustomPaint(
        painter: JoystickCrosshairPainter(),
        size: const Size(150, 150),
      ),
    );
  }
}

class RecordButton extends StatefulWidget {
  final bool isRecording;
  final VoidCallback onTap;

  const RecordButton({
    super.key,
    required this.isRecording,
    required this.onTap,
  });

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _sizeAnim;
  late Animation<BorderRadius?> _borderAnim;
  late Animation<double> _pulseAnimIcon;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _sizeAnim = Tween<double>(begin: 30, end: 20).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
    _borderAnim = BorderRadiusTween(
      begin: BorderRadius.circular(30),
      end: BorderRadius.circular(8),
    ).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
    _pulseAnimIcon = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    if (widget.isRecording) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant RecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording != oldWidget.isRecording) {
      if (widget.isRecording) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color: widget.isRecording
              ? Colors.red.withOpacity(0.7)
              : Colors.black.withOpacity(0.3),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: widget.isRecording ? Colors.red.shade900 : Colors.grey.shade700,
            width: 3,
          ),
          boxShadow: widget.isRecording
              ? [
            BoxShadow(
              color: Colors.red.withOpacity(0.5),
              blurRadius: 10,
            ),
          ]
              : [],
        ),
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Container(
                width: _sizeAnim.value,
                height: _sizeAnim.value,
                decoration: BoxDecoration(
                  color: Colors.red.shade900,
                  borderRadius: _borderAnim.value,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.shade900.withOpacity(
                        widget.isRecording ? 0.7 : 0.3,
                      ),
                      blurRadius: widget.isRecording ? 8 : 3,
                      spreadRadius: widget.isRecording ? 2 : 0,
                    ),
                  ],
                ),
                child: widget.isRecording
                    ? null
                    : FadeTransition(
                  opacity: ReverseAnimation(_pulseAnimIcon),
                  child: Icon(
                    Icons.videocam,
                    color: Colors.white,
                    size: _sizeAnim.value * 0.9,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeOption({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label, style: const TextStyle(color: Colors.black87)),
      selected: isSelected,
      selectedColor: Colors.blueAccent.withOpacity(0.6),
      backgroundColor: Colors.white24,
      onSelected: (_) => onTap(),
    );
  }
}