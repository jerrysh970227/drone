import 'dart:ui';
import 'package:flutter/material.dart';

class VerticalAngleSlider extends StatefulWidget {
  final double angle;
  final ValueChanged<double> onAngleChanged;

  const VerticalAngleSlider({
    Key? key,
    required this.angle,
    required this.onAngleChanged,
  }) : super(key: key);

  @override
  _VerticalAngleSliderState createState() => _VerticalAngleSliderState();
}

class _VerticalAngleSliderState extends State<VerticalAngleSlider>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _glowAnim;
  double _currentAngle = 0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _glowAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
    _currentAngle = widget.angle.clamp(0.0, 180.0);
  }

  @override
  void didUpdateWidget(covariant VerticalAngleSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.angle != oldWidget.angle) {
      setState(() {
        _currentAngle = widget.angle.clamp(0.0, 180.0);
      });
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _updateAngle(double newAngle) {
    setState(() {
      _currentAngle = newAngle.clamp(0.0, 180.0);
    });
    widget.onAngleChanged(_currentAngle);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      height: 300,
      child: GestureDetector(
        onVerticalDragUpdate: (details) {
          double delta = details.delta.dy * -1; // 反向映射
          double newAngle = _currentAngle + (delta * 180 / 300); // 300px 映射到 180°
          _updateAngle(newAngle);
        },
        child: CustomPaint(
          painter: VerticalSliderPainter(
            angle: _currentAngle,
            glowAnim: _glowAnim,
          ),
          child: Center(
            child: Text(
              '${_currentAngle.round()}°',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                shadows: [
                  Shadow(color: Colors.black, blurRadius: 4, offset: Offset(1, 1)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class VerticalSliderPainter extends CustomPainter {
  final double angle;
  final Animation<double> glowAnim;

  VerticalSliderPainter({required this.angle, required this.glowAnim})
      : super(repaint: glowAnim);

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final height = size.height;
    final trackWidth = 10.0;

    // 繪製毛玻璃背景
    final bgPaint = Paint()
      ..color = Colors.black.withOpacity(0.5)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, height),
        const Radius.circular(20),
      ),
      bgPaint,
    );

    // 繪製刻度軌道
    final trackPaint = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(centerX - trackWidth / 2, 10, trackWidth, height - 20),
        const Radius.circular(5),
      ),
      trackPaint,
    );

    // 繪製刻度
    final tickPaint = Paint()
      ..color = Colors.white70
      ..strokeWidth = 2;
    final majorTickPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3;
    for (int i = 0; i <= 180; i += 15) {
      final isMajor = [0, 25, 50, 90, 180].contains(i);
      final y = 10 + (height - 20) * (1 - i / 180); // 0° 在底部，180° 在頂部
      final tickLength = isMajor ? 20.0 : 10.0;
      canvas.drawLine(
        Offset(centerX - tickLength, y),
        Offset(centerX + tickLength, y),
        isMajor ? majorTickPaint : tickPaint,
      );

      if (isMajor) {
        final textPainter = TextPainter(
          text: TextSpan(
            text: '$i',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        textPainter.paint(
          canvas,
          Offset(centerX + 15, y - textPainter.height / 2),
        );
      }
    }

    // 繪製指示器
    final indicatorY = 10 + (height - 20) * (1 - angle / 180);
    final indicatorPaint = Paint()
      ..shader = LinearGradient(
        colors: [Colors.redAccent, Colors.red],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Rect.fromLTWH(0, 0, size.width, height))
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(centerX - 15, indicatorY - 5, 30, 10),
        const Radius.circular(5),
      ),
      indicatorPaint,
    );

    // 繪製光暈效果
    final glowPaint = Paint()
      ..color = Colors.redAccent.withOpacity(glowAnim.value * 0.3)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(centerX - 20, indicatorY - 10, 40, 20),
        const Radius.circular(10),
      ),
      glowPaint,
    );
  }

  @override
  bool shouldRepaint(covariant VerticalSliderPainter oldDelegate) =>
      oldDelegate.angle != angle || oldDelegate.glowAnim.value != glowAnim.value;
}