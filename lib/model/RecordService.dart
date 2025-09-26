import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO; // Add this import

enum RecordingStatus { idle, recording, stopping, error, converting }
enum ConnectionStatus { disconnected, connecting, connected, reconnecting }

class VideoRecordingService extends ChangeNotifier {
  RecordingStatus _status = RecordingStatus.idle;
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  DateTime? _startTime;
  Timer? _timer;
  Timer? _reconnectTimer;
  String _serverIP;
  int _seconds = 0;
  double _recordingDuration = 0.0; // 來自服務器的精確時長
  String? _currentVideoPath;
  String? _lastError;
  List<String> _recordedVideos = [];
  IO.Socket? _socket;
  Map<String, dynamic>? _serverStatus;
  Map<String, dynamic>? _storageStatus;

  // Getters
  RecordingStatus get status => _status;
  ConnectionStatus get connectionStatus => _connectionStatus;
  bool get isRecording => _status == RecordingStatus.recording;
  bool get isStopping => _status == RecordingStatus.stopping;
  bool get isConverting => _status == RecordingStatus.converting;
  bool get isConnected => _connectionStatus == ConnectionStatus.connected;
  String? get lastError => _lastError;
  String? get currentVideoPath => _currentVideoPath;
  List<String> get recordedVideos => List.unmodifiable(_recordedVideos);
  Map<String, dynamic>? get serverStatus => _serverStatus;
  Map<String, dynamic>? get storageStatus => _storageStatus;

  String get formattedTime {
    final totalSeconds = _recordingDuration > 0 ? _recordingDuration.round() : _seconds;
    return '${(totalSeconds ~/ 60).toString().padLeft(2, '0')}:${(totalSeconds % 60).toString().padLeft(2, '0')}';
  }

  int get recordingSeconds => _recordingDuration > 0 ? _recordingDuration.round() : _seconds;
  Duration get recordingDuration => Duration(milliseconds: (_recordingDuration * 1000).round());

  VideoRecordingService(this._serverIP) {
    _connect();
  }

  void updateServerIP(String newIP) {
    if (_serverIP != newIP) {
      _serverIP = newIP;
      _disconnect();
      _connect();
    }
  }

  void _connect() {
    if (_socket != null) {
      _disconnect();
    }

    _connectionStatus = ConnectionStatus.connecting;
    notifyListeners();

    try {
      _socket = IO.io('http://$_serverIP:8770',
          IO.OptionBuilder()
              .setTransports(['websocket'])
              .disableAutoConnect()
              .setTimeout(10000)
              .setReconnectionDelay(2000)
              .setReconnectionDelayMax(10000)
              .setReconnectionAttempts(5)
              .build()
      );

      _setupSocketListeners();
      _socket!.connect();

      debugPrint('正在連接到 WebSocket: $_serverIP:8770');
    } catch (e) {
      _handleConnectionError('連接失敗: $e');
    }
  }

