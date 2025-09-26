import 'package:flutter/material.dart';

class ServoTrackPainter extends CustomPainter {
  final double servoAngle;
  final bool isDragging;

  ServoTrackPainter({required this.servoAngle, required this.isDragging});

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
    Paint()
      ..color = Colors.white.withOpacity(isDragging ? 0.9 : 0.5)
      ..strokeWidth = 4.0
      ..style = PaintingStyle.stroke;

    final trackPaint =
    Paint()
      ..color = Colors.grey.withOpacity(0.4)
      ..strokeWidth = 8.0
      ..style = PaintingStyle.stroke;

    final sliderPaint =
    Paint()
      ..color = isDragging ? Colors.blueAccent.shade400 : Colors.white
      ..style = PaintingStyle.fill;

    final centerX = size.width / 2;
    final trackHeight = size.height - 20;
    final trackTop = 10.0;
    final trackBottom = trackHeight + 10;

    // 繪製軌道
    canvas.drawLine(
      Offset(centerX, trackTop),
      Offset(centerX, trackBottom),
      trackPaint,
    );

    // 計算滑塊位置
    final normalized = (servoAngle + 45) / 135;
    final sliderY = trackBottom - normalized * trackHeight;
    canvas.drawCircle(
      Offset(centerX, sliderY.clamp(trackTop, trackBottom)),
      isDragging ? 12.0 : 10.0,
      sliderPaint,
    );

    // 繪製滑塊陰影
    if (isDragging) {
      canvas.drawCircle(
        Offset(centerX, sliderY.clamp(trackTop, trackBottom)),
        14.0,
        Paint()
          ..color = Colors.black.withOpacity(0.3)
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}