import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:logging/logging.dart';
import 'drone_controller.dart';
import 'constants.dart';

class DroneJoystickPage extends StatefulWidget {
  const DroneJoystickPage({super.key});

  @override
  State<DroneJoystickPage> createState() => _DroneJoystickPageState();
}

class _DroneJoystickPageState extends State<DroneJoystickPage> with TickerProviderStateMixin {
  final Logger log = Logger('DroneJoystickPage');
  late final DroneController _controller;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  String selectedMode = '顯示加控制';

  // 控制變數
  double throttle = 0.0;
  double yaw = 0.0;
  double forward = 0.0;
  double lateral = 0.0;
  double servoSpeed = 0.0; // 馬達速度，範圍 -1.0 到 1.0
  bool isCameraConnected = false;
  bool isStreamLoaded = false;
  bool isWebSocketConnected = false;
  bool isRecording = false;

  // 其他狀態
  Timer? _debounceTimer;
  Socket? _socket;
  StreamSubscription? _socketSubscription;
  Uint8List? _currentFrame;

  @override
  void initState() {
    super.initState();
    // 設定螢幕為橫向
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // 初始化脈衝動畫（用於載入指示器）
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat(reverse: true);

    // 初始化 DroneController
    _controller = DroneController(
      onStatusChanged: (status, connected, [speed]) {
        setState(() {
          isWebSocketConnected = connected;
          log.info('WebSocket status: $status, connected: $connected');
          if (speed != null && speed >= -1.0 && speed <= 1.0) {
            servoSpeed = speed;
            log.info('Updated servo speed from server: ${servoSpeed * 100}%');
          }
        });
      },
    );
    _controller.connect();
    _connectToStream();
  }

