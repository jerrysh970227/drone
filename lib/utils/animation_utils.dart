import 'package:flutter/material.dart';

class AnimationUtils {
  static AnimationController createPulseController(TickerProvider vsync) {
    return AnimationController(
      duration: const Duration(seconds: 2),
      vsync: vsync,
    );
  }

  static Animation<double> createPulseAnimation(AnimationController controller) {
    return Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeInOut),
    );
  }

  static AnimationController createScaleController(TickerProvider vsync) {
    return AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: vsync,
    );
  }

  static Animation<double> createScaleAnimation(AnimationController controller) {
    return Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeInOut),
    );
  }
}