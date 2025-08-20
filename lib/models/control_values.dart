class ControlValues {
  final double throttle;
  final double yaw;
  final double forward;
  final double lateral;
  final double smoothedThrottle;
  final double smoothedYaw;
  final double smoothedForward;
  final double smoothedLateral;

  ControlValues({
    this.throttle = 0.0,
    this.yaw = 0.0,
    this.forward = 0.0,
    this.lateral = 0.0,
    this.smoothedThrottle = 0.0,
    this.smoothedYaw = 0.0,
    this.smoothedForward = 0.0,
    this.smoothedLateral = 0.0,
  });

  ControlValues copyWith({
    double? throttle,
    double? yaw,
    double? forward,
    double? lateral,
    double? smoothedThrottle,
    double? smoothedYaw,
    double? smoothedForward,
    double? smoothedLateral,
  }) {
    return ControlValues(
      throttle: throttle ?? this.throttle,
      yaw: yaw ?? this.yaw,
      forward: forward ?? this.forward,
      lateral: lateral ?? this.lateral,
      smoothedThrottle: smoothedThrottle ?? this.smoothedThrottle,
      smoothedYaw: smoothedYaw ?? this.smoothedYaw,
      smoothedForward: smoothedForward ?? this.smoothedForward,
      smoothedLateral: smoothedLateral ?? this.smoothedLateral,
    );
  }
}