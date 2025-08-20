import 'package:flutter/material.dart';
import 'package:flutter_joystick/flutter_joystick.dart' hide JoystickBase;
import '../joystick/animation_joystick_stick.dart';
import '../joystick/joystick_base.dart';

class BottomControlArea extends StatelessWidget {
  final bool isWebSocketConnected;
  final double throttle;
  final double yaw;
  final double forward;
  final double lateral;
  final Function(JoystickMode, double, double) onJoystickUpdate;
  final VoidCallback onThrottleYawEnd;
  final VoidCallback onForwardLateralEnd;
  final VoidCallback onArmPressed;
  final VoidCallback onDisarmPressed;

  const BottomControlArea({
    super.key,
    required this.isWebSocketConnected,
    required this.throttle,
    required this.yaw,
    required this.forward,
    required this.lateral,
    required this.onJoystickUpdate,
    required this.onThrottleYawEnd,
    required this.onForwardLateralEnd,
    required this.onArmPressed,
    required this.onDisarmPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 16,
      left: 110,
      right: 100,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildJoystickWithLabel(
            label: '油門/偏航',
            mode: JoystickMode.all,
            xValue: yaw,
            yValue: throttle,
            onUpdate: (x, y) => onJoystickUpdate(JoystickMode.all, x, y),
            onEnd: onThrottleYawEnd,
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
                    isWebSocketConnected
                        ? Colors.greenAccent.shade700
                        : Colors.grey.shade700,
                    isWebSocketConnected ? onArmPressed : null,
                  ),
                  const SizedBox(width: 10),
                  _buildActionButton(
                    Icons.flight_land_rounded,
                    '解除',
                    isWebSocketConnected
                        ? Colors.redAccent.shade400
                        : Colors.grey.shade700,
                    isWebSocketConnected ? onDisarmPressed : null,
                  ),
                ],
              ),
              const SizedBox(height: 80),
            ],
          ),
          _buildJoystickWithLabel(
            label: '前進/橫移',
            mode: JoystickMode.all,
            xValue: lateral,
            yValue: forward,
            onUpdate: (x, y) => onJoystickUpdate(JoystickMode.all, x, y),
            onEnd: onForwardLateralEnd,
          ),
        ],
      ),
    );
  }

  Widget _buildJoystickWithLabel({
    required String label,
    required JoystickMode mode,
    required double xValue,
    required double yValue,
    required void Function(double, double) onUpdate,
    required VoidCallback onEnd,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            shadows: [
              Shadow(
                color: Colors.black87,
                blurRadius: 2,
                offset: Offset(1, 1),
              ),
            ],
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
      ],
    );
  }

  Widget _buildActionButton(
      IconData icon,
      String label,
      Color color,
      VoidCallback? onTap,
      ) {
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