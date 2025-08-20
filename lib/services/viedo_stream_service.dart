import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import '../constants.dart';

class VideoStreamService {
  final Logger _log = Logger('VideoStreamService');
  Socket? _socket;
  StreamSubscription? _socketSubscription;
  List<int> _buffer = [];
  final StreamController<Uint8List> _frameController = StreamController<Uint8List>.broadcast();
  final StreamController<bool> _connectionController = StreamController<bool>.broadcast();

  Timer? _reconnectTimer;
  bool _isConnecting = false;

  Stream<Uint8List> get frameStream => _frameController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  bool get isConnected => _socket != null;
  bool get isConnecting => _isConnecting;

  Future<bool> connect() async {
    if (_socket != null || _isConnecting) return isConnected;

    _isConnecting = true;
    _connectionController.add(false);

    try {
      _socket = await Socket.connect(
        AppConfig.droneIP,
        AppConfig.videoPort,
        timeout: const Duration(seconds: 5),
      );

      _log.info('成功連接到視訊串流：${AppConfig.droneIP}:${AppConfig.videoPort}');

      _socketSubscription = _socket!.listen(
        _onDataReceived,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: true,
      );

      _isConnecting = false;
      _connectionController.add(true);
      return true;
    } catch (e) {
      _log.severe('連線失敗：$e');
      _socket = null;
      _isConnecting = false;
      _connectionController.add(false);
      _scheduleReconnect();
      return false;
    }
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _socketSubscription?.cancel();
    _socket?.close();
    _socket = null;
    _socketSubscription = null;
    _buffer.clear();
    _isConnecting = false;
    _connectionController.add(false);
  }

  void _onDataReceived(List<int> data) {
    try {
      _buffer.addAll(data);
      _processBuffer();
    } catch (e) {
      _log.severe('處理串流數據時出錯：$e');
    }
  }

  void _processBuffer() {
    int start, end;
    while ((start = _findJpegStart(_buffer)) != -1 &&
        (end = _findJpegEnd(_buffer, start)) != -1) {
      final frame = _buffer.sublist(start, end + 2);
      _buffer = _buffer.sublist(end + 2);
      _frameController.add(Uint8List.fromList(frame));
    }

    if (_buffer.length > 500000) {
      _buffer = _buffer.sublist(_buffer.length - 250000);
      _log.warning('緩衝區過大，已裁剪至 ${_buffer.length} 位元組');
    }
  }

  int _findJpegStart(List<int> data) {
    for (int i = 0; i < data.length - 1; i++) {
      if (data[i] == 0xFF && data[i + 1] == 0xD8) return i;
    }
    return -1;
  }

  int _findJpegEnd(List<int> data, int start) {
    for (int i = start; i < data.length - 1; i++) {
      if (data[i] == 0xFF && data[i + 1] == 0xD9) return i;
    }
    return -1;
  }

  void _onError(error) {
    _log.severe('串流錯誤：$error');
    disconnect();
    _scheduleReconnect();
  }

  void _onDone() {
    _log.warning('串流已關閉');
    disconnect();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (!isConnected && !_isConnecting) {
        _log.info('嘗試重新連線到視訊串流...');
        connect();
      }
    });
  }

  void dispose() {
    disconnect();
    _frameController.close();
    _connectionController.close();
  }
}