  void _setupSocketListeners() {
    if (_socket == null) return;

    // 連接事件
    _socket!.onConnect((_) {
      debugPrint(' WebSocket 已連接');
      _connectionStatus = ConnectionStatus.connected;
      _clearError();
      _cancelReconnectTimer();
      notifyListeners();
    });

    _socket!.onDisconnect((_) {
      debugPrint(' WebSocket 已斷開連接');
      _connectionStatus = ConnectionStatus.disconnected;
      _scheduleReconnect();
      notifyListeners();
    });

    _socket!.onConnectError((data) {
      debugPrint(' WebSocket 連接錯誤: $data');
      _handleConnectionError('連接錯誤: $data');
    });

    _socket!.onError((data) {
      debugPrint(' WebSocket 錯誤: $data');
      _handleError('Socket 錯誤: $data');
    });

    // 服務器狀態事件
    _socket!.on('server_status', (data) {
      debugPrint(' 服務器狀態: $data');
      _serverStatus = Map<String, dynamic>.from(data);
      notifyListeners();
    });

    _socket!.on('storage_status', (data) {
      debugPrint(' 存儲狀態: $data');
      _storageStatus = Map<String, dynamic>.from(data);
      notifyListeners();
    });

    // 拍照事件
    _socket!.on('photo_start', (data) {
      debugPrint(' 拍照開始: $data');
    });

    _socket!.on('photo_success', (data) {
      debugPrint(' 拍照成功: $data');
      // 可以在這裡處理拍照成功的邏輯
    });

    _socket!.on('photo_error', (data) {
      debugPrint(' 拍照失敗: $data');
      _handleError('拍照失敗: ${data['error']}');
    });

    // 錄影事件
    _socket!.on('video_start', (data) {
      debugPrint(' 錄影開始: $data');
      _status = RecordingStatus.recording;
      _startTime = DateTime.now();
      _seconds = 0;
      _recordingDuration = 0.0;
      _currentVideoPath = data['file'];
      _startTimer();
      notifyListeners();
    });

    _socket!.on('video_start_success', (data) {
      debugPrint(' 錄影啟動成功: $data');
    });

    _socket!.on('video_status', (data) {
      debugPrint(' 錄影狀態更新: $data');
      if (data['recording'] == true && data['duration'] != null) {
        _recordingDuration = (data['duration'] as num).toDouble();
        if (_status != RecordingStatus.recording) {
          _status = RecordingStatus.recording;
          _startTimer();
        }
      } else if (data['recording'] == false && _status == RecordingStatus.recording) {
        _status = RecordingStatus.idle;
        _stopTimer();
      }

      if (data['file'] != null) {
        _currentVideoPath = data['file'];
      }

      notifyListeners();
    });

    _socket!.on('video_stopping', (data) {
      debugPrint(' 錄影停止中...');
      _status = RecordingStatus.stopping;
      notifyListeners();
    });

    _socket!.on('video_stop_success', (data) {
      debugPrint(' 錄影停止成功: $data');
      _status = RecordingStatus.idle;
      _stopTimer();

      if (data['file'] != null) {
        _currentVideoPath = data['file'];
        final filename = (data['file'] as String).split('/').last;
        if (!_recordedVideos.contains(filename)) {
          _recordedVideos.add(filename);
        }
      }

      _startTime = null;
      _seconds = 0;
      _recordingDuration = 0.0;
      notifyListeners();
    });

    _socket!.on('video_converting', (data) {
      debugPrint(' 文件轉換中: $data');
      _status = RecordingStatus.converting;
      notifyListeners();
    });

    _socket!.on('video_convert_success', (data) {
      debugPrint('文件轉換成功: $data');
      _status = RecordingStatus.idle;
      if (data['file'] != null) {
        _currentVideoPath = data['file'];
      }
      notifyListeners();
    });

    _socket!.on('video_convert_error', (data) {
      debugPrint('文件轉換失敗: $data');
      _handleError('文件轉換失敗: ${data['error']}');
    });

    _socket!.on('video_error', (data) {
      debugPrint(' 錄影錯誤: $data');
      _handleError('錄影錯誤: ${data['error']}');
    });
  }