  // 連接到視訊串流
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
      },
      onDone: () {
        log.warning('串流已關閉');
        setState(() {
          isCameraConnected = false;
          isStreamLoaded = false;
        });
        _disconnectFromStream();
      },
      cancelOnError: true,
    );
  }

  // 斷開視訊串流
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

  // 尋找 JPEG 起始標記
  int _findJpegStart(List<int> data) {
    for (int i = 0; i < data.length - 1; i++) {
      if (data[i] == 0xFF && data[i + 1] == 0xD8) return i;
    }
    return -1;
  }

  // 尋找 JPEG 結束標記
  int _findJpegEnd(List<int> data, int start) {
    for (int i = start; i < data.length - 1; i++) {
      if (data[i] == 0xFF && data[i + 1] == 0xD9) return i;
    }
    return -1;
  }

  // 切換 WebSocket 連線
  void _toggleWebSocketConnection() {
    if (isWebSocketConnected) {
      _controller.disconnect();
    } else {
      _controller.connect();
    }
  }

  // 切換視訊串流連線
  void _toggleCameraConnection() {
    if (isStreamLoaded || _socket != null) {
      _disconnectFromStream();
    } else {
      _connectToStream();
    }
  }

  // 開始錄影
  void startRecording() async {
    try {
      final socket = await Socket.connect(AppConfig.droneIP, 12345);
      socket.write('start_recording');
      await socket.flush();
      socket.listen((data) {
        log.info('Recording response: ${String.fromCharCodes(data)}');
        socket.close();
      }, onDone: () {
        socket.destroy();
      });
      setState(() {
        isRecording = true;
      });
    } catch (e) {
      log.severe('Failed to start recording: $e');
    }
  }

  // 停止錄影
  void stopRecording() async {
    try {
      final socket = await Socket.connect(AppConfig.droneIP, 12345);
      socket.write('stop_recording');
      await socket.flush();
      socket.listen((data) {
        log.info('Recording response: ${String.fromCharCodes(data)}');
        socket.close();
      }, onDone: () {
        socket.destroy();
      });
      setState(() {
        isRecording = false;
      });
    } catch (e) {
      log.severe('Failed to stop recording: $e');
    }
  }

  // 更新搖桿控制值
  void _updateControlValues(JoystickMode mode, double x, double y) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 20), () {
      setState(() {
        if (mode == JoystickMode.all) {
          throttle = -y;
          yaw = x;
        } else {
          forward = -y;
          lateral = x;
        }
        if (isWebSocketConnected) {
          _controller.startSendingControl(throttle, yaw, forward, lateral);
        } else {
          _controller.stopSendingControl();
        }
      });
    });
  }

  // 更新馬達速度
  void _updateServoSpeed(double newSpeed) {
    setState(() {
      final clampedSpeed = newSpeed.clamp(-1.0, 1.0);
      if ((clampedSpeed - servoSpeed).abs() > 0.01) {
        servoSpeed = clampedSpeed;
        if (isWebSocketConnected) {
          _controller.sendServoControl(servoSpeed);
          log.info('Sending servo speed to controller: ${servoSpeed * 100}%');
        } else {
          log.warning('WebSocket not connected, servo command not sent');
        }
      }
    });
  }

  // 顯示菜單對話框
  void _showMenuDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext dialogContext) {
        String selectedMenu = '設定'; // 定義在外部以保持狀態

        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 400,
              // 使用動態高度，根據內容調整，避免固定高度導致的溢出
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
                builder: (BuildContext innerContext, StateSetter setState) {
                  return Stack(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min, // 確保 Column 只佔用必要高度
                        children: [
                          // 菜單項目（左右滑動）
                          SizedBox(
                            height: 75, // 固定高度，如果出事這裡的問題
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                              children: [
                                _MenuItem(
                                  icon: Icons.settings,
                                  title: '設定',
                                  isSelected: selectedMenu == '設定',
                                  onTap: () {
                                    print('Clicked 設定');
                                    setState(() {
                                      selectedMenu = '設定';
                                    });
                                  },
                                ),
                                _MenuItem(
                                  icon: Icons.info,
                                  title: '資訊',
                                  isSelected: selectedMenu == '資訊',
                                  onTap: () {
                                    print('Clicked 資訊');
                                    setState(() {
                                      selectedMenu = '資訊';
                                    });
                                  },
                                ),
                                _MenuItem(
                                  icon: Icons.help,
                                  title: '幫助',
                                  isSelected: selectedMenu == '幫助',
                                  onTap: () {
                                    print('Clicked 幫助');
                                    setState(() {
                                      selectedMenu = '幫助';
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                          // 分隔線
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 16.0),
                            height: 1.0,
                            color: Colors.white.withOpacity(0.3),
                          ),
                          // 動態內容區域（上下滑動）
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(12.0), // 減少 padding
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (selectedMenu == '設定') ..._buildSettingsUI(innerContext, selectedMode, (mode) {
                                    setState(() {
                                      selectedMode = mode;
                                    });
                                  }),
                                  if (selectedMenu == '資訊') ..._buildInfoUI(innerContext),
                                  if (selectedMenu == '幫助') ..._buildHelpUI(innerContext),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      // 浮動關閉按鈕
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

// 自訂菜單項目小部件
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

// 設定頁面 UI
  List<Widget> _buildSettingsUI(BuildContext context, String selectedMode, Function(String) onModeChanged) {
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
    ];
  }

// 資訊頁面 UI
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
      const SizedBox(height: 8), // 減少間距
      const ListTile(
        leading: Icon(Icons.info_outline, color: Colors.white),
        title: Text('版本號: 2.4.6.8', style: TextStyle(color: Colors.white)),
      ),
      const ListTile(
        leading: Icon(Icons.person, color: Colors.white),
        title: Text('開發者: 資二甲 裊裊 Team', style: TextStyle(color: Colors.white)),
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

// 幫助頁面 UI
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
      const SizedBox(height: 8), // 減少間距
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
              content: const Text('Q: 如何連線無人機?\nA: 請確保藍牙已啟用並配對設備。'),
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



  // ---彈窗結束---


  //控制留白
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
    ]); // 恢復所有方向
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
                      '',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
            Container(color: Colors.black.withOpacity(0.1)),
            _buildTopStatusBar(),
            _buildBottomControlArea(),
            _buildServoSlider(),
          ],
        ),
      ),
    );
  }

  // 頂部狀態欄
  Widget _buildTopStatusBar() {
    return Positioned(
      top: 0, // 移除硬編碼的 top: 20，讓 SafeArea 處理邊距
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
              onPressed: () => Navigator.pop(context),
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
              tooltip: 'WebSocket連接',
            ),
            const SizedBox(width: 8),
            _buildConnectionButton(
              icon: isStreamLoaded ? Icons.videocam_rounded : Icons.videocam_off_rounded,
              isConnected: isCameraConnected,
              onPressed: _toggleCameraConnection,
              tooltip: '視訊串流',
            ),
            const Spacer(),
            RecordButton(
              isRecording: isRecording,
              onTap: () {
                if (!isRecording) {
                  startRecording();
                } else {
                  stopRecording();
                }
              },
            ),
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

  // 連線按鈕
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
            child: Icon(
              icon,
              color: isConnected ? activeColor : inactiveColor,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }

  // 伺服馬達滑桿
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
                '馬達\n速度',
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final double painterTrackLength = constraints.maxHeight;
                  final double painterVisualWidth = constraints.maxWidth;

                  final double normalizedValue = (1.0 - servoSpeed) / 2.0;

                  final textStyle = const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  );
                  final String textContent = '${(servoSpeed * 100).round()}%';
                  final textPainter = TextPainter(
                    text: TextSpan(text: textContent, style: textStyle),
                    textDirection: TextDirection.ltr,
                  );
                  textPainter.layout(minWidth: 0, maxWidth: painterVisualWidth);
                  final double textRenderHeight = textPainter.height;
                  final double verticalPaddingInContainer = 4.0 * 2;
                  final double actualTextContainerHeight = textRenderHeight + verticalPaddingInContainer;
                  final double actualTextContainerHalfHeight = actualTextContainerHeight / 2.0;
                  final double thumbCenterY = normalizedValue * painterTrackLength;
                  final double textLabelTopPosition = thumbCenterY - actualTextContainerHalfHeight;
                  final double thumbRadius = 10.0;
                  final double spacingToTheRightOfThumb = 8.0;
                  final double textLabelLeftPosition = (painterVisualWidth / 2) + thumbRadius + spacingToTheRightOfThumb;

                  return Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      RotatedBox(
                        quarterTurns: -1,
                        child: CustomPaint(
                          size: Size(painterTrackLength, painterVisualWidth),
                          painter: ScalePainter(
                            scaleTopValue: 1.0,
                            scaleBottomValue: -1.0,
                            tickColor: Colors.white60,
                            tickStrokeWidth: 1.5,
                            tickVisualLength: 12.0,
                            zeroMarkColor: Colors.white,
                            zeroMarkStrokeWidth: 2.5,
                            zeroMarkVisualLength: 22.0,
                          ),
                        ),
                      ),
                      RotatedBox(
                        quarterTurns: -1,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 6,
                            thumbShape: RoundSliderThumbShape(enabledThumbRadius: thumbRadius),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
                            overlayColor: Colors.white.withOpacity(0.2),
                            activeTrackColor: Colors.transparent,
                            inactiveTrackColor: Colors.transparent,
                            thumbColor: Colors.white,
                            activeTickMarkColor: Colors.transparent,
                            inactiveTickMarkColor: Colors.transparent,
                            showValueIndicator: ShowValueIndicator.never,
                          ),
                          child: Slider(
                            value: servoSpeed,
                            min: -1.0,
                            max: 1.0,
                            divisions: 200,
                            onChanged: (sliderRawValue) {
                              _updateServoSpeed(sliderRawValue);
                            },
                          ),
                        ),
                      ),
                      Positioned(
                        top: textLabelTopPosition,
                        left: textLabelLeftPosition,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.8),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            textContent,
                            style: textStyle,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // 底部控制區域
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
            label: '',
            mode: JoystickMode.all,
            onUpdate: (x, y) => _updateControlValues(JoystickMode.all, x, y),
            onEnd: () {
              setState(() {
                throttle = yaw = 0;
                if (isWebSocketConnected) {
                  _controller.startSendingControl(0, 0, forward, lateral);
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
                    isWebSocketConnected ? Colors.greenAccent.shade700 : Colors.grey.shade700,
                    isWebSocketConnected ? () => _controller.sendCommand('ARM') : null,
                  ),
                  const SizedBox(width: 10),
                  _buildActionButton(
                    Icons.flight_land_rounded,
                    '解除',
                    isWebSocketConnected ? Colors.redAccent.shade400 : Colors.grey.shade700,
                    isWebSocketConnected ? () => _controller.sendCommand('DISARM') : null,
                  ),
                ],
              ),
              const SizedBox(height: 80),
            ],
          ),
          _buildJoystickWithLabel(
            label: '',
            mode: JoystickMode.all,
            onUpdate: (x, y) => _updateControlValues(JoystickMode.all, x, y),
            onEnd: () {
              setState(() {
                forward = lateral = 0;
                if (isWebSocketConnected) {
                  _controller.startSendingControl(throttle, yaw, 0, 0);
                }
              });
            },
          ),
        ],
      ),
    );
  }

  // 搖桿與標籤
  Widget _buildJoystickWithLabel({
    required String label,
    required JoystickMode mode,
    required void Function(double, double) onUpdate,
    required VoidCallback onEnd,
  }) {
    double xValue = (mode == JoystickMode.all && label == '油門/偏航') ? yaw : lateral;
    double yValue = (mode == JoystickMode.all && label == '油門/偏航') ? throttle : forward;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            shadows: [Shadow(color: Colors.black87, blurRadius: 2, offset: Offset(1, 1))],
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
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.7),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            'X: ${xValue.toStringAsFixed(2)}, Y: ${yValue.toStringAsFixed(2)}',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  // 動作按鈕
  Widget _buildActionButton(IconData icon, String label, Color color, VoidCallback? onTap) {
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
}

