import 'package:flutter/material.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'joystick_crosshair_painter.dart';

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
          colors: [
            Colors.blueGrey.shade800.withOpacity(0.5),
            Colors.black.withOpacity(0.6),
          ],
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