import 'package:flutter/material.dart';
import 'connect_button.dart';
import 'led_button.dart';

class TopStatusBar extends StatelessWidget {
  final bool isWebSocketConnected;
  final bool isCameraConnected;
  final bool isStreamLoaded;
  final bool ledEnabled;
  final Animation<double> pulseAnimation;
  final VoidCallback onBackPressed;
  final VoidCallback onWebSocketPressed;
  final VoidCallback onCameraPressed;
  final VoidCallback onLedPressed;
  final VoidCallback onMenuPressed;

  const TopStatusBar({
    super.key,
    required this.isWebSocketConnected,
    required this.isCameraConnected,
    required this.isStreamLoaded,
    required this.ledEnabled,
    required this.pulseAnimation,
    required this.onBackPressed,
    required this.onWebSocketPressed,
    required this.onCameraPressed,
    required this.onLedPressed,
    required this.onMenuPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.6),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: onBackPressed,
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withOpacity(0.15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.all(10),
              ),
              icon: const Icon(
                Icons.arrow_back_ios_new,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            ConnectionButton(
              icon: isWebSocketConnected ? Icons.wifi_rounded : Icons.wifi_off_rounded,
              isConnected: isWebSocketConnected,
              onPressed: onWebSocketPressed,
              tooltip: 'WebSocket連線',
              pulseAnimation: pulseAnimation,
            ),
            const SizedBox(width: 8),
            ConnectionButton(
              icon: isCameraConnected ? Icons.videocam_rounded : Icons.videocam_off_rounded,
              isConnected: isCameraConnected,
              onPressed: onCameraPressed,
              tooltip: '視訊串流',
              pulseAnimation: pulseAnimation,
            ),
            const SizedBox(width: 8),
            LedButton(
              ledEnabled: ledEnabled,
              onPressed: onLedPressed,
              pulseAnimation: pulseAnimation,
            ),
            const Spacer(),
            IconButton(
              onPressed: onMenuPressed,
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withOpacity(0.15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.all(10),
              ),
              icon: const Icon(Icons.menu, color: Colors.white, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}