// 動畫搖桿
class AnimatedJoystickStick extends StatefulWidget {
  final double x;
  final double y;
  const AnimatedJoystickStick({super.key, required this.x, required this.y});
  @override
  _AnimatedJoystickStickState createState() => _AnimatedJoystickStickState();
}

class _AnimatedJoystickStickState extends State<AnimatedJoystickStick> with SingleTickerProviderStateMixin {
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(duration: const Duration(milliseconds: 150), vsync: this);
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(AnimatedJoystickStick oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.x != 0 || widget.y != 0) && (_scaleController.status == AnimationStatus.dismissed || _scaleController.status == AnimationStatus.reverse)) {
      _scaleController.forward();
    } else if (widget.x == 0 && widget.y == 0 && (_scaleController.status == AnimationStatus.completed || _scaleController.status == AnimationStatus.forward)) {
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

// 搖桿十字線
class JoystickCrosshairPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.2)
      ..strokeWidth = 1.0;

    double lineLength = size.width * 0.35;
    canvas.drawLine(Offset(center.dx - lineLength / 2, center.dy), Offset(center.dx + lineLength / 2, center.dy), paint);
    canvas.drawLine(Offset(center.dx, center.dy - lineLength / 2), Offset(center.dx, center.dy + lineLength / 2), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// 搖桿底座
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
          colors: [Colors.blueGrey.shade800.withOpacity(0.5), Colors.black.withOpacity(0.6)],
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

// 錄影按鈕
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
    _controller = AnimationController(duration: const Duration(milliseconds: 300), vsync: this);
    _sizeAnim = Tween<double>(begin: 22, end: 14).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
    _borderAnim = BorderRadiusTween(
      begin: BorderRadius.circular(22),
      end: BorderRadius.circular(4),
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
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.2),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.redAccent.withOpacity(0.7), width: 2),
        ),
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Container(
                width: _sizeAnim.value,
                height: _sizeAnim.value,
                decoration: BoxDecoration(
                  color: Colors.redAccent,
                  borderRadius: _borderAnim.value,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.redAccent.withOpacity(0.5),
                      blurRadius: widget.isRecording ? 6 : 2,
                      spreadRadius: widget.isRecording ? 1 : 0,
                    ),
                  ],
                ),
                child: widget.isRecording
                    ? null
                    : FadeTransition(
                  opacity: ReverseAnimation(_pulseAnimIcon),
                  child: Icon(
                    Icons.fiber_manual_record_rounded,
                    color: Colors.white.withOpacity(0.5),
                    size: _sizeAnim.value * 0.8,
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

//設定彈窗
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
      label: Text(label, style: const TextStyle(color: Colors.black38)),
      selected: isSelected,
      selectedColor: Colors.blueAccent.withOpacity(0.6),
      backgroundColor: Colors.white24,
      onSelected: (_) => onTap(),
    );
  }
}

