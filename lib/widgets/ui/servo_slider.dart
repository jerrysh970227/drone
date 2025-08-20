import 'package:flutter/material.dart';

class ServoSlider extends StatelessWidget {
  final bool isWebSocketConnected;
  final double? servoAngle;
  final bool isDraggingServo;
  final Function(DragStartDetails) onPanStart;
  final Function(DragUpdateDetails) onPanUpdate;
  final Function(DragEndDetails) onPanEnd;
  final VoidCallback onTap;

  const ServoSlider({
    super.key,
    required this.isWebSocketConnected,
    required this.servoAngle,
    required this.isDraggingServo,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        onPanStart: onPanStart,
        onPanUpdate: onPanUpdate,
        onPanEnd: onPanEnd,
        child: Container(
          color: Colors.transparent,
          child: Stack(
            children: [
              // 角度显示指示器
              Positioned(
                right: 80,
                top: 10,
                child: AnimatedContainer(
                  duration: Duration(milliseconds: isDraggingServo ? 150 : 300),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(isDraggingServo ? 0.8 : 0.6),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isWebSocketConnected
                          ? (isDraggingServo ? Colors.blue : Colors.blue.withOpacity(0.5))
                          : Colors.grey.withOpacity(0.5),
                      width: isDraggingServo ? 2 : 1,
                    ),
                    boxShadow: isDraggingServo ? [
                      BoxShadow(
                        color: Colors.blue.withOpacity(0.3),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ] : [],
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
                      const SizedBox(height: 2),
                      Text(
                        '${servoAngle?.toStringAsFixed(1) ?? "0.0"}°',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: isDraggingServo ? 18 : 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 拖拽提示
              if (isDraggingServo)
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
                              '${servoAngle?.toStringAsFixed(1)}°',
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

              // 连接状态提示
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