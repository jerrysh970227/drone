import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
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

class _DroneJoystickPageState extends State<DroneJoystickPage> with TickerProviderStateMixin {
  final Logger log = Logger('DroneJoystickPage');
  late final DroneController _controller;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  String selectedMode = '顯示加控制';

  // 控制變數
  double throttle = 0.0, yaw = 0.0, forward = 0.0, lateral = 0.0, servoSpeed = 0.0;
  bool isCameraConnected = false, isStreamLoaded = false, isWebSocketConnected = false, isRecording = false;

  // 其他狀態
  Timer? _debounceTimer;
  Socket? _socket;
  StreamSubscription? _socketSubscription;
  Uint8List? _currentFrame;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);

    _pulseController = AnimationController(duration: const Duration(seconds: 2), vsync: this);
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _pulseController.repeat(reverse: true);

    _controller = DroneController(
      onStatusChanged: (status, connected, [speed]) {
        setState(() {
          isWebSocketConnected = connected;
          if (speed != null && speed >= -1.0 && speed <= 1.0) servoSpeed = speed;
        });
      },
    );
    _controller.connect();
    _connectToStream();
  }

  void _connectToStream() async {
    if (_socket != null) return;
    setState(() => isStreamLoaded = true);

    try {
      _socket = await Socket.connect(AppConfig.droneIP, AppConfig.videoPort, timeout: const Duration(seconds: 5));
    } catch (e) {
      setState(() => isStreamLoaded = isCameraConnected = false);
      return;
    }

    List<int> buffer = [];
    _socketSubscription = _socket!.listen(
          (data) {
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
        if (buffer.length > 200000) buffer = buffer.sublist(buffer.length - 100000);
      },
      onError: (_) => _disconnectFromStream(),
      onDone: () => _disconnectFromStream(),
      cancelOnError: true,
    );
  }

  void _disconnectFromStream() {
    _socketSubscription?.cancel();
    _socket?.close();
    _socket = null;
    _socketSubscription = null;
    setState(() => isStreamLoaded = isCameraConnected = false);
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

  void _toggleConnection(bool isWebSocket) {
    if (isWebSocket) {
      isWebSocketConnected ? _controller.disconnect() : _controller.connect();
    } else {
      (isStreamLoaded || _socket != null) ? _disconnectFromStream() : _connectToStream();
    }
  }

  void _handleRecording(bool start) async {
    try {
      final socket = await Socket.connect(AppConfig.droneIP, 12345);
      socket.write(start ? 'start_recording' : 'stop_recording');
      await socket.flush();
      socket.listen((data) => socket.close(), onDone: () => socket.destroy());
      setState(() => isRecording = start);
    } catch (e) {
      log.severe('Recording ${start ? 'start' : 'stop'} failed: $e');
    }
  }

  void _updateControlValues(JoystickMode mode, double x, double y) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 20), () {
      setState(() {
        if (mode == JoystickMode.all) {
          throttle = -y; yaw = x;
        } else {
          forward = -y; lateral = x;
        }
        if (isWebSocketConnected) {
          _controller.startSendingControl(throttle, yaw, forward, lateral);
        }
      });
    });
  }

  void _updateServoSpeed(double newSpeed) {
    final clampedSpeed = newSpeed.clamp(-1.0, 1.0);
    if ((clampedSpeed - servoSpeed).abs() > 0.01) {
      setState(() => servoSpeed = clampedSpeed);
      if (isWebSocketConnected) _controller.sendServoControl(servoSpeed);
    }
  }

  void _showMenuDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => _MenuDialog(
          selectedMode: selectedMode,
          onModeChanged: (mode) => setState(() => selectedMode = mode)
      ),
    );
  }

  // 根據模式判斷是否顯示組件的輔助方法
  bool _shouldShowControls() {
    return selectedMode == '顯示加控制' || selectedMode == '協同作業';
  }

  bool _shouldShowDisplayElements() {
    return selectedMode == '顯示加控制' || selectedMode == '僅顯示';
  }

  bool _shouldShowOnlyJoysticks() {
    return selectedMode == '協同作業';
  }
  bool _shouldShowRecordButton() {
    return selectedMode == '顯示加控制' || selectedMode == '僅顯示';
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _pulseController.dispose();
    _controller.dispose();
    _disconnectFromStream();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildVideoDisplay(),
            Container(color: Colors.black.withOpacity(0.1)),
            _buildTopStatusBar(),
            // 根據模式顯示不同的組件
            if (_shouldShowControls()) _buildBottomControlArea(),
            if (_shouldShowDisplayElements()) _buildServoSlider(),
            // 獨立顯示 RecordButton
            if (_shouldShowRecordButton()) _buildRecordButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoDisplay() {
    return _currentFrame != null
        ? Transform.rotate(
      angle: math.pi,
      child: Image.memory(_currentFrame!, fit: BoxFit.cover, gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _buildLoadingScreen('視訊解碼錯誤')),
    )
        : _buildLoadingScreen('');
  }

  Widget _buildLoadingScreen(String error) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (error.isEmpty) AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (_, __) => Transform.scale(
                scale: _pulseAnimation.value,
                child: const CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Colors.white), strokeWidth: 3),
              ),
            ),
            if (error.isNotEmpty) Text(error, style: const TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
      ),
    );
  }

  Widget _buildTopStatusBar() {
    return Positioned(
      top: 0, left: 16, right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(16)),
        child: Row(
          children: [
            _buildIconButton(Icons.arrow_back_ios_new, () => Navigator.push(context, MaterialPageRoute(builder: (_) => Home()))),
            const SizedBox(width: 10),
            // 在"僅顯示"模式下隱藏連接控制按鈕
            if (selectedMode != '僅顯示') ...[
              _buildConnectionButton(isWebSocketConnected ? Icons.wifi_rounded : Icons.wifi_off_rounded, isWebSocketConnected, () => _toggleConnection(true)),
              const SizedBox(width: 8),
              _buildConnectionButton(isStreamLoaded ? Icons.videocam_rounded : Icons.videocam_off_rounded, isCameraConnected, () => _toggleConnection(false)),
            ],
            const Spacer(),
            _buildIconButton(Icons.menu, _showMenuDialog),
          ],
        ),
      ),
    );
  }

  Widget _buildIconButton(IconData icon, VoidCallback onPressed) {
    return IconButton(
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.white.withOpacity(0.15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.all(10),
      ),
      icon: Icon(icon, color: Colors.white, size: 20),
    );
  }

  Widget _buildConnectionButton(IconData icon, bool isConnected, VoidCallback onPressed) {
    final color = isConnected ? Colors.greenAccent.shade700 : Colors.redAccent.shade400;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.25),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.5), width: 1.5),
        ),
        child: Icon(icon, color: color, size: 22),
      ),
    );
  }

  Widget _buildServoSlider() {
    return Positioned(
      left: 20, top: 110,
      child: Container(
        height: 250, width: 80,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.6),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 8, offset: const Offset(0, 3))],
        ),
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 16.0),
              child: Text('雲台\n角度', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold, height: 1.2), textAlign: TextAlign.center),
            ),
            const SizedBox(height: 16),
            Expanded(child: _buildSliderWithScale()),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSliderWithScale() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            RotatedBox(quarterTurns: -1, child: CustomPaint(size: Size(constraints.maxHeight, constraints.maxWidth), painter: ScalePainter())),
            RotatedBox(
              quarterTurns: -1,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 6, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 22), overlayColor: Colors.white.withOpacity(0.2),
                  activeTrackColor: Colors.transparent, inactiveTrackColor: Colors.transparent, thumbColor: Colors.white,
                  activeTickMarkColor: Colors.transparent, inactiveTickMarkColor: Colors.transparent, showValueIndicator: ShowValueIndicator.never,
                ),
                child: Slider(
                    value: servoSpeed,
                    min: -1.0,
                    max: 1.0,
                    divisions: 200,
                    // 在"僅顯示"模式下禁用滑桿控制
                    onChanged: _shouldShowDisplayElements() ?  _updateServoSpeed : null
                ),
              ),
            ),
            _buildSpeedLabel(constraints),
          ],
        );
      },
    );
  }

  Widget _buildSpeedLabel(BoxConstraints constraints) {
    final normalizedValue = (1.0 - servoSpeed) / 2.0;
    final thumbCenterY = normalizedValue * constraints.maxHeight;
    return Positioned(
      top: thumbCenterY - 15,
      left: (constraints.maxWidth / 2) + 18,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.transparent, borderRadius: BorderRadius.circular(6)),
        child: Text('${(servoSpeed * 100).round()}°', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildBottomControlArea() {
    return Positioned(
      bottom: 5, left: 110, right: 100,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _buildJoystickWithLabel('', (x, y) => _updateControlValues(JoystickMode.all, x, y), () => _resetControls(true)),
              if (_shouldShowControls())
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        _buildActionButton(Icons.flight_takeoff_rounded, '啟動', Colors.greenAccent.shade700, () => _controller.sendCommand('ARM')),
                        const SizedBox(width: 10),
                        _buildActionButton(Icons.flight_land_rounded, '解除', Colors.redAccent.shade400, () => _controller.sendCommand('DISARM')),
                      ],
                    ),
                    const SizedBox(height: 80),
                  ],
                ),
              _buildJoystickWithLabel('', (x, y) => _updateControlValues(JoystickMode.all, x, y), () => _resetControls(false)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecordButton() {
    return Positioned(
      bottom: 155, // 調整位置，避免與其他元素重疊
      right: 50,
      child: RecordButton(
        isRecording: isRecording,
        onTap: () => _handleRecording(!isRecording),
      ),
    );
  }


  void _resetControls(bool isThrottle) {
    setState(() {
      if (isThrottle) {
        throttle = yaw = 0;
        if (isWebSocketConnected) _controller.startSendingControl(0, 0, forward, lateral);
      } else {
        forward = lateral = 0;
        if (isWebSocketConnected) _controller.startSendingControl(throttle, yaw, 0, 0);
      }
    });
  }

  Widget _buildJoystickWithLabel(String label, Function(double, double) onUpdate, VoidCallback onEnd) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 160, height: 160,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(80),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 3))],
          ),
          child: Joystick(
            stick: AnimatedJoystickStick(x: lateral, y: throttle),
            base: JoystickBase(),
            listener: (details) => onUpdate(details.x, details.y),
            onStickDragEnd: onEnd,
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton(IconData icon, String label, Color color, VoidCallback? onTap) {
    return ElevatedButton(
      onPressed: isWebSocketConnected ? onTap : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: isWebSocketConnected ? color : Colors.grey.shade800,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        elevation: 4,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon, size: 22), const SizedBox(height: 5), Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600))],
      ),
    );
  }
}