// 滑桿刻度繪製
class ScalePainter extends CustomPainter {
  final double scaleTopValue;
  final double scaleBottomValue;
  final Color tickColor;
  final double tickStrokeWidth;
  final double tickVisualLength;
  final Color zeroMarkColor;
  final double zeroMarkStrokeWidth;
  final double zeroMarkVisualLength;

  ScalePainter({
    this.scaleTopValue = 1.0,
    this.scaleBottomValue = -1.0,
    this.tickColor = Colors.white54,
    this.tickStrokeWidth = 1.5,
    this.tickVisualLength = 12.0,
    this.zeroMarkColor = Colors.white,
    this.zeroMarkStrokeWidth = 3.0,
    this.zeroMarkVisualLength = 24.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double trackLength = size.width;
    final double scaleVisualCenterY = size.height / 2;

    if (trackLength <= 0) return;

    final halfTickLen = tickVisualLength / 2;
    final halfZeroLen = zeroMarkVisualLength / 2;

    final tickPaint = Paint()
      ..color = tickColor
      ..strokeWidth = tickStrokeWidth
      ..style = PaintingStyle.stroke;

    final zeroPaint = Paint()
      ..color = zeroMarkColor
      ..strokeWidth = zeroMarkStrokeWidth
      ..style = PaintingStyle.stroke;

    const double step = 0.2; // 每 20% 一個刻度
    bool iterateDown = scaleTopValue > scaleBottomValue;
    double currentValue = scaleTopValue;

    while (iterateDown ? currentValue >= scaleBottomValue : currentValue <= scaleBottomValue) {
      double normalizedPosition;
      if (scaleTopValue == scaleBottomValue) {
        normalizedPosition = 0.5;
      } else {
        normalizedPosition = (currentValue - scaleTopValue) / (scaleBottomValue - scaleTopValue);
      }

      final double xPosOnTrack = normalizedPosition * trackLength;

      if (currentValue == 0.0) {
        canvas.drawLine(
          Offset(xPosOnTrack, scaleVisualCenterY - halfZeroLen),
          Offset(xPosOnTrack, scaleVisualCenterY + halfZeroLen),
          zeroPaint,
        );
      } else {
        canvas.drawLine(
          Offset(xPosOnTrack, scaleVisualCenterY - halfTickLen),
          Offset(xPosOnTrack, scaleVisualCenterY + halfTickLen),
          tickPaint,
        );
      }

      if (iterateDown) {
        currentValue -= step;
      } else {
        currentValue += step;
      }
    }
  }

  @override
  bool shouldRepaint(covariant ScalePainter oldDelegate) {
    return oldDelegate.scaleTopValue != scaleTopValue ||
        oldDelegate.scaleBottomValue != scaleBottomValue ||
        oldDelegate.tickColor != tickColor ||
        oldDelegate.tickStrokeWidth != tickStrokeWidth ||
        oldDelegate.tickVisualLength != tickVisualLength ||
        oldDelegate.zeroMarkColor != zeroMarkColor ||
        oldDelegate.zeroMarkStrokeWidth != zeroMarkStrokeWidth ||
        oldDelegate.zeroMarkVisualLength != zeroMarkVisualLength;
  }
}