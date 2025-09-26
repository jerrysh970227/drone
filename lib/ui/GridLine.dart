import 'package:flutter/material.dart';

class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.3) // 半透明白色
      ..strokeWidth = 1;

    // 垂直線 (三等分)
    final dx = size.width / 3;
    for (int i = 1; i < 3; i++) {
      canvas.drawLine(Offset(dx * i, 0), Offset(dx * i, size.height), paint);
    }

    // 水平線 (三等分)
    final dy = size.height / 3;
    for (int i = 1; i < 3; i++) {
      canvas.drawLine(Offset(0, dy * i), Offset(size.width, dy * i), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}