// 菜單對話框組件
class _MenuDialog extends StatefulWidget {
  final String selectedMode;
  final Function(String) onModeChanged;

  const _MenuDialog({required this.selectedMode, required this.onModeChanged});

  @override
  State<_MenuDialog> createState() => _MenuDialogState();
}

class _MenuDialogState extends State<_MenuDialog> {
  late String selectedMenu = '設定';
  String currentSelectMode = '顯示加控制';

  @override
  void initState(){
    super.initState();
    currentSelectMode = widget.selectedMode;
  }


  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 450,
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.95
          ),
          margin: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            // 使用漸層背景增加現代感
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.grey.withOpacity(0.95),
                Colors.black12.withOpacity(0.85),
              ],
            ),
            borderRadius: BorderRadius.circular(24),
            // 多層陰影增加立體感
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                offset: const Offset(0, 10),
                blurRadius: 30,
                spreadRadius: 0,
              ),
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                offset: const Offset(0, 1),
                blurRadius: 5,
                spreadRadius: 0,
              ),
            ],
            // 增加細微邊框
            border: Border.all(
              color: Colors.grey.withOpacity(0.3),
              width: 1,
            ),
          ),
          // 增加背景模糊效果
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Stack(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildMenuTabs(),
                      // 現代化分隔線
                      Container(
                        height: 1,
                        width: double.infinity,
                        margin: const EdgeInsets.symmetric(horizontal: 20),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              Colors.grey.withOpacity(0.3),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(20.0),
                          physics: const BouncingScrollPhysics(),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: _buildMenuContent(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  // 現代化關閉按鈕
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.2),
                          width: 1,
                        ),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            width: 40,
                            height: 40,
                            child: Icon(
                              Icons.close_rounded,
                              color: Colors.black.withOpacity(0.7),
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenuTabs() {
    return SizedBox(
      height: 75,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _MenuItem(icon: Icons.settings, title: '設定', isSelected: selectedMenu == '設定', onTap: () => setState(() => selectedMenu = '設定')),
          SizedBox(width: 20,),
          _MenuItem(icon: Icons.info, title: '資訊', isSelected: selectedMenu == '資訊', onTap: () => setState(() => selectedMenu = '資訊')),
          SizedBox(width: 20,),
          _MenuItem(icon: Icons.help, title: '幫助', isSelected: selectedMenu == '幫助', onTap: () => setState(() => selectedMenu = '幫助')),
          SizedBox(height: 10,),
        ],
      ),
    );
  }

  List<Widget> _buildMenuContent() {
    switch (selectedMenu) {
      case '設定':
        return [
          const Text('設定', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const ListTile(leading: Icon(Icons.adjust, color: Colors.white), title: Text('亮度調整', style: TextStyle(color: Colors.white))),
          const ListTile(leading: Icon(Icons.vibration, color: Colors.white), title: Text('震動反饋', style: TextStyle(color: Colors.white))),
          const Text('模式選擇', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          // 添加模式說明
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('• 顯示加控制：完整功能模式', style: TextStyle(color: Colors.white70, fontSize: 12)),
                Text('• 僅顯示：只顯示錄影和雲台角度', style: TextStyle(color: Colors.white70, fontSize: 12)),
                Text('• 協同作業：只顯示搖桿控制', style: TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8.0,
            children: ['顯示加控制', '僅顯示', '協同作業'].map((mode) =>
                _ModeOption(label: mode, isSelected: currentSelectMode == mode, onTap: (){
                  setState(() {
                    currentSelectMode = mode;
                  });
                  widget.onModeChanged(mode);
                })
            ).toList(),
          ),
        ];
      case '資訊':
        return [
          const Text('應用資訊', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          const ListTile(leading: Icon(Icons.info_outline, color: Colors.white), title: Text('版本號: 2.4.6.8', style: TextStyle(color: Colors.white))),
          const ListTile(leading: Icon(Icons.person, color: Colors.white), title: Text('開發者: 資二甲 裊裊 Team', style: TextStyle(color: Colors.white))),
          ListTile(
            leading: const Icon(Icons.email, color: Colors.white),
            title: const Text('聯繫我們', style: TextStyle(color: Colors.white)),
            onTap: () => _showInfoDialog('聯繫我們', '請發送郵件至: jerrysh0227@gmail.com'),
          ),
        ];
      case '幫助':
        return [
          const Text('幫助與支援', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          const ListTile(leading: Icon(Icons.book, color: Colors.white), title: Text('使用手冊', style: TextStyle(color: Colors.white))),
          ListTile(
            leading: const Icon(Icons.question_answer, color: Colors.white),
            title: const Text('常見問題', style: TextStyle(color: Colors.white)),
            onTap: () => _showInfoDialog('常見問題', 'Q: 如何連線無人機?\nA: 請確保藍牙已啟用並配對設備。'),
          ),
          const ListTile(leading: Icon(Icons.support, color: Colors.white), title: Text('技術支援', style: TextStyle(color: Colors.white))),
        ];
      default:
        return [];
    }
  }

  void _showInfoDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('關閉'))],
      ),
    );
  }
}

