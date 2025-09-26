import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_joystick/flutter_joystick.dart';

class JoystickBases extends StatelessWidget {
  final JoystickMode mode;

  const JoystickBases({super.key, this.mode = JoystickMode.all});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(75), // 確保是圓形
      child: Stack(
        children: [
          // 背景模糊 (玻璃感)
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
              ),
            ),
          ),
          // 上層高光（液體感）
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    Colors.white.withOpacity(0.2),
                    Colors.transparent,
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
          ),
          // 中心畫布 (十字線)
          Center(
            child: CustomPaint(
              painter: JoystickCrosshairPainter(),
              size: const Size(150, 150),
            ),
          ),
        ],
      ),
    );
  }
}


class JoystickCrosshairPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint =
    Paint()
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