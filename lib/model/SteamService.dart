import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:logging/logging.dart';

/// 串流狀態回調函數類型
typedef StreamStatusCallback = void Function({
required bool isConnected,
required bool isLoading,
});

/// 新幀數據回調函數類型
typedef FrameDataCallback = void Function(Uint8List frameData);

/// 視訊串流服務類
class VideoStreamService {
  static final Logger _log = Logger('VideoStreamService');

  // 網路連線相關
  Socket? _socket;
  StreamSubscription? _socketSubscription;

  // 串流狀態
  bool _isConnected = false;
  bool _isLoading = false;

  // 數據處理相關
  List<int> _buffer = [];
  Uint8List? _currentFrame;

  // 回調函數
  StreamStatusCallback? _onStatusChanged;
  FrameDataCallback? _onFrameReceived;

  // 重連相關
  Timer? _reconnectTimer;
  int _retryCount = 0;
  static const int _maxRetries = 5;
  static const Duration _reconnectDelay = Duration(seconds: 2);
  static const Duration _connectionTimeout = Duration(seconds: 15);

  // 緩衝區管理
  static const int _maxBufferSize = 500000;
  static const int _trimBufferSize = 250000;

  /// 取得當前連線狀態
  bool get isConnected => _isConnected;

  /// 取得當前載入狀態
  bool get isLoading => _isLoading;

  /// 取得當前幀數據
  Uint8List? get currentFrame => _currentFrame;

  /// 設定狀態變更回調
  void setStatusCallback(StreamStatusCallback callback) {
    _onStatusChanged = callback;
  }

  /// 設定幀數據回調
  void setFrameCallback(FrameDataCallback callback) {
    _onFrameReceived = callback;
  }

  /// 連接到視訊串流
  Future<void> connect(String ip, int port) async {
    if (_socket != null) {
      _log.warning('已有現有連線，將先斷開');
      await disconnect();
    }

    _updateStatus(isConnected: false, isLoading: true);
    _retryCount = 0;

    await _attemptConnection(ip, port);
  }

  /// 嘗試建立連線
  Future<void> _attemptConnection(String ip, int port) async {
    while (_retryCount < _maxRetries) {
      try {
        _log.info('嘗試連接到視訊串流：$ip:$port (第 ${_retryCount + 1} 次)');

        _socket = await Socket.connect(
          ip,
          port,
          timeout: _connectionTimeout,
        );

        _log.info('成功連接到視訊串流：$ip:$port');

        // 設定串流監聽器
        _setupStreamListener();

        _updateStatus(isConnected: true, isLoading: false);
        _retryCount = 0;
        return;

      } catch (e) {
        _retryCount++;
        _log.severe('連線失敗（嘗試 $_retryCount/$_maxRetries）：$e');

        if (_retryCount < _maxRetries) {
          await Future.delayed(_reconnectDelay);
        } else {
          _log.severe('視訊串流連線失敗，已達到最大重試次數');
          _updateStatus(isConnected: false, isLoading: false);
        }
      }
    }
  }

  /// 設定串流監聽器
  void _setupStreamListener() {
    _socketSubscription = _socket!.listen(
      _handleStreamData,
      onError: _handleStreamError,
      onDone: _handleStreamClosed,
    );
  }

  /// 處理串流數據
  void _handleStreamData(List<int> data) {
    try {
      _buffer.addAll(data);
      _processFrames();
      _manageBufferSize();
    } catch (e) {
      _log.severe('處理串流數據時出錯：$e');
    }
  }

  /// 處理串流錯誤
  void _handleStreamError(dynamic error) {
    _log.severe('串流錯誤：$error');
    _updateStatus(isConnected: false, isLoading: false);
    _cleanupConnection();
    _scheduleReconnect();
  }

  /// 處理串流關閉
  void _handleStreamClosed() {
    _log.warning('串流已關閉');
    _updateStatus(isConnected: false, isLoading: false);
    _cleanupConnection();
    _scheduleReconnect();
  }

  /// 處理幀數據
  void _processFrames() {
    int start, end;
    while ((start = _findJpegStart(_buffer)) != -1 &&
        (end = _findJpegEnd(_buffer, start)) != -1) {

      final frame = _buffer.sublist(start, end + 2);
      _buffer = _buffer.sublist(end + 2);

      _currentFrame = Uint8List.fromList(frame);

      // 觸發幀數據回調
      _onFrameReceived?.call(_currentFrame!);
    }
  }

  /// 管理緩衝區大小
  void _manageBufferSize() {
    if (_buffer.length > _maxBufferSize) {
      _buffer = _buffer.sublist(_buffer.length - _trimBufferSize);
      _log.warning('緩衝區過大，已裁剪至 ${_buffer.length} 位元組');
    }
  }

  /// 尋找 JPEG 開始標記
  int _findJpegStart(List<int> buffer) {
    for (int i = 0; i < buffer.length - 1; i++) {
      if (buffer[i] == 0xFF && buffer[i + 1] == 0xD8) {
        return i;
      }
    }
    return -1;
  }

  /// 尋找 JPEG 結束標記
  int _findJpegEnd(List<int> buffer, int start) {
    for (int i = start; i < buffer.length - 1; i++) {
      if (buffer[i] == 0xFF && buffer[i + 1] == 0xD9) {
        return i;
      }
    }
    return -1;
  }

  /// 更新狀態並觸發回調
  void _updateStatus({required bool isConnected, required bool isLoading}) {
    _isConnected = isConnected;
    _isLoading = isLoading;

    _onStatusChanged?.call(
      isConnected: isConnected,
      isLoading: isLoading,
    );
  }

  /// 安排重新連線
  void _scheduleReconnect() {
    if (_reconnectTimer?.isActive == true) return;

    _reconnectTimer = Timer(_reconnectDelay, () {
      if (!_isConnected && !_isLoading) {
        _log.info('嘗試重新連線到視訊串流...');
        // 注意：這裡需要保存 IP 和 Port 來重連
        // 可以考慮在類中保存這些參數
      }
    });
  }

  /// 清理連線資源
  void _cleanupConnection() {
    _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket?.close();
    _socket = null;
  }

  /// 斷開連線
  Future<void> disconnect() async {
    _log.info('正在斷開視訊串流連線');

    _reconnectTimer?.cancel();
    _cleanupConnection();

    _buffer.clear();
    _currentFrame = null;

    _updateStatus(isConnected: false, isLoading: false);

    _log.info('已斷開視訊串流連線');
  }

  /// 釋放資源
  void dispose() {
    disconnect();
    _onStatusChanged = null;
    _onFrameReceived = null;
  }
}

/// 視訊串流服務的擴展功能
extension VideoStreamServiceExtensions on VideoStreamService {
  /// 取得串流統計信息
  Map<String, dynamic> getStreamStats() {
    return {
      'isConnected': isConnected,
      'isLoading': isLoading,
      'hasCurrentFrame': currentFrame != null,
      'currentFrameSize': currentFrame?.length ?? 0,
    };
  }

  /// 重設串流狀態
  Future<void> reset() async {
    await disconnect();
    // 可以在這裡添加其他重設邏輯
  }
}