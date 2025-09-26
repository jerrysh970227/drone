import 'package:flutter/material.dart';

class AnimatedJoystickStick extends StatefulWidget {
  final double x;
  final double y;

  const AnimatedJoystickStick({super.key, required this.x, required this.y});

  @override
  _AnimatedJoystickStickState createState() => _AnimatedJoystickStickState();
}

class _AnimatedJoystickStickState extends State<AnimatedJoystickStick>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(AnimatedJoystickStick oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.x != 0 || widget.y != 0) &&
        (_scaleController.status == AnimationStatus.dismissed ||
            _scaleController.status == AnimationStatus.reverse)) {
      _scaleController.forward();
    } else if (widget.x == 0 &&
        widget.y == 0 &&
        (_scaleController.status == AnimationStatus.completed ||
            _scaleController.status == AnimationStatus.forward)) {
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