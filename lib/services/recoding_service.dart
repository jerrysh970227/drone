import 'dart:async';
import 'dart:io';
import 'package:logging/logging.dart';
import '../constants.dart';

class RecordingService {
  final Logger _log = Logger('RecordingService');
  final StreamController<bool> _recordingController = StreamController<bool>.broadcast();
  final StreamController<String> _messageController = StreamController<String>.broadcast();

  bool _isRecording = false;

  Stream<bool> get recordingStream => _recordingController.stream;
  Stream<String> get messageStream => _messageController.stream;
  bool get isRecording => _isRecording;

  Future<bool> startRecording() async {
    if (_isRecording) return true;

    try {
      final socket = await Socket.connect(
        AppConfig.droneIP,
        12345,
        timeout: const Duration(seconds: 5),
      );
      socket.write('start_recording');
      await socket.flush();

      socket.listen(
            (data) {
          _log.info('錄影回應: ${String.fromCharCodes(data)}');
          socket.close();
        },
        onDone: () => socket.destroy(),
        onError: (e) => _log.severe('錄影 socket 錯誤: $e'),
      );

      _isRecording = true;
      _recordingController.add(true);
      _messageController.add('開始錄影');
      return true;
    } catch (e) {
      _log.severe('無法開始錄影: $e');
      _messageController.add('錄影失敗: $e');
      return false;
    }
  }

  Future<bool> stopRecording() async {
    if (!_isRecording) return true;

    try {
      final socket = await Socket.connect(
        AppConfig.droneIP,
        12345,
        timeout: const Duration(seconds: 5),
      );
      socket.write('stop_recording');
      await socket.flush();

      socket.listen(
            (data) {
          _log.info('錄影回應: ${String.fromCharCodes(data)}');
          socket.close();
        },
        onDone: () => socket.destroy(),
        onError: (e) => _log.severe('錄影 socket 錯誤: $e'),
      );

      _isRecording = false;
      _recordingController.add(false);
      _messageController.add('停止錄影');
      return true;
    } catch (e) {
      _log.severe('無法停止錄影: $e');
      _messageController.add('停止錄影失敗: $e');
      return false;
    }
  }

  void dispose() {
    _recordingController.close();
    _messageController.close();
  }
}