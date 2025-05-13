import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:drone/main.dart';
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

class _DroneJoystickPageState extends State<DroneJoystickPage> {
  final Logger log = Logger('DroneJoystickPage');
  late final DroneController _controller;
  double throttle = 0.0;
  double yaw = 0.0;
  double forward = 0.0;
  double lateral = 0.0;
  bool isCameraConnected = false;
  bool isStreamLoaded = false;
  bool isWebSocketConnected = false;
  String connectionStatus = 'Disconnected';
  Timer? _debounceTimer;
  Timer? _reconnectTimer;
  List<String> errorMessages = [];
  Socket? _socket;
  StreamSubscription? _socketSubscription;
  Uint8List? _currentFrame;
  int _retries = 0;
  final int maxRetries = 5;
  bool isRecording = false;
  bool modeChanged = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _controller = DroneController(
      onStatusChanged: (status, connected) {
        setState(() {
          isWebSocketConnected = connected;
          connectionStatus = status;
          if (status.contains('Error') || status.contains('Disconnected')) {
            errorMessages.add(status);
            if (errorMessages.length > 5) errorMessages.removeAt(0);
          }
        });
      },
    );
    _connectToStream();
  }

  void _connectToStream() async {
    if (_socket != null || _retries >= maxRetries) {
      if (_retries >= maxRetries) {
        setState(() {
          errorMessages.add('已達最大重試次數，請檢查伺服器');
          isStreamLoaded = false;
          isCameraConnected = false;
        });
      }
      return;
    }

    setState(() {
      isStreamLoaded = true;
      isCameraConnected = false;
      errorMessages.add('正在連接到視訊串流... (嘗試 ${_retries + 1}/$maxRetries)');
    });

    try {
      _socket = await Socket.connect(
        AppConfig.droneIP,
        AppConfig.videoPort,
        timeout: const Duration(seconds: 5),
      );
      log.info('成功連接到視訊串流：${AppConfig.droneIP}:${AppConfig.videoPort}');
      _retries = 0;
    } catch (e) {
      setState(() {
        isStreamLoaded = false;
        isCameraConnected = false;
        errorMessages.add('連線失敗：$e');
        if (errorMessages.length > 5) errorMessages.removeAt(0);
      });
      _retries++;
      _scheduleReconnect();
      return;
    }

    List<int> buffer = [];
    _socketSubscription = _socket!.listen(
      (data) {
        try {
          buffer.addAll(data);
          int start, end;
          while ((start = _findJpegStart(buffer)) != -1 &&
              (end = _findJpegEnd(buffer, start)) != -1) {
            final frame = buffer.sublist(start, end + 2);
            buffer = buffer.sublist(end + 2);

            setState(() {
              _currentFrame = Uint8List.fromList(frame);
              isCameraConnected = true;
              errorMessages.removeWhere((msg) => msg.contains('正在連接到視訊串流'));
            });
          }

          // 適應 640x480、10fps（每幀約 10-20KB）
          if (buffer.length > 50000) {
            buffer = buffer.sublist(buffer.length - 25000);
            log.warning('緩衝區過大，已裁剪至 ${buffer.length} 位元組');
          }
        } catch (e) {
          log.severe('處理串流數據時出錯：$e');
          setState(() {
            errorMessages.add('串流處理錯誤：$e');
            if (errorMessages.length > 5) errorMessages.removeAt(0);
          });
        }
      },
      onError: (error) {
        log.severe('串流錯誤：$error');
        setState(() {
          isCameraConnected = false;
          isStreamLoaded = false;
          errorMessages.add('串流錯誤：$error');
          if (errorMessages.length > 5) errorMessages.removeAt(0);
        });
        _disconnectFromStream();
        _retries++;
        _scheduleReconnect();
      },
      onDone: () {
        log.warning('串流已關閉');
        setState(() {
          isCameraConnected = false;
          isStreamLoaded = false;
          errorMessages.add('串流已關閉');
          if (errorMessages.length > 5) errorMessages.removeAt(0);
        });
        _disconnectFromStream();
        _retries++;
        _scheduleReconnect();
      },
      cancelOnError: true,
    );
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (!isStreamLoaded && !isCameraConnected && _retries < maxRetries) {
        log.info('嘗試重新連接到視訊串流...');
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
      if (data[i] == 0xFF && data[i + 1] == 0xD9) return i + 1;
    }
    return -1;
  }

  void _toggleWebSocketConnection() {
    if (isWebSocketConnected) {
      _controller.disconnect();
    } else {
      _controller.connect();
    }
  }

  void _toggleCameraConnection() {
    if (isStreamLoaded) {
      _disconnectFromStream();
      _reconnectTimer?.cancel();
      _retries = 0;
    } else {
      _retries = 0;
      _connectToStream();
    }
  }

  void startRecording() async {
    final Socket socket = await Socket.connect(AppConfig.droneIP, 12345);
    socket.write('start_recording');
    socket.listen((data) {
      print(String.fromCharCodes(data));
    });
    setState(() {
      isRecording = true;
    });
  }

  void stopRecording() async {
    final Socket socket = await Socket.connect(AppConfig.droneIP, 12345);
    socket.write('stop_recording');
    socket.listen((data) {
      print(String.fromCharCodes(data));
    });
    setState(() {
      isRecording = false;
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _reconnectTimer?.cancel();
    _controller.dispose();
    _disconnectFromStream();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    super.dispose();
  }

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 視訊背景
          _currentFrame != null
              ? Image.memory(
                _currentFrame!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder:
                    (context, error, stackTrace) => Container(
                      color: Colors.black,
                      child: const Center(
                        child: Text(
                          '視訊解碼錯誤',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
              )
              : Container(
                color: Colors.black,
                child: const Center(child: CircularProgressIndicator()),
              ),
          // 半透明覆蓋層
          Container(color: Colors.black.withOpacity(0.3)),
          // 左上角連線按鈕和狀態
          Positioned(
            top: 30,
            left: 10,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => Home()),
                        );
                      },
                      icon: Icon(Icons.arrow_back_ios_new, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    // WebSocket 連線按鈕
                    ElevatedButton(
                      onPressed: _toggleWebSocketConnection,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 10,
                        ),
                      ),
                      child: Icon(
                        isWebSocketConnected
                            ? Icons.signal_wifi_4_bar_outlined
                            : Icons.signal_wifi_bad_outlined,
                        color: isWebSocketConnected ? Colors.green : Colors.red,
                        size: 30,
                      ),
                    ),
                    const SizedBox(width: 12),
                    // 攝影機連線按鈕
                    ElevatedButton(
                      onPressed: _toggleCameraConnection,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      child: Icon(
                        isStreamLoaded
                            ? Icons.cast_connected
                            : Icons.cast_connected_outlined,
                        color: isStreamLoaded ? Colors.green : Colors.red,
                        size: 30,
                      ),
                    ),
                    const SizedBox(width: 450),
                    // 右上角錄影控制
                    Column(
                      children: [
                        RecordButton(
                          isRecording: isRecording,
                          onTap: () {
                            setState(() {
                              isRecording = !isRecording;
                            });
                            if (isRecording) {
                              startRecording();
                            } else {
                              stopRecording();
                            }
                          },
                        ),
                        // SizedBox(height: 10,),
                        // Text("00:00",style: TextStyle(color: Colors.white),)
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '狀態：$connectionStatus',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                // 連線狀態
                if (errorMessages.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    constraints: const BoxConstraints(
                      maxWidth: 300,
                      maxHeight: 100, // 限制高度讓它可以滑動
                    ),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 6,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children:
                            errorMessages
                                .map(
                                  (msg) => Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: Text(
                                      msg,
                                      style: const TextStyle(
                                        color: Colors.redAccent,
                                        fontSize: 12,
                                        height: 0.9,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 底部控制區域
          Positioned(
            bottom: 24,
            left: 16,
            right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 左搖桿
                _buildJoystickOverlay(
                  // label: '油門 ${throttle.toStringAsFixed(1)} | 偏航 ${yaw.toStringAsFixed(1)}',
                  mode: JoystickMode.all,
                  onUpdate:
                      (x, y) => _updateControlValues(JoystickMode.all, x, y),
                  onEnd:
                      () => setState(() {
                        throttle = yaw = 0;
                        if (isWebSocketConnected) {
                          _controller.startSendingControl(
                            0,
                            0,
                            forward,
                            lateral,
                          );
                        }
                      }),
                ),
                // 動作按鈕
                Row(
                  children: [
                    _actionButton(
                      Icons.flight_takeoff,
                      '啟動',
                      isWebSocketConnected ? Colors.green : Colors.transparent,
                      isWebSocketConnected
                          ? () => _controller.sendCommand('ARM')
                          : null,
                    ),
                    const SizedBox(width: 12),
                    _actionButton(
                      Icons.flight_land,
                      '解除',
                      isWebSocketConnected ? Colors.red : Colors.transparent,
                      isWebSocketConnected
                          ? () => _controller.sendCommand('DISARM')
                          : null,
                    ),
                  ],
                ),
                // 右搖桿
                _buildJoystickOverlay(
                  // label: '前進 ${forward.toStringAsFixed(1)} | 橫移 ${lateral.toStringAsFixed(1)}',
                  mode: JoystickMode.horizontalAndVertical,
                  onUpdate:
                      (x, y) => _updateControlValues(
                        JoystickMode.horizontalAndVertical,
                        x,
                        y,
                      ),
                  onEnd:
                      () => setState(() {
                        forward = lateral = 0;
                        if (isWebSocketConnected) {
                          _controller.startSendingControl(throttle, yaw, 0, 0);
                        }
                      }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJoystickOverlay({
    // required String label,
    required JoystickMode mode,
    required void Function(double, double) onUpdate,
    required VoidCallback onEnd,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Text(label, style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.all(6),
          child: Joystick(
            stick: Container(
              width: 60,
              height: 60,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color.fromARGB(180, 255, 255, 255),
              ),
            ),
            base: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.grey.withOpacity(0.5),
              ),
            ),
            listener: (details) => onUpdate(details.x, details.y),
            onStickDragEnd: onEnd,
          ),
        ),
      ],
    );
  }

  Widget _actionButton(
    IconData icon,
    String label,
    Color color,
    VoidCallback? onTap,
  ) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: isWebSocketConnected ? Colors.white : Colors.transparent,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: isWebSocketConnected ? Colors.white : Colors.transparent,
            ),
          ),
        ],
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

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _sizeAnim = Tween<double>(begin: 50, end: 30).animate(_controller);
    _borderAnim = BorderRadiusTween(
      begin: BorderRadius.circular(25),
      end: BorderRadius.circular(6),
    ).animate(_controller);

    if (widget.isRecording) _controller.forward();
  }

  @override
  void didUpdateWidget(covariant RecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording != oldWidget.isRecording) {
      widget.isRecording ? _controller.forward() : _controller.reverse();
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
      child: Container(
        width: 60,
        height: 60,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Center(
              child: Container(
                width: _sizeAnim.value,
                height: _sizeAnim.value,
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: _borderAnim.value,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
