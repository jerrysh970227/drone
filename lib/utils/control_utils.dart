class ControlUtils {
  static double applyDeadzone(double v, {double dz = 0.06}) {
    if (v.abs() < dz) return 0.0;
    final sign = v.isNegative ? -1.0 : 1.0;
    final mag = ((v.abs() - dz) / (1 - dz)).clamp(0.0, 1.0);
    return sign * mag;
  }

  static double applyExpo(double v, {double expo = 0.3}) {
    return v * (1 - expo) + v * v * v * expo;
  }

  static double lerp(double a, double b, double t) => a + (b - a) * t;

  static double clampAngle(double angle, {double min = -45.0, double max = 90.0}) {
    return angle.clamp(min, max);
  }
}