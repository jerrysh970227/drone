import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'drone_controller.dart';
import 'constants.dart';
import 'Photo_mode_setting.dart';
import 'drone_joystick_page.dart';
import 'main.dart';

class DroneDisplayOnlyPage extends StatefulWidget {
  const DroneDisplayOnlyPage({super.key});

  @override
  State<DroneDisplayOnlyPage> createState() => _DroneDisplayOnlyPageState();
}

class _DroneDisplayOnlyPageState extends State<DroneDisplayOnlyPage> with TickerProviderStateMixin {
  final Logger log = Logger('DroneDisplayOnlyPage');
  late final DroneController _controller;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  bool isCameraConnected = false;
  bool isStreamLoaded = false;
  bool isWebSocketConnected = false;
  bool isRecording = false;
  double? _servoAngle = 0.0; // 使用 nullable 類型以與 DroneJoystickPage 一致
  double servoSpeed = 0.0; // 新增 servoSpeed 變數
  bool _isDraggingServo = false;
  bool _ledEnabled = false; // 新增 LED 狀態
  Timer? _debounceTimer;
  Socket? _socket;
  StreamSubscription? _socketSubscription;
  Uint8List? _currentFrame;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat(reverse: true);

    _controller = DroneController(
      onStatusChanged: (status, connected, [angle, led]) {
        setState(() {
          isWebSocketConnected = connected;
          log.info('WebSocket 狀態: $status, 連線: $connected');
          if (angle != null && angle >= -45.0 && angle <= 135.0) {
            _servoAngle = angle;
            servoSpeed = (angle + 45) / 180; // 將角度映射到速度 [-45°~135°] -> [0~1]
            log.info('伺服器回傳角度更新: ${_servoAngle?.toStringAsFixed(1)}°');
          }
          if (led != null) {
            _ledEnabled = led;
            log.info('LED 狀態更新: $_ledEnabled');
          }
        });
      },
    );
    _controller.connect();
    _connectToStream();
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
        timeout: const Duration(seconds: 5),
      );
      log.info('成功連接到視訊串流：${AppConfig.droneIP}:${AppConfig.videoPort}');
    } catch (e) {
      setState(() {
        isStreamLoaded = false;
        isCameraConnected = false;
      });
      log.severe('連線失敗：$e');
      _scheduleStreamReconnect();
      return;
    }

    List<int> buffer = [];
    _socketSubscription = _socket!.listen(
          (data) {
        try {
          buffer.addAll(data);
          int start, end;
          while ((start = _findJpegStart(buffer)) != -1 && (end = _findJpegEnd(buffer, start)) != -1) {
            final frame = buffer.sublist(start, end + 2);
            buffer = buffer.sublist(end + 2);
            setState(() {
              _currentFrame = Uint8List.fromList(frame);
              isCameraConnected = true;
            });
          }
          if (buffer.length > 200000) {
            buffer = buffer.sublist(buffer.length - 100000);
            log.warning('緩衝區過大，已裁剪至 ${buffer.length} 位元組');
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
  }

  void _scheduleStreamReconnect() {
    Timer(const Duration(seconds: 5), () {
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

  void _toggleCameraConnection() {
    if (isStreamLoaded || _socket != null) {
      _disconnectFromStream();
    } else {
      _connectToStream();
    }
  }

  void _toggleWebSocketConnection() {
    if (isWebSocketConnected) {
      _controller.disconnect();
    } else {
      _controller.connect();
    }
  }

  void _toggleLed() {
    if (isWebSocketConnected) {
      _controller.sendLedCommand('LED_TOGGLE');
      log.info('發送 LED 切換指令');
    } else {
      log.warning('WebSocket未連線，LED指令未發送');
    }
  }

  void startRecording() async {
    try {
      final socket = await Socket.connect(AppConfig.droneIP, 12345);
      socket.write('start_recording');
      await socket.flush();
      socket.listen((data) {
        log.info('錄影回應: ${String.fromCharCodes(data)}');
        socket.close();
      }, onDone: () {
        socket.destroy();
      });
      setState(() {
        isRecording = true;
      });
    } catch (e) {
      log.severe('無法開始錄影: $e');
    }
  }

  void stopRecording() async {
    try {
      final socket = await Socket.connect(AppConfig.droneIP, 12345);
      socket.write('stop_recording');
      await socket.flush();
      socket.listen((data) {
        log.info('錄影回應: ${String.fromCharCodes(data)}');
        socket.close();
      }, onDone: () {
        socket.destroy();
      });
      setState(() {
        isRecording = false;
      });
    } catch (e) {
      log.severe('無法停止錄影: $e');
    }
  }

  void _updateServoAngle(double newAngle) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 20), () {
      setState(() {
        final clampedAngle = newAngle.clamp(-45.0, 135.0); // 與 DroneController 的範圍一致
        if ((clampedAngle - (_servoAngle ?? 0.0)).abs() > 0.1) {
          _servoAngle = clampedAngle;
          servoSpeed = (_servoAngle! + 45) / 180; // 將角度映射到速度
          if (isWebSocketConnected) {
            _controller.sendServoAngle(_servoAngle!);
            log.info('更新伺服角度: ${_servoAngle!.toStringAsFixed(1)}°');
          } else {
            log.warning('WebSocket未連線，伺服指令未發送');
          }
        }
      });
    });
  }

  void _showMenuDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext dialogContext) {
        String selectedMenu = '設定';
        String selectedMode = '僅顯示';

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
                              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
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
                                  if (selectedMenu == '設定') ..._buildSettingsUI(innerContext, selectedMode, (mode) {
                                    innerSetState(() {
                                      selectedMode = mode;
                                    });
                                    if (mode == '顯示加控制') {
                                      Navigator.pushReplacement(
                                        context,
                                        MaterialPageRoute(builder: (context) => const DroneJoystickPage()),
                                      );
                                    }
                                  }, innerSetState),
                                  if (selectedMenu == '資訊') ..._buildInfoUI(innerContext),
                                  if (selectedMenu == '幫助') ..._buildHelpUI(innerContext),
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
                          icon: const Icon(Icons.close, color: Colors.white, size: 20),
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
      BuildContext context, String selectedMode, Function(String) onModeChanged, StateSetter innerSetState) {
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
      const ListTile(
        leading: Icon(Icons.adjust, color: Colors.white),
        title: Text('亮度調整', style: TextStyle(color: Colors.white)),
      ),
      const ListTile(
        leading: Icon(Icons.vibration, color: Colors.white),
        title: Text('震動反饋', style: TextStyle(color: Colors.white)),
      ),
      const SizedBox(height: 8),
      const Text(
        '模式選擇',
        style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
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
        controller: TextEditingController(text: AppConfig.droneIP),
        onChanged: (value) {
          innerSetState(() {
            AppConfig.droneIP = value;
          });
          setState(() {
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

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _pulseController.dispose();
    _controller.dispose();
    _disconnectFromStream();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
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
                    const Text(
                      '正在連線視訊串流...',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
            Container(color: Colors.black.withOpacity(0.1)),
            _buildTopStatusBar(),
            _buildServoSlider(),
            Positioned(
              right: 20,
              top: (MediaQuery.of(context).size.height - 60) / 2 - 50,
              child: IconButton(
                onPressed: () {
                  _showRecordingOptionsDialog(context);
                },
                icon: const Icon(
                  Icons.movie,
                  color: Colors.white,
                  size: 30,
                ),
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
                log.info('開始切換為直式方向並返回 Home');
                await SystemChrome.setPreferredOrientations([
                  DeviceOrientation.portraitUp,
                ]);
                log.info('直式方向設置完成');
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
              icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            _buildConnectionButton(
              icon: isWebSocketConnected ? Icons.wifi_rounded : Icons.wifi_off_rounded,
              isConnected: isWebSocketConnected,
              onPressed: _toggleWebSocketConnection,
              tooltip: 'WebSocket連線',
            ),
            const SizedBox(width: 8),
            _buildConnectionButton(
              icon: isCameraConnected ? Icons.videocam_rounded : Icons.videocam_off_rounded,
              isConnected: isCameraConnected,
              onPressed: _toggleCameraConnection,
              tooltip: '視訊串流',
            ),
            const SizedBox(width: 8),
            _buildLedButton(),
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
              color: isConnected ? activeColor.withOpacity(0.25) : inactiveColor.withOpacity(0.25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isConnected ? activeColor.withOpacity(0.5) : inactiveColor.withOpacity(0.5),
                width: 1.5,
              ),
            ),
            child: AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) => Transform.scale(
                scale: isConnected ? _pulseAnimation.value : 1.0,
                child: Icon(icon, color: isConnected ? activeColor : inactiveColor, size: 22),
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
              color: _ledEnabled ? activeColor.withOpacity(0.25) : inactiveColor.withOpacity(0.25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _ledEnabled ? activeColor.withOpacity(0.5) : inactiveColor.withOpacity(0.5),
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
                  });
                },
                onVerticalDragUpdate: (details) {
                  final double maxDragDistance = 100.0;
                  final double dragPosition = details.localPosition.dy;
                  final double normalizedPosition = (125 - dragPosition) / maxDragDistance;
                  final double newAngle = (normalizedPosition * 180 - 45).clamp(-45.0, 135.0);
                  _updateServoAngle(newAngle);
                },
                onVerticalDragEnd: (details) {
                  setState(() {
                    _isDraggingServo = false;
                    _servoAngle = 0.0;
                    servoSpeed = 0.0;
                  });
                  if (isWebSocketConnected) {
                    _controller.sendServoAngle(0.0);
                    log.info('停止伺服角度控制');
                  }
                },
                child: Container(
                  alignment: Alignment.center,
                  child: CustomPaint(
                    size: const Size(80, 200),
                    painter: ServoTrackPainter(servoSpeed: servoSpeed, isDragging: _isDraggingServo),
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

class ServoTrackPainter extends CustomPainter {
  final double servoSpeed;
  final bool isDragging;

  ServoTrackPainter({required this.servoSpeed, required this.isDragging});

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;

    // 繪製軌道
    final trackPaint = Paint()
      ..color = Colors.white60
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(centerX, 0),
      Offset(centerX, size.height),
      trackPaint,
    );

    // 繪製零點線
    final zeroPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(centerX - 10, centerY),
      Offset(centerX + 10, centerY),
      zeroPaint,
    );

    // 繪製滑塊
    final thumbPaint = Paint()
      ..color = isDragging ? Colors.blueAccent : Colors.white
      ..style = PaintingStyle.fill;
    final thumbY = centerY - (servoSpeed * 100);
    canvas.drawCircle(Offset(centerX, thumbY), 10, thumbPaint);
  }

  @override
  bool shouldRepaint(covariant ServoTrackPainter oldDelegate) {
    return oldDelegate.servoSpeed != servoSpeed || oldDelegate.isDragging != isDragging;
  }
}

class RecordButton extends StatefulWidget {
  final bool isRecording;
  final VoidCallback onTap;
  const RecordButton({super.key, required this.isRecording, required this.onTap});

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _sizeAnim;
  late Animation<BorderRadius?> _borderAnim;
  late Animation<double> _pulseAnimIcon;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: const Duration(milliseconds: 500), vsync: this);
    _sizeAnim = Tween<double>(begin: 30, end: 20).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
    _borderAnim = BorderRadiusTween(
      begin: BorderRadius.circular(30),
      end: BorderRadius.circular(8),
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine));

    _pulseAnimIcon = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

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
      onTap: () {
        widget.onTap();
      },
      child: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.3),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: widget.isRecording ? Colors.red.shade900 : Colors.grey.shade700, width: 3),
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
                      color: Colors.red.shade900.withOpacity(widget.isRecording ? 0.7 : 0.3),
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