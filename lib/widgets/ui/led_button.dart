import 'package:flutter/material.dart';

class LedButton extends StatelessWidget {
  final bool ledEnabled;
  final VoidCallback onPressed;
  final Animation<double> pulseAnimation;

  const LedButton({
    super.key,
    required this.ledEnabled,
    required this.onPressed,
    required this.pulseAnimation,
  });

  @override
  Widget build(BuildContext context) {
    Color activeColor = Colors.yellow.shade600;
    Color inactiveColor = Colors.grey.shade600;

    return Tooltip(
      message: 'LED 控制',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: ledEnabled
                  ? activeColor.withOpacity(0.25)
                  : inactiveColor.withOpacity(0.25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: ledEnabled
                    ? activeColor.withOpacity(0.5)
                    : inactiveColor.withOpacity(0.5),
                width: 1.5,
              ),
            ),
            child: AnimatedBuilder(
              animation: pulseAnimation,
              builder: (context, child) => Transform.scale(
                scale: ledEnabled ? pulseAnimation.value : 1.0,
                child: Icon(
                  Icons.lightbulb,
                  color: ledEnabled ? activeColor : inactiveColor,
                  size: 22,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}