  void _startTimer() {
    _stopTimer();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _seconds++;
      notifyListeners();
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleReconnect() {
    if (_connectionStatus == ConnectionStatus.reconnecting) return;

    _connectionStatus = ConnectionStatus.reconnecting;
    _cancelReconnectTimer();

    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (_connectionStatus == ConnectionStatus.reconnecting) {
        debugPrint(' 嘗試重新連接...');
        _connect();
      }
    });
  }

  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _disconnect() {
    _cancelReconnectTimer();
    _stopTimer();

    if (_socket != null) {
      _socket!.dispose();
      _socket = null;
    }

    _connectionStatus = ConnectionStatus.disconnected;
    debugPrint(' WebSocket 已斷開');
  }

  // 公共方法
  Future<bool> startRecording({String? filename, int? duration}) async {
    if (!isConnected) {
      _handleError('未連接到服務器');
      return false;
    }

    if (_status == RecordingStatus.recording) {
      debugPrint('錄影已在進行中');
      return false;
    }

    if (filename != null && !RegExp(r'^[a-zA-Z0-9_-]+\.mp4$').hasMatch(filename)) {
      _handleError('無效的文件名: $filename');
      return false;
    }

    _clearError();

    try {
      final data = <String, dynamic>{};
      if (filename != null) data['filename'] = filename;
      if (duration != null) data['duration'] = duration;

      _socket!.emit('video_start', data);
      debugPrint(' 發送錄影開始請求: $data');
      return true;
    } catch (e) {
      _handleError('發送錄影開始請求失敗: $e');
      return false;
    }
  }

  Future<bool> stopRecording() async {
    if (!isConnected) {
      _handleError('未連接到服務器');
      return false;
    }

    if (_status != RecordingStatus.recording) {
      debugPrint('沒有進行中的錄影');
      return false;
    }

    try {
      _socket!.emit('video_stop');
      debugPrint(' 發送停止錄影請求');
      return true;
    } catch (e) {
      _handleError('發送停止錄影請求失敗: $e');
      return false;
    }
  }

  Future<String> capturePhoto({String? filename}) async {
    if (!isConnected) {
      _handleError('未連接到服務器');
      throw Exception('未連接到服務器');
    }

    final completer = Completer<String>();

    void onPhotoSuccess(dynamic data) {
      if (data != null && data['file'] != null) {
        completer.complete(data['file']);
      } else {
        completer.completeError(Exception('拍照成功但未返回檔案路徑'));
      }
    }

    void onPhotoError(dynamic data) {
      final error = data != null ? data['error'] : '未知錯誤';
      completer.completeError(Exception('拍照錯誤: $error'));
    }

    _socket!.on('photo_success', onPhotoSuccess);
    _socket!.on('photo_error', onPhotoError);

    try {
      final data = <String, dynamic>{};
      if (filename != null) data['filename'] = filename;
      _socket!.emit('photo_capture', data);
      debugPrint('發送拍照請求: $data');

      final filePath = await completer.future.timeout(const Duration(seconds: 15));
      return filePath;
    } catch (e) {
      _handleError('拍照失敗: $e');
      throw e;
    } finally {
      _socket!.off('photo_success', onPhotoSuccess);
      _socket!.off('photo_error', onPhotoError);
    }
  }

  void requestVideoStatus() {
    if (isConnected) {
      _socket!.emit('video_status');
    }
  }

  void requestStorageStatus() {
    if (isConnected) {
      _socket!.emit('storage_status');
    }
  }

  Future<bool> downloadRecording(String filename, String localPath) async {
    try {
      final url = Uri.parse('http://$_serverIP:8770/media/$filename');
      final response = await http.get(url).timeout(const Duration(seconds: 60));
      debugPrint('下載回應: ${response.statusCode}');

      if (response.statusCode == 200) {
        await File(localPath).writeAsBytes(response.bodyBytes);
        return true;
      }
      throw Exception('下載失敗: ${response.statusCode}');
    } catch (e) {
      _handleError('下載錄影失敗: $e');
      return false;
    }
  }

  // 錯誤處理
  void _handleConnectionError(String error) {
    _connectionStatus = ConnectionStatus.disconnected;
    _handleError(error);
    _scheduleReconnect();
  }

  void _handleError(String error) {
    _lastError = error;
    if (_status == RecordingStatus.recording) {
      _status = RecordingStatus.error;
      _stopTimer();
    }
    notifyListeners();
    debugPrint(' 錯誤: $error');
  }

  void _clearError() {
    _lastError = null;
  }

  void resetError() {
    if (_status == RecordingStatus.error) {
      _status = RecordingStatus.idle;
      _seconds = 0;
      _recordingDuration = 0.0;
      _lastError = null;
      notifyListeners();
    }
  }

  Future<void> reconnect() async {
    debugPrint(' 手動重新連接');
    _disconnect();
    await Future.delayed(const Duration(milliseconds: 500));
    _connect();
  }

  // 獲取連接狀態文字
  String get connectionStatusText {
    switch (_connectionStatus) {
      case ConnectionStatus.disconnected:
        return '已斷線';
      case ConnectionStatus.connecting:
        return '連接中...';
      case ConnectionStatus.connected:
        return '已連接';
      case ConnectionStatus.reconnecting:
        return '重新連接中...';
    }
  }

  // 獲取錄影狀態文字
  String get recordingStatusText {
    switch (_status) {
      case RecordingStatus.idle:
        return '待機';
      case RecordingStatus.recording:
        return '錄影中';
      case RecordingStatus.stopping:
        return '停止中...';
      case RecordingStatus.converting:
        return '轉換中...';
      case RecordingStatus.error:
        return '錯誤';
    }
  }

  @override
  void dispose() {
    _disconnect();
    super.dispose();
  }
}