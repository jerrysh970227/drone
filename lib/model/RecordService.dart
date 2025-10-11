import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

enum RecordingStatus { idle, recording, stopping, error, converting }
enum ConnectionStatus { disconnected, connecting, connected, reconnecting }

class VideoRecordingService extends ChangeNotifier {
  RecordingStatus _status = RecordingStatus.idle;
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  DateTime? _startTime;
  Timer? _timer;
  Timer? _reconnectTimer;
  Timer? _statusTimer; // Timer for periodic status updates
  String _serverIP;
  int _seconds = 0;
  double _recordingDuration = 0.0; // 來自服務器的精確時長
  String? _currentVideoPath;
  String? _lastError;
  List<String> _recordedVideos = [];
  Map<String, dynamic>? _serverStatus;
  Map<String, dynamic>? _storageStatus;
  bool _isRecordingActive = false; // Track if we have an active recording

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
    // 如果已經連線成功，則不重新連線
    if (isConnected) {
      debugPrint('HTTP 已連接，跳過連線嘗試');
      return;
    }
    
    // For HTTP-based service, we just check if we can reach the server
    _connectionStatus = ConnectionStatus.connecting;
    notifyListeners();

    // Test connection to media server
    _testConnection().then((success) {
      if (success) {
        _connectionStatus = ConnectionStatus.connected;
        _clearError();
        _cancelReconnectTimer();
        // Start periodic status updates
        _startStatusTimer();
        notifyListeners();
        debugPrint('HTTP 連接成功: $_serverIP:8770');
      } else {
        _handleConnectionError('無法連接到媒體服務器');
      }
    }).catchError((error) {
      _handleConnectionError('連接失敗: $error');
    });
  }

  Future<bool> _testConnection() async {
    try {
      final url = Uri.parse('ws://$_serverIP:8770/health');
      debugPrint('測試媒體服務器連接: $url');
      
      // 添加重试机制
      int retryCount = 0;
      const maxRetries = 2;
      
      while (retryCount <= maxRetries) {
        try {
          final response = await http.get(url).timeout(const Duration(seconds: 20));
          debugPrint('連接測試回應: ${response.statusCode}');
          
          if (response.statusCode == 200) {
            try {
              final data = json.decode(response.body);
              debugPrint('服務器健康狀態: ${data['status']}');
              return data['status'] == 'ok';
            } catch (e) {
              debugPrint('無法解析服務器健康回應: $e');
              return true; // 能够连接但无法解析响应也算连接成功
            }
          } else if (response.statusCode == 404) {
            // 如果健康检查端点不存在，尝试基本连接
            debugPrint('健康檢查端點不存在，嘗試基本連接測試');
            return true;
          }
        } on TimeoutException catch (e) {
          retryCount++;
          debugPrint('連接測試超時 (第$retryCount次重試): $e');
          if (retryCount > maxRetries) {
            throw e;
          }
          await Future.delayed(const Duration(seconds: 2));
        }
      }
      return false;
    } catch (e) {
      debugPrint('連接測試失敗: $e');
      return false;
    }
  }

  void _startStatusTimer() {
    _statusTimer?.cancel();
    // Increase interval from 5 to 10 seconds to reduce server load
    _statusTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (isConnected) {
        _updateStatus();
      }
    });
  }

  void _stopStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  Future<void> _updateStatus() async {
    try {
      final url = Uri.parse('ws://$_serverIP:8770/video/status');
      debugPrint('請求錄影狀態: $url');
      
      // 添加重试机制
      int retryCount = 0;
      const maxRetries = 2;
      
      while (retryCount <= maxRetries) {
        try {
          // 增加超时到30秒
          final response = await http.get(url).timeout(const Duration(seconds: 30));
          
          debugPrint('狀態回應: ${response.statusCode}');
          
          if (response.statusCode == 200) {
            final data = json.decode(response.body);
            debugPrint('狀態數據: $data');
            if (data['status'] == 'ok') {
              // Update recording status
              if (data['recording'] == true && _status != RecordingStatus.recording) {
                _status = RecordingStatus.recording;
                _isRecordingActive = true;
                _startTime = DateTime.now();
                _seconds = 0;
                _recordingDuration = 0.0;
                if (data['file'] != null) {
                  _currentVideoPath = data['file'];
                }
                _startTimer();
                notifyListeners();
              } else if (data['recording'] == false && _isRecordingActive) {
                // Recording has stopped
                _status = RecordingStatus.idle;
                _isRecordingActive = false;
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
              }
              
              // Update duration if available
              if (data['started_at'] != null) {
                final startTime = DateTime.fromMillisecondsSinceEpoch((data['started_at'] * 1000).toInt());
                _recordingDuration = DateTime.now().difference(startTime).inSeconds.toDouble();
                notifyListeners();
              }
            }
            // 成功响应，退出重试循环
            return;
          } else if (response.statusCode == 404) {
            // 如果是404错误，可能服务器不支持此端点
            debugPrint('服務器不支持狀態端點');
            return;
          }
        } on TimeoutException catch (e) {
          retryCount++;
          debugPrint('狀態更新請求超時 (第$retryCount次重試): $e');
          if (retryCount > maxRetries) {
            throw e; // 超过最大重试次数，抛出异常
          }
          // 等待一段时间再重试
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    } catch (e) {
      debugPrint('狀態更新失敗: $e');
    }
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
    _stopStatusTimer();

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
    _stopStatusTimer();
    _connectionStatus = ConnectionStatus.disconnected;
    debugPrint(' HTTP 連接已斷開');
  }

  // 公共方法
  Future<bool> startRecording({String? filename, int? duration}) async {
    // 檢查連線狀態，如果未連線則嘗試重新連線
    if (!isConnected) {
      debugPrint('未連接到服務器，嘗試重新連線...');
      await reconnect();
      
      // 等待短暫時間讓連線建立
      await Future.delayed(const Duration(milliseconds: 500));
      
      // 再次檢查連線狀態
      if (!isConnected) {
        _handleError('無法連接到媒體服務器');
        return false;
      }
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
      final uri = Uri.parse('ws://$_serverIP:8770/video/start');
      final queryParams = <String, String>{};
      
      if (filename != null) queryParams['filename'] = filename;
      if (duration != null) queryParams['duration'] = duration.toString();
      
      debugPrint('發送錄影開始請求到: $uri');
      
      // Increase timeout for recording start request since it might take time
      final response = await http.post(uri.replace(queryParameters: queryParams))
          .timeout(const Duration(seconds: 30)); // Increased from 10 to 30 seconds
      
      debugPrint('錄影開始回應: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        debugPrint('錄影開始回應數據: $data');
        if (data['status'] == 'ok') {
          _status = RecordingStatus.recording;
          _isRecordingActive = true;
          _startTime = DateTime.now();
          _seconds = 0;
          _recordingDuration = 0.0;
          // 伺服器現在會立即返回錄影檔案路徑
          if (data['file'] != null) {
            _currentVideoPath = data['file'];
          }
          _startTimer();
          notifyListeners();
          debugPrint('錄影開始成功: ${data['file']}');
          return true;
        } else {
          _handleError('錄影啟動失敗: ${data['message']}');
          return false;
        }
      } else {
        _handleError('錄影啟動請求失敗: ${response.statusCode} - ${response.reasonPhrase}');
        return false;
      }
    } on TimeoutException catch (e) {
      _handleError('錄影啟動請求超時，請檢查服務器是否正常運行');
      debugPrint('錄影啟動請求超時: $e');
      return false;
    } catch (e) {
      _handleError('發送錄影開始請求失敗: $e');
      debugPrint('錄影啟動請求錯誤: $e');
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
      final uri = Uri.parse('ws://$_serverIP:8770/video/stop');
      debugPrint('發送停止錄影請求到: $uri');
      
      // Increase timeout for recording stop request
      final response = await http.post(uri).timeout(const Duration(seconds: 30)); // Increased from 15 to 30 seconds
      
      debugPrint('停止錄影回應: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        debugPrint('停止錄影回應數據: $data');
        if (data['status'] == 'ok') {
          _status = RecordingStatus.stopping;
          notifyListeners();
          
          // Wait a bit and then update to idle
          Future.delayed(const Duration(seconds: 2), () {
            _status = RecordingStatus.idle;
            _isRecordingActive = false;
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
          
          debugPrint(' 停止錄影請求成功');
          return true;
        } else {
          _handleError('停止錄影失敗: ${data['message']}');
          return false;
        }
      } else {
        _handleError('停止錄影請求失敗: ${response.statusCode} - ${response.reasonPhrase}');
        return false;
      }
    } on TimeoutException catch (e) {
      _handleError('停止錄影請求超時，請檢查服務器是否正常運行');
      debugPrint('停止錄影請求超時: $e');
      return false;
    } catch (e) {
      _handleError('發送停止錄影請求失敗: $e');
      debugPrint('停止錄影請求錯誤: $e');
      return false;
    }
  }

  Future<String> capturePhoto({String? filename}) async {
    if (!isConnected) {
      _handleError('未連接到服務器');
      throw Exception('未連接到服務器');
    }

    try {
      final uri = Uri.parse('ws://$_serverIP:8770/photo');
      final queryParams = <String, String>{};
      
      if (filename != null) queryParams['filename'] = filename;
      
      debugPrint('發送拍照請求到: $uri');
      
      final response = await http.post(uri.replace(queryParameters: queryParams))
          .timeout(const Duration(seconds: 30)); // Increased from 15 to 30 seconds
      
      debugPrint('拍照回應: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        debugPrint('拍照回應數據: $data');
        if (data['status'] == 'ok' && data['file'] != null) {
          debugPrint('拍照成功: ${data['file']}');
          return data['file'];
        } else {
          final errorMessage = data['message'] ?? '未知錯誤';
          throw Exception('拍照失敗: $errorMessage');
        }
      } else {
        throw Exception('拍照請求失敗: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      _handleError('拍照請求超時，請檢查服務器是否正常運行');
      debugPrint('拍照請求超時: $e');
      throw Exception('拍照請求超時，請檢查服務器是否正常運行');
    } catch (e) {
      _handleError('拍照失敗: $e');
      debugPrint('拍照請求錯誤: $e');
      throw e;
    }
  }

  void requestVideoStatus() {
    if (isConnected) {
      _updateStatus();
    }
  }

  void requestStorageStatus() {
    // Not implemented for HTTP version
  }

  Future<bool> downloadRecording(String filename, String localPath) async {
    try {
      final url = Uri.parse('ws://$_serverIP:8770/media/$filename');
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
      _isRecordingActive = false;
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