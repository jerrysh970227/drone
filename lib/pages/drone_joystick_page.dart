import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:drone/model/RecordService.dart';
import 'package:drone/ui/RecordButton.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:latlong2/latlong.dart' as latLng;
import 'package:logging/logging.dart';

import '../map/mapInfo.dart';
import '../constants.dart';
import '../controller/drone_controller.dart';
import '../model/Joystick.dart';
import '../model/SteamService.dart';
import '../ui/GridLine.dart';
import '../ui/JoystickBase.dart';
import '../ui/claudSlider.dart';
import 'main.dart';

class DroneJoystickPage extends StatefulWidget {
  const DroneJoystickPage({super.key});

  @override
  State<DroneJoystickPage> createState() => _DroneJoystickPageState();
}

class _DroneJoystickPageState extends State<DroneJoystickPage>
    with TickerProviderStateMixin {
  bool _gestureRecognitionEnabled = false;
  bool _aiRecognitionEnabled = false;
  bool _aiRescueEnabled = false;
  bool _ledEnabled = false;
  bool _auxiliaryLine = false;
  bool _useSliderControl = false; // 控制伺服馬達方式（false: 按鈕控制, true: 滑桿）
  bool _usePhoneAsMapCenter = false; // 控制地圖中心顯示（false: 無人機位置, true: 手機位置）
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
  double? _servoAngle = 0.0;
  bool _isDraggingServo = false;
  bool isCameraConnected = false;
  bool isStreamLoaded = false;
  bool isWebSocketConnected = false;
  Uint8List? _currentFrame;
  Timer? _snackBarDebounceTimer;

  Timer? _debounceTimer; // 伺服用
  Timer? _controlDebounceTimer; // 控制用
  Timer? _anglePollTimer;
  latLng.LatLng? dronePosition;
  latLng.LatLng? _phonePosition; // 手機位置
  bool isFullScreen = false;
  bool _isSatelliteView = false; // 衛星視圖切換
  late AnimationController _fullScreenController;
  late Animation<double> _fullScreenAnimation;
  Timer? _locationUpdateTimer; // 定期更新位置
  // 小地圖控制器，用於回到目前模式中心
  late final MapService _mapService;
  late final VideoStreamService  _stream;
  late final VideoRecordingService _record;


  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );

    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat(reverse: true);

    _mapService = MapService();
    _mapService.usePhoneAsMapCenter = _usePhoneAsMapCenter;

    _stream = VideoStreamService();
    _setupVideoStreamCallback();
    _stream.connect(AppConfig.droneIP, AppConfig.videoPort);

    _record = VideoRecordingService(AppConfig.droneIP);
    _record.addListener(_onRecordingStateChanged);


    _fullScreenController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fullScreenAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fullScreenController, curve: Curves.easeInOut),
    );

    _controller = DroneController(
      onStatusChanged: (DroneStatus status) {
        setState(() {
          isWebSocketConnected = status.isConnected;
          log.info(
            'WebSocket 狀態: ${status.connectionState}, 連線: ${status.isConnected}',
          );
          if (status.servoAngle != null &&
              status.servoAngle! >= -45.0 &&
              status.servoAngle! <= 90.0) {
            if (!_isDraggingServo) {
              _servoAngle = double.parse(status.servoAngle!.toStringAsFixed(2));
              // _lastServoUiUpdate = DateTime.now();
              log.info('伺服角度更新: ${_servoAngle!.toStringAsFixed(2)}°');
            }
          }
          if (status.ledState != null) {
            _ledEnabled = status.ledState!;
            log.info('LED 狀態更新: $_ledEnabled');
          }
          // 處理 GPS 數據
          // Note: GPS data is not part of DroneStatus in the current implementation
        });
      },
      onLogMessage: (String message, {bool isError = false}) {
        log.info('控制器訊息: $message');
        if (isError) {
          log.severe('控制器錯誤: $message');
        }
      },
    );
    _controller.connect();

    _anglePollTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (isWebSocketConnected) {
        // Use sendCommand to request servo angle instead
        _controller.sendCommand('REQUEST_SERVO_ANGLE');
      }
    });

    // 定期更新手機位置
    _startLocationSetting();
  }

  void _startLocationSetting(){
    _mapService.getCurrentLocation(context);
    _locationUpdateTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      _mapService.getCurrentLocation(context);
    });
  }

  void _onMapStateChanged(){
    setState(() {
      _usePhoneAsMapCenter = _mapService.usePhoneAsMapCenter;
    });
  }

  void _toggleFullScreen() {
    setState(() {
      isFullScreen = !isFullScreen;
    });
    if (isFullScreen) {
      _fullScreenController.forward();
    } else {
      _fullScreenController.reverse();
    }
    log.info('全螢幕模式已切換為: $isFullScreen');
  }

  void _updateServoAngle(double newAngle) {
    _debounceTimer?.cancel();
    // Increase debounce time to reduce jitter
    _debounceTimer = Timer(const Duration(milliseconds: 50), () {
      final clampedAngle = newAngle.clamp(-45.0, 90.0);
      setState(() {
        _servoAngle = double.parse(
          clampedAngle.toStringAsFixed(1),
        ); // Reduce precision to avoid jitter
      });
      if (isWebSocketConnected) {
        log.info('【伺服指令】即將送出角度: ${_servoAngle!.toStringAsFixed(1)}°');
        _controller.sendServoAngle(_servoAngle!);
        log.info('【伺服指令】已送出角度: ${_servoAngle!.toStringAsFixed(1)}°');
      } else {
        log.warning('WebSocket未連線，伺服指令未發送');
      }
    });
  }

  void _toggleLed() {
    if (isWebSocketConnected) {
      _controller.sendLedCommand(
        jsonEncode({
          'type': 'led_control',
          'action': _ledEnabled ? 'LED_OFF' : 'LED_ON',
        }),
      );
      log.info('發送 LED 切換指令');
    } else {
      log.warning('WebSocket未連線，LED指令未發送');
    }
  }

  void _changeUIMode(String newMode, StateSetter innerState) {
    innerState((){
      selectedMode = newMode;
    });
    setState(() {
      selectedMode = newMode;
    });
    log.info('UI模式已切換至：$newMode');
  }

  bool _shouldShowControls() {
    return selectedMode == '顯示加控制' || selectedMode == '協同作業';
  }

  bool _shouldShowServoControls() {
    return selectedMode == '顯示加控制' || selectedMode == '僅顯示';
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
                builder: (
                  BuildContext innerContext,
                  StateSetter innerSetState,
                ) {
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
                            margin: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                            ),
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

  void _setupVideoStreamCallback(){
    _stream.setStatusCallback(({required bool isConnected, required bool isLoading}) {
      if (mounted) {
        setState(() {
          isCameraConnected = isConnected;
          isStreamLoaded = isLoading;
        });
        log.info('串流狀態更新 - 連線: $isConnected, 載入中: $isLoading');
      }
    });

    // 設定幀數據回調
    _stream.setFrameCallback((Uint8List frameData) {
      if (mounted) {
        setState(() {
          _currentFrame = frameData;
        });
      }
    });
}

Future<void> reconnect() async{
    await _stream.connect(AppConfig.droneIP, AppConfig.videoPort);
}

Future<void> disconnect() async{
    await _stream.disconnect();
}

void _onRecordingStateChanged(){
    if(!mounted) return;

    if(_record.status == RecordingStatus.error){
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text("錄影發生錯誤"),
            duration: Duration(seconds: 2)
        )
      );
      _record.resetError();
    }
    setState(() {});
}


  Future<void> _toggleRecording() async {
    _snackBarDebounceTimer?.cancel();
    if (!_record.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('錄影服務未連線，請檢查伺服器')),
      );
      _record.reconnect();
      return;
    }
    _snackBarDebounceTimer = Timer(const Duration(milliseconds: 500), () async {
      try {
        if (_record.isRecording) {
          final success = await _record.stopRecording();
          if (success) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('錄影已停止 時長: ${_record.formattedTime}')),
            );
          } else {
            throw Exception('停止錄影失敗');
          }
        } else {
          final success = await _record.startRecording();
          if (success) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('錄影已開始')),
            );
          } else {
            throw Exception('開始錄影失敗');
          }
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('錄影錯誤: $e')),
        );
      }
    });
  }

  void startRecording() async {
    await _record.startRecording();
  }

  void stopRecording() async {
    await _record.stopRecording();
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
    final String selectedMode,
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
        leading: const Icon(Icons.waving_hand, color: Colors.white),
        title: const Text('手勢辨識', style: TextStyle(color: Colors.white)),
        trailing: Switch(
          value: _gestureRecognitionEnabled,
          activeColor: Colors.green,
          onChanged: (bool value) {
            innerSetState(() {
              _gestureRecognitionEnabled = value;
            });
            setState(() {
              _gestureRecognitionEnabled = value;
            });
          },
        ),
      ),
      ListTile(
        leading: const Icon(Icons.photo_camera, color: Colors.white),
        title: const Text('AI 辨識', style: TextStyle(color: Colors.white)),
        trailing: Switch(
          value: _aiRecognitionEnabled,
          activeColor: Colors.green,
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
        leading: const Icon(Icons.photo_camera, color: Colors.white),
        title: const Text('AI 搜救', style: TextStyle(color: Colors.white)),
        trailing: Switch(
          value: _aiRescueEnabled,
          activeColor: Colors.green,
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
        leading: const Icon(Icons.settings, color: Colors.white),
        title: Text(
          '伺服控制方式: ${_useSliderControl ? '滑桿' : '按鈕'}',
          style: const TextStyle(color: Colors.white),
        ),
        trailing: Switch(
          value: _useSliderControl,
          activeColor: Colors.green,
          onChanged: (bool value) {
            innerSetState(() {
              _useSliderControl = value;
            });
            setState(() {
              _useSliderControl = value;
              log.info('伺服控制方式切換為: ${_useSliderControl ? '滑桿' : '按鈕'}');
            });
          },
        ),
      ),
      ListTile(
        leading: const Icon(Icons.map, color: Colors.white),
        title: const Text('地圖中心顯示', style: TextStyle(color: Colors.white)),
        subtitle: Text(
          _usePhoneAsMapCenter ? '以手機位置為中心' : '以無人機位置為中心',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        trailing: Switch(
          value: _usePhoneAsMapCenter,
          activeColor: Colors.green,
          onChanged: (bool value) {
            innerSetState(() {
              _usePhoneAsMapCenter = value;
            });
            setState(() {
              _usePhoneAsMapCenter = value;
              log.info('地圖中心顯示切換為: ${_usePhoneAsMapCenter ? '手機位置' : '無人機位置'}');
            });
          },
        ),
      ),
      ListTile(
        leading: const Icon(Icons.photo_camera, color: Colors.white),
        title: const Text('拍照輔助線', style: TextStyle(color: Colors.white)),
        trailing: Switch(
          value: _auxiliaryLine,
          activeColor: Colors.green,
          onChanged: (bool value) {
            innerSetState(() {
              _auxiliaryLine = value;
            });
            setState(() {
              _auxiliaryLine = value;
            });
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
      Row(
        children: [
          Wrap(
            spacing: 8.0,
            children: [
              _ModeOption(
                label: '顯示加控制',
                isSelected: selectedMode == '顯示加控制',
                onTap: () => _changeUIMode('顯示加控制',innerSetState),
              ),
              _ModeOption(
                label: '僅顯示',
                isSelected: selectedMode == '僅顯示',
                onTap: () => _changeUIMode('僅顯示',innerSetState),
              ),
              _ModeOption(
                label: '協同作業',
                isSelected: selectedMode == '協同作業',
                onTap: () => _changeUIMode('協同作業',innerSetState),
              ),
            ],
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
          disconnect();
          reconnect();
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
            builder:
                (context) => AlertDialog(
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
            builder:
                (context) => AlertDialog(
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
              icon:
                  isWebSocketConnected
                      ? Icons.wifi_rounded
                      : Icons.wifi_off_rounded,
              isConnected: isWebSocketConnected,
              onPressed: () {
                if (!isWebSocketConnected) _controller.connect();
                setState(() {
                  isWebSocketConnected = isWebSocketConnected;
                });
              },
              tooltip: 'WebSocket連線',
            ),
            const SizedBox(width: 8),
            _buildConnectionButton(
              icon:
                  isCameraConnected
                      ? Icons.videocam_rounded
                      : Icons.videocam_off_rounded,
              isConnected: isCameraConnected,
              onPressed: () {
                if (isStreamLoaded)
                  disconnect();
                else
                  reconnect();
              },
              tooltip: '視訊串流',
            ),
            const SizedBox(width: 8),
            const Spacer(),
            Text(
              '伺服: ${_servoAngle?.toStringAsFixed(1) ?? 0.0}°',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
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
              color:
                  isConnected
                      ? activeColor.withOpacity(0.25)
                      : inactiveColor.withOpacity(0.25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color:
                    isConnected
                        ? activeColor.withOpacity(0.5)
                        : inactiveColor.withOpacity(0.5),
                width: 1.5,
              ),
            ),
            child: AnimatedBuilder(
              animation: _pulseController,
              builder:
                  (context, child) => Transform.scale(
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
    return _buildConnectionButton(
      icon: _ledEnabled ? Icons.lightbulb : Icons.lightbulb_outline,
      isConnected: _ledEnabled,
      onPressed: _toggleLed,
      tooltip: 'LED控制',
    );
  }

  Widget _buildServoSlider1() {
    if (_useSliderControl) {
      return Positioned(
        left: 20,
        top: 110,
        child: Container(
          height: 250,
          width: 80,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.6),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.4),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 16.0),
                child: Text(
                  '雲台\n角度',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    height: 1.2,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: GestureDetector(
                  onVerticalDragStart: (details) {
                    setState(() {
                      _isDraggingServo = true;
                      log.info('開始拖拽伺服控制（滑桿）');
                    });
                  },
                  onVerticalDragUpdate: (details) {
                    final double maxDragDistance = 150.0;
                    final double dragPosition = details.localPosition.dy;
                    final double normalizedPosition =
                        1 - (dragPosition / maxDragDistance);
                    final double newAngle = (normalizedPosition * 135 - 45)
                        .clamp(-45.0, 90.0);
                    _updateServoAngle(newAngle);
                  },
                  onVerticalDragEnd: (details) {
                    setState(() {
                      _isDraggingServo = false;
                      log.info('結束拖拽伺服控制（滑桿）');
                    });
                  },
                  child: Container(
                    alignment: Alignment.center,
                    child: CustomPaint(
                      size: const Size(80, 200),
                      painter: ServoTrackPainter(
                        servoAngle: _servoAngle ?? 0.0,
                        isDragging: _isDraggingServo,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '角度: ${_servoAngle?.toStringAsFixed(1) ?? 0.0}°',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      // Touch-to-appear servo control
      return Stack(
        children: [
          // Invisible gesture detector covering the entire screen
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
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
                  _servoAngle =
                      (_servoAngle ?? 0.0) - details.delta.dy * sensitivity;
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
              onTap: () {
                if (!isWebSocketConnected) return;
                setState(() {
                  _servoAngle = 0.0;
                });
                _updateServoAngle(0.0);
                log.info('伺服角度歸零');
              },
            ),
          ),
          // Servo control interface - only show when dragging
          if (_isDraggingServo)
            Center(
              child: AnimatedOpacity(
                opacity: _isDraggingServo ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.blue.withOpacity(0.7),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.5),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
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
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '雲台角度',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            '${_servoAngle?.toStringAsFixed(1)}°',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
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
        ],
      );
    }
  }

  // 應用死區處理（減少死區以提高靈敏度）
  double _applyDeadzone(double value, {double deadzone = 0.03}) {
    if (value.abs() < deadzone) return 0.0;
    final sign = value.isNegative ? -1.0 : 1.0;
    final magnitude = ((value.abs() - deadzone) / (1.0 - deadzone)).clamp(
      0.0,
      1.0,
    );
    return sign * magnitude;
  }

  // 特別的油門死區處理（減少死區以提高靈敏度）
  double _applyThrottleDeadzone(double value) {
    const throttleDeadzone = 0.04; // 減少油門死區以提高靈敏度
    if (value.abs() < throttleDeadzone) return 0.0;
    final sign = value.isNegative ? -1.0 : 1.0;
    final magnitude = ((value.abs() - throttleDeadzone) /
            (1.0 - throttleDeadzone))
        .clamp(0.0, 1.0);
    return sign * magnitude;
  }

  // 應用指數曲線增強精確控制（減少指數效應以提高靈敏度）
  double _applyExpo(double value, {double expo = 0.15}) {
    return value * (1.0 - expo) + (value * value * value) * expo;
  }

  // 線性插值平滑處理（減少平滑以降低延遲）
  double _lerp(double current, double target, double smoothing) {
    return current + (target - current) * smoothing;
  }

  void _updateControlValues(JoystickMode mode, double x, double y) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 20), () {
      setState(() {
        if (mode == JoystickMode.all) {
          throttle = -y; // 油門：Y軸反向
          yaw = x; // 偏航：X軸
        } else {
          forward = -y; // 前進：Y軸反向
          lateral = x; // 橫移：X軸
        }
        if (isWebSocketConnected) {
          _controller.startContinuousControl(throttle, yaw, forward, lateral);
        } else {
          _controller.stopContinuousControl();
        }
      });
    });
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
            label: "",
            mode: JoystickMode.all,
            onUpdate: (x, y) => _updateControlValues(JoystickMode.all, x, y),
            onEnd: () {
              setState(() {
                throttle = yaw = 0;
                if (isWebSocketConnected) {
                  _controller.startContinuousControl(0, 0, forward, lateral);
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
                        ? () {
                          // 使用舊版本簡潔的 ARM 邏輯
                          _controller.sendCommand('ARM');
                        }
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
                        ? () {
                          // 使用舊版本簡潔的 DISARM 邏輯
                          _controller.sendCommand('DISARM');
                        }
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 80),
            ],
          ),
          _buildJoystickWithLabel(
            label: "",
            mode: JoystickMode.all,
            onUpdate:
                (x, y) => _updateControlValues(
                  JoystickMode.horizontalAndVertical,
                  x,
                  y,
                ),
            onEnd: () {
              setState(() {
                forward = lateral = 0;
                if (isWebSocketConnected) {
                  _controller.startContinuousControl(throttle, yaw, 0, 0);
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
    double xValue = (label == '') ? yaw : lateral;
    double yValue = (label == '') ? throttle : forward;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 160,
          height: 160,
          child: Joystick(
            stick: AnimatedJoystickStick(x: xValue, y: yValue),
            base: JoystickBases(mode: mode),
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

  Future<void> takePhoto(BuildContext context, VideoRecordingService service) async {
    try {
      final filePath = await service.capturePhoto();
      log.info('拍照成功: $filePath');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('拍照成功')),
      );
    } catch (e) {
      log.severe('拍照錯誤: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('拍照錯誤: $e')),
      );
    }
  }

  @override
  void dispose() {
// 現有清理代碼保持不變
    _debounceTimer?.cancel();
    _controlDebounceTimer?.cancel();
    _anglePollTimer?.cancel();
    _locationUpdateTimer?.cancel();
    _pulseController.dispose();
    _fullScreenController.dispose();
    _controller.dispose();
    _stream.dispose();
    // 清理錄影服務
    _record.removeListener(_onRecordingStateChanged);
    _record.dispose();

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              onTap: _toggleFullScreen,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                decoration: BoxDecoration(
                  color: Colors.black,
                  boxShadow:
                      isFullScreen
                          ? [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.8),
                              blurRadius: 20,
                            ),
                          ]
                          : null,
                ),
                child: AnimatedBuilder(
                  animation: _fullScreenAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: 1.0 + _fullScreenAnimation.value * 0.1,
                      child:
                          _currentFrame != null
                              ? Transform.rotate(
                                angle: math.pi,
                                child: Image.memory(
                                  _currentFrame!,
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                  errorBuilder:
                                      (context, error, stackTrace) => Container(
                                        color: Colors.black,
                                        child: const Center(
                                          child: Text(
                                            '影像解碼錯誤',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                            ),
                                          ),
                                        ),
                                      ),
                                ),
                              )
                              : child,
                    );
                  },
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
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                                strokeWidth: 3,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Container(color: Colors.black.withOpacity(0.1)),
            if (_shouldShowServoControls()) _buildServoSlider1(),

            _buildTopStatusBar(),
            if(_auxiliaryLine)
              Positioned.fill(
                child: IgnorePointer(child: CustomPaint(painter: GridPainter())),
              ),
            if (_shouldShowControls()) _buildBottomControlArea(),
            Positioned(
              left: 20,
              bottom: MediaQuery.of(context).size.height * 0.55,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.5),
                    width: 2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      width: 150,
                      height: 100,
                      child: Stack(
                        children: [
                          _mapService.buildMiniMap(),
                          _mapService.buildMiniMapControl(context,onStateChanged: _onMapStateChanged)
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (isFullScreen)
              Positioned(
                top: 100,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
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
                onPressed: (){
                  takePhoto(context, _record);
                },
                icon: const Icon(
                  Icons.camera_alt,
                  color: Colors.white,
                  size: 28,
                ),
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
              child: RecordButton(onTap: _toggleRecording, service: _record)
            ),
          ],
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