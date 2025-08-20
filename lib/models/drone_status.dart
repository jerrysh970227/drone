class DroneStatus {
  final bool isWebSocketConnected;
  final bool isCameraConnected;
  final bool isStreamLoaded;
  final bool isRecording;
  final bool ledEnabled;
  final bool aiRecognitionEnabled;
  final bool aiRescueEnabled;
  final bool flashlightEnabled;
  final double? servoAngle;
  final bool isDraggingServo;

  DroneStatus({
    this.isWebSocketConnected = false,
    this.isCameraConnected = false,
    this.isStreamLoaded = false,
    this.isRecording = false,
    this.ledEnabled = false,
    this.aiRecognitionEnabled = false,
    this.aiRescueEnabled = false,
    this.flashlightEnabled = false,
    this.servoAngle = 0.0,
    this.isDraggingServo = false,
  });

  DroneStatus copyWith({
    bool? isWebSocketConnected,
    bool? isCameraConnected,
    bool? isStreamLoaded,
    bool? isRecording,
    bool? ledEnabled,
    bool? aiRecognitionEnabled,
    bool? aiRescueEnabled,
    bool? flashlightEnabled,
    double? servoAngle,
    bool? isDraggingServo,
  }) {
    return DroneStatus(
      isWebSocketConnected: isWebSocketConnected ?? this.isWebSocketConnected,
      isCameraConnected: isCameraConnected ?? this.isCameraConnected,
      isStreamLoaded: isStreamLoaded ?? this.isStreamLoaded,
      isRecording: isRecording ?? this.isRecording,
      ledEnabled: ledEnabled ?? this.ledEnabled,
      aiRecognitionEnabled: aiRecognitionEnabled ?? this.aiRecognitionEnabled,
      aiRescueEnabled: aiRescueEnabled ?? this.aiRescueEnabled,
      flashlightEnabled: flashlightEnabled ?? this.flashlightEnabled,
      servoAngle: servoAngle ?? this.servoAngle,
      isDraggingServo: isDraggingServo ?? this.isDraggingServo,
    );
  }
}