// 簡化的組件類別
class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool isSelected;
  final VoidCallback onTap;

  const _MenuItem({required this.icon, required this.title, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: isSelected ? Colors.white : Colors.white70, size: 28),
                const SizedBox(height: 4),
                Text(title, style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontSize: 15, fontWeight: isSelected ? FontWeight.bold : FontWeight.w500)),
              ],
            ),
            if (isSelected) Container(margin: const EdgeInsets.only(top: 4), height: 2, width: 45, color: Colors.white),
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

  const _ModeOption({required this.label, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(
          label,
          style: TextStyle(
              color: isSelected ? Colors.white : Colors.black45
          )
      ),
      selected: isSelected,
      selectedColor: Colors.black.withOpacity(0.6),
      backgroundColor: Colors.white24,
      onSelected: (bool selected) {
        if (selected) {
          onTap();
        }
      },
    );
  }
}
// 保持原有的複雜組件
class AnimatedJoystickStick extends StatefulWidget {
  final double x, y;
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
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(CurvedAnimation(parent: _scaleController, curve: Curves.easeInOut));
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
            width: 55, height: 55,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [Colors.black12.withOpacity(0.5), Colors.blueGrey.shade400], begin: Alignment.topLeft, end: Alignment.bottomRight),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 6, offset: const Offset(2, 2))],
            ),
            child: Center(child: Icon(Icons.control_camera_rounded, color: Colors.white.withOpacity(0.8), size: 24)),
          ),
        );
      },
    );
  }
}

class JoystickBase extends StatelessWidget {
  const JoystickBase({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200, height: 200,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [Colors.blueGrey.shade800.withOpacity(0.5), Colors.black.withOpacity(0.6)], stops: const [0.7, 1.0]),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 10, offset: const Offset(0, 4)),
          BoxShadow(color: Colors.grey.shade900.withOpacity(0.3), spreadRadius: -5.0, blurRadius: 10.0),
        ],
      ),
      child: CustomPaint(painter: JoystickCrosshairPainter(), size: const Size(150, 150)),
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
        width: 50,
        height: 50,
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