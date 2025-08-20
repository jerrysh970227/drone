import 'package:flutter/material.dart';

class ConnectionButton extends StatelessWidget {
  final IconData icon;
  final bool isConnected;
  final VoidCallback onPressed;
  final String tooltip;
  final Animation<double> pulseAnimation;

  const ConnectionButton({
    super.key,
    required this.icon,
    required this.isConnected,
    required this.onPressed,
    required this.tooltip,
    required this.pulseAnimation,
  });

  @override
  Widget build(BuildContext context) {
    Color activeColor = Colors.greenAccent.shade700;
    Color inactiveColor = Colors.redAccent.shade400;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isConnected
                  ? activeColor.withOpacity(0.25)
                  : inactiveColor.withOpacity(0.25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isConnected
                    ? activeColor.withOpacity(0.5)
                    : inactiveColor.withOpacity(0.5),
                width: 1.5,
              ),
            ),
            child: AnimatedBuilder(
              animation: pulseAnimation,
              builder: (context, child) => Transform.scale(
                scale: isConnected ? pulseAnimation.value : 1.0,
                child: Icon(
                  icon,
                  color: isConnected ? activeColor : inactiveColor,
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