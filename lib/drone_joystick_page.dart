import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:flutter_map/flutter_map.dart' as FMap;
import 'package:google_maps_flutter/google_maps_flutter.dart' as GMaps;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as latLng;
import 'package:logging/logging.dart';
import 'drone_controller.dart';
import 'constants.dart';
import 'Photo_mode_setting.dart';
import 'main.dart';

class DroneJoystickPage extends StatefulWidget {
  const DroneJoystickPage({super.key});

  @override
  State<DroneJoystickPage> createState() => _DroneJoystickPageState();
}

class _DroneJoystickPageState extends State<DroneJoystickPage>
    with TickerProviderStateMixin {
  bool _gestureRecognitionEnabled = false;
  bool _aiRecognitionEnabled = false;
  bool _aiRescueEnabled = false;
  bool _ledEnabled = false;
  bool _auxiliaryLine = false;
  bool _useSliderControl = false; // 控制伺服馬達方式（false: 按鈕控制, true: 滑桿）
  bool _usePhoneAsMapCenter = false; // 控制地圖中心顯示（false: 無人機位置, true: 手機位置）
  final Logger log = Logger('DroneJoystickPage');
  late final DroneController _controller;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  String selectedMode = '顯示加控制';
  String droneIP = AppConfig.droneIP;
  double throttle = 0.0;
  double yaw = 0.0;
  double forward = 0.0;
  double lateral = 0.0;

  // 平滑後的控制值
  double? _servoAngle = 0.0;
  bool _isDraggingServo = false;
  bool isCameraConnected = false;
  bool isStreamLoaded = false;
  bool isWebSocketConnected = false;
  bool isRecording = false;
  Uint8List? _currentFrame;

  Timer? _debounceTimer; // 伺服用
  Timer? _controlDebounceTimer; // 控制用
  Timer? _anglePollTimer;
  latLng.LatLng? dronePosition;
  latLng.LatLng? _phonePosition; // 手機位置
  bool isFullScreen = false;
  bool _isSatelliteView = false; // 衛星視圖切換
  // 移除 _is3DMapEnabled 變數，3D模式永久啟用
  bool _showApiKeyOverlay = true; // 控制API金鑰提示覆蓋層顯示
  GMaps.GoogleMapController? _googleMapController; // Google Maps 控制器
  // 保存當前地圖攝影機位置，避免切換模式時跳回默認位置
  GMaps.CameraPosition? _currentCameraPosition;
  bool _isMapInitialized = false; // 標記地圖是否已初始化
  late AnimationController _fullScreenController;
  late Animation<double> _fullScreenAnimation;
  Timer? _locationUpdateTimer; // 定期更新位置
  // 小地圖控制器，用於回到目前模式中心
  final FMap.MapController _miniMapController = FMap.MapController();

  List<int> _buffer = [];
  Socket? _socket;
  StreamSubscription? _socketSubscription;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );

    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat(reverse: true);

    _fullScreenController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fullScreenAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fullScreenController, curve: Curves.easeInOut),
    );

    _controller = DroneController(
      onStatusChanged: (DroneStatus status) {
        setState(() {
          isWebSocketConnected = status.isConnected;
          log.info(
            'WebSocket 狀態: ${status.connectionState}, 連線: ${status.isConnected}',
          );
          if (status.servoAngle != null &&
              status.servoAngle! >= -45.0 &&
              status.servoAngle! <= 90.0) {
            if (!_isDraggingServo) {
              _servoAngle = double.parse(status.servoAngle!.toStringAsFixed(2));
              // _lastServoUiUpdate = DateTime.now();
              log.info('伺服角度更新: ${_servoAngle!.toStringAsFixed(2)}°');
            }
          }
          if (status.ledState != null) {
            _ledEnabled = status.ledState!;
            log.info('LED 狀態更新: $_ledEnabled');
          }
          // 處理 GPS 數據
          // Note: GPS data is not part of DroneStatus in the current implementation
        });
      },
      onLogMessage: (String message, {bool isError = false}) {
        log.info('控制器訊息: $message');
        if (isError) {
          log.severe('控制器錯誤: $message');
        }
      },
    );
    _controller.connect();
    _connectToStream();

    _anglePollTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (isWebSocketConnected) {
        // Use sendCommand to request servo angle instead
        _controller.sendCommand('REQUEST_SERVO_ANGLE');
      }
    });
    _getCurrentLocation();

    // 定期更新手機位置
    _locationUpdateTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      _getCurrentLocation();
    });
  }

  Future<void> _getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        log.warning('位置服務未啟用');
        // 嘗試打開位置服務設置
        bool opened = await Geolocator.openLocationSettings();
        if (!opened) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('請在設置中啟用位置服務'),
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          log.warning('位置權限被拒絕');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('需要位置權限才能顯示手機位置'),
              duration: Duration(seconds: 3),
            ),
          );
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        log.warning('位置權限永久被拒絕');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('位置權限已被永久拒絕，請在設置中手動開啟'),
            duration: Duration(seconds: 5),
          ),
        );
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      setState(() {
        _phonePosition = latLng.LatLng(position.latitude, position.longitude);
      });
      log.info('獲取手機位置成功: ${position.latitude}, ${position.longitude}');

      // 顯示成功提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '位置更新: ${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      log.severe('獲取位置失敗: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('獲取位置失敗: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _toggleFullScreen() {
    setState(() {
      isFullScreen = !isFullScreen;
    });
    if (isFullScreen) {
      _fullScreenController.forward();
    } else {
      _fullScreenController.reverse();
    }
    log.info('全螢幕模式已切換為: $isFullScreen');
  }

  void _showFullScreenMap() {
    // 設備檢測和日誌記錄
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.shortestSide >= 600;
    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;

    log.info(
      '開始顯示全螢幕 3D 地圖 - 設備類型: ${isTablet ? "平板" : "手機"}, 螢幕尺寸: ${screenSize.width}x${screenSize.height}, 像素比: $devicePixelRatio',
    );

    // 所有設備都優先嘗試 Google Maps 3D，失敗時平板使用 FlutterMap 降級
    try {
      showDialog(
        context: context,
        barrierDismissible: true,
        builder: (BuildContext context) {
          log.info('正在建立全螢幕 3D 地圖對話框 - 設備: ${isTablet ? "平板" : "手機"}');
          return StatefulBuilder(
            builder: (BuildContext dialogContext, StateSetter dialogSetState) {
              return Dialog.fullscreen(
                child: Scaffold(
                  backgroundColor: Colors.black,
                  appBar: AppBar(
                    title: Text(
                      '無人機地圖${isTablet ? " (平板 3D 模式)" : ""}',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: isTablet ? 20 : 16,
                      ),
                    ),
                    backgroundColor: Colors.black.withOpacity(0.8),
                    iconTheme: const IconThemeData(color: Colors.white),
                    actions: [
                      // 移除 3D 模式切換按鈕，3D 永久啟用
                      // 衛星視圖切換按鈕
                      IconButton(
                        icon: Icon(
                          _isSatelliteView ? Icons.map : Icons.satellite,
                          color:
                              _isSatelliteView ? Colors.orange : Colors.white,
                          size: isTablet ? 28 : 24,
                        ),
                        onPressed: () {
                          // 儲存當前攝影機位置
                          if (_googleMapController != null) {
                            _googleMapController!.getVisibleRegion().then((
                              bounds,
                            ) {
                              final center = GMaps.LatLng(
                                (bounds.northeast.latitude +
                                        bounds.southwest.latitude) /
                                    2,
                                (bounds.northeast.longitude +
                                        bounds.southwest.longitude) /
                                    2,
                              );
                              setState(() {
                                _isSatelliteView = !_isSatelliteView;
                                // 保持當前位置和視角（所有模式都使用 3D）
                                _currentCameraPosition = GMaps.CameraPosition(
                                  target: center,
                                  zoom: _currentCameraPosition?.zoom ?? 16.0,
                                  tilt:
                                      _currentCameraPosition?.tilt ??
                                      (_isSatelliteView ? 60.0 : 45.0),
                                  bearing:
                                      _currentCameraPosition?.bearing ?? 30.0,
                                );
                              });

                              // 在當前對話框中更新地圖
                              dialogSetState(() {
                                // 觸發對話框內部重建
                              });

                              log.info(
                                '地圖視圖切換為: ${_isSatelliteView ? "衛星視圖" : "標準地圖"}，保持當前位置: ${center.latitude}, ${center.longitude}',
                              );
                            });
                          } else {
                            setState(() {
                              _isSatelliteView = !_isSatelliteView;
                            });
                            dialogSetState(() {});
                            log.info(
                              '地圖視圖切換為: ${_isSatelliteView ? "衛星視圖" : "標準地圖"}（無控制器）',
                            );
                          }
                        },
                        tooltip: _isSatelliteView ? '切換到標準地圖' : '切換到衛星視圖',
                      ),
                      IconButton(
                        icon: Icon(Icons.my_location, size: isTablet ? 28 : 24),
                        onPressed: () {
                          log.info('重新獲取手機位置 - 設備: ${isTablet ? "平板" : "手機"}');
                          _getCurrentLocation();
                          // 更新 Google Maps 攝影機位置（所有模式都使用 3D）
                          if (_googleMapController != null &&
                              _phonePosition != null) {
                            _googleMapController!.animateCamera(
                              GMaps.CameraUpdate.newCameraPosition(
                                GMaps.CameraPosition(
                                  target: GMaps.LatLng(
                                    _phonePosition!.latitude,
                                    _phonePosition!.longitude,
                                  ),
                                  zoom: 16.0,
                                  tilt: _isSatelliteView ? 60.0 : 45.0,
                                  // 所有模式都使用 3D
                                  bearing: 30.0,
                                ),
                              ),
                            );
                          }
                        },
                        tooltip: '定位手機位置',
                      ),
                      // 平板專用：FlutterMap 降級按鈕
                      if (isTablet)
                        IconButton(
                          icon: const Icon(Icons.layers, size: 28),
                          onPressed: () {
                            Navigator.of(context).pop();
                            _showTabletOptimizedMap();
                            log.info('平板切換到 FlutterMap 降級模式');
                          },
                          tooltip: '切換到備援地圖',
                        ),
                      IconButton(
                        icon: Icon(Icons.close, size: isTablet ? 28 : 24),
                        onPressed: () {
                          log.info('關閉全螢幕地圖 - 設備: ${isTablet ? "平板" : "手機"}');
                          Navigator.of(dialogContext).pop();
                        },
                        tooltip: '關閉',
                      ),
                    ],
                  ),
                  body: _buildFullScreenMapBody(dialogSetState),
                ),
              );
            },
          );
        },
      );
      log.info('全螢幕 3D 地圖對話框已啟動 - 設備: ${isTablet ? "平板" : "手機"}');
    } catch (e) {
      log.severe('Google Maps 展示錯誤: $e - 設備: ${isTablet ? "平板" : "手機"}');

      // 平板設備的特殊處理邏輯 - 自動降級到 FlutterMap
      if (isTablet) {
        log.info('平板設備 Google Maps 失敗，自動切換到優化版 FlutterMap');
        _showTabletOptimizedMap();
      } else {
        // 手機設備的簡單處理
        _showFlutterMapFallback();
      }
    }
  }

  // 專為平板優化的地圖顯示方法
  void _showTabletOptimizedMap() {
    final screenSize = MediaQuery.of(context).size;
    log.info('顯示平板優化地圖 - 螢幕尺寸: ${screenSize.width}x${screenSize.height}');

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return Dialog.fullscreen(
          child: Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              title: const Text(
                '無人機地圖 (平板備援模式)',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                ),
              ),
              backgroundColor: Colors.black.withOpacity(0.8),
              iconTheme: const IconThemeData(color: Colors.white),
              actions: [
                IconButton(
                  icon: Icon(
                    _isSatelliteView ? Icons.map : Icons.satellite,
                    color: _isSatelliteView ? Colors.orange : Colors.white,
                    size: 28,
                  ),
                  onPressed: () {
                    setState(() {
                      _isSatelliteView = !_isSatelliteView;
                    });
                    // 重新顯示地圖以應用新設置
                    Navigator.of(context).pop();
                    _showTabletOptimizedMap();
                    log.info('平板地圖切換為: ${_isSatelliteView ? "衛星視圖" : "標準地圖"}');
                  },
                  tooltip: _isSatelliteView ? '切換到標準地圖' : '切換到衛星視圖',
                ),
                IconButton(
                  icon: const Icon(
                    Icons.view_in_ar,
                    size: 28,
                    color: Colors.cyan,
                  ),
                  onPressed: () {
                    Navigator.of(context).pop();
                    _showFullScreenMap(); // 嘗試使用 Google Maps 3D
                    log.info('平板嘗試切換到 Google Maps 3D 模式');
                  },
                  tooltip: '嘗試 3D 模式 (Google Maps)',
                ),
                IconButton(
                  icon: const Icon(Icons.my_location, size: 28),
                  onPressed: () {
                    _getCurrentLocation();
                    log.info('平板設備重新獲取位置');
                  },
                  tooltip: '定位手機位置',
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 28),
                  onPressed: () {
                    Navigator.of(context).pop();
                    log.info('關閉平板地圖');
                  },
                  tooltip: '關閉',
                ),
              ],
            ),
            body: _buildTabletFlutterMap(),
          ),
        );
      },
    );
  }

  // 為平板構建優化的 FlutterMap
  Widget _buildTabletFlutterMap() {
    log.info('構建平板專用 FlutterMap - 衛星模式: $_isSatelliteView');

    // 根據設置決定地圖中心位置
    latLng.LatLng mapCenter;
    if (_usePhoneAsMapCenter) {
      mapCenter =
          _phonePosition ??
          dronePosition ??
          const latLng.LatLng(25.0330, 121.5654); // 台北101附近
      log.info(
        '平板地圖中心設為手機位置: ${_phonePosition?.latitude}, ${_phonePosition?.longitude}',
      );
    } else {
      mapCenter =
          dronePosition ??
          _phonePosition ??
          const latLng.LatLng(25.0330, 121.5654); // 台北101附近
      log.info(
        '平板地圖中心設為無人機位置: ${dronePosition?.latitude}, ${dronePosition?.longitude}',
      );
    }

    return FMap.FlutterMap(
      options: FMap.MapOptions(
        initialCenter: mapCenter,
        initialZoom: 16.0,
        // 適合的初始縮放級別
        minZoom: 3.0,
        maxZoom: 22.0,
        interactionOptions: const FMap.InteractionOptions(
          flags: FMap.InteractiveFlag.all,
        ),
      ),
      children: [
        FMap.TileLayer(
          urlTemplate:
              _isSatelliteView
                  ? 'https://mt{s}.google.com/vt/lyrs=s&x={x}&y={y}&z={z}&hl=zh-TW' // Google 衛星圖
                  : 'https://mt{s}.google.com/vt/lyrs=m&x={x}&y={y}&z={z}&hl=zh-TW',
          // Google 標準地圖
          subdomains: const ['0', '1', '2', '3'],
          userAgentPackageName: 'com.example.drone_app',
        ),
        // 標記層
        if (dronePosition != null || _phonePosition != null)
          FMap.MarkerLayer(
            markers: [
              // 手機位置標記（平板優化尺寸）
              if (_phonePosition != null)
                FMap.Marker(
                  point: _phonePosition!,
                  width: 50.0, // 平板使用較大的標記
                  height: 50.0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.8),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.tablet_android,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                ),
              // 無人機位置標記（平板優化尺寸）
              if (dronePosition != null)
                FMap.Marker(
                  point: dronePosition!,
                  width: 55.0, // 平板使用較大的標記
                  height: 55.0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.8),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.airplanemode_active,
                      color: Colors.white,
                      size: 35,
                    ),
                  ),
                ),
            ],
          ),
        // 平板專用的狀態顯示層
        Positioned(
          top: 20,
          left: 20,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(0.2)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isSatelliteView ? Icons.satellite : Icons.map,
                  color: _isSatelliteView ? Colors.orange : Colors.green,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  _isSatelliteView ? '衛星模式' : '標準地圖',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
        // 平板備援模式提示訊息
        Positioned(
          bottom: 20,
          left: 20,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.8),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withOpacity(0.5)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.info_outline, color: Colors.orange, size: 16),
                    SizedBox(width: 6),
                    Text(
                      '平板備援模式',
                      style: TextStyle(
                        color: Colors.orange,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 4),
                Text(
                  '穩定的 2D 地圖顯示，無 3D 建築功能',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
                SizedBox(height: 2),
                Text(
                  '如需 3D 功能，請嘗試 Google Maps 模式',
                  style: TextStyle(color: Colors.white60, fontSize: 10),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFullScreenMapBody([StateSetter? dialogSetState]) {
    // 獲取螢幕資訊進行平板檢測
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.shortestSide >= 600; // 平板檢測
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;

    log.info(
      '設備資訊 - 螢幕尺寸: ${screenSize.width}x${screenSize.height}, 最短邊: ${screenSize.shortestSide}, 是否為平板: $isTablet, 像素比: $pixelRatio',
    );

    // 當 API 金鑰無效或 Google Maps 無法使用時，使用 FlutterMap 作為備援
    try {
      return Stack(
        children: [
          GMaps.GoogleMap(
            // 使用新的地圖類型選擇方法，確保 3D 衛星模式正確運作
            mapType: _determineOptimalMapType(),
            initialCameraPosition:
                _currentCameraPosition ??
                GMaps.CameraPosition(
                  target: _determineMapCenter(),

                  // 所有模式都使用 3D，平板使用更高縮放以確保 3D 建築顯示
                  zoom: isTablet ? 18.0 : 16.0,
                  // 平板使用更高縮放級別
                  tilt: _isSatelliteView ? 70.0 : (isTablet ? 60.0 : 45.0),
                  // 平板使用更大 3D 傾斜角度
                  bearing: 45.0, // 更好的 3D 旋轉角度
                ),
            onMapCreated: (GMaps.GoogleMapController controller) {
              _googleMapController = controller;
              _isMapInitialized = true;

              // 獲取設備類型
              final screenSize = MediaQuery.of(context).size;
              final isTablet = screenSize.shortestSide >= 600;

              log.info(
                '${isTablet ? "平板" : "手機"} Google Maps 控制器初始化 - 永久 3D 模式, 衛星模式: $_isSatelliteView, 地圖類型: ${_determineOptimalMapType()}',
              );

              if (isTablet) {
                // 平板專用：更積極的 3D 加載策略
                log.info('平板設備啟動強化 3D 建築加載模式');

                // 第一次：立即強制設置
                _force3DView(controller);

                // 第二次：1 秒後再次強化
                Timer(const Duration(seconds: 1), () {
                  if (mounted && _googleMapController != null) {
                    _force3DView(_googleMapController!);
                    log.info('平板 3D 建築第一次強化完成');
                  }
                });

                // 第三次：3 秒後最終強化
                Timer(const Duration(seconds: 3), () {
                  if (mounted && _googleMapController != null) {
                    _force3DView(_googleMapController!);
                    log.info('平板 3D 建築最終強化完成 - 確保 3D 顯示');
                  }
                });

                // 平板設備 5 秒後檢查地圖加載狀態
                Timer(const Duration(seconds: 5), () {
                  _checkMapLoadingAndFallback();
                });
              } else {
                // 手機設備的標準邏輯
                Timer(const Duration(seconds: 3), () {
                  _checkMapLoadingAndFallback();
                });

                // 關鍵：立即且多次強制設置 3D 視角（所有模式都啟用 3D）
                // 第一次：500ms 後
                Timer(const Duration(milliseconds: 500), () {
                  if (mounted && controller != null) {
                    _force3DView(controller);
                  }
                });

                // 第二次：2 秒後
                Timer(const Duration(seconds: 2), () {
                  if (mounted && controller != null) {
                    _force3DView(controller);
                  }
                });
              }

              // 記錄攝影機位置變化
              controller.getVisibleRegion().then((bounds) {
                final center = GMaps.LatLng(
                  (bounds.northeast.latitude + bounds.southwest.latitude) / 2,
                  (bounds.northeast.longitude + bounds.southwest.longitude) / 2,
                );
                _currentCameraPosition = GMaps.CameraPosition(
                  target: center,
                  zoom: _currentCameraPosition?.zoom ?? 16.0,
                  tilt: _isSatelliteView ? 60.0 : 45.0,
                  bearing: 30.0,
                );
              });
            },
            onCameraMove: (GMaps.CameraPosition position) {
              // 即時更新攝影機位置，保持用戶瀏覽位置
              _currentCameraPosition = position;
            },
            // 最佳化的 3D 設定組合
            buildingsEnabled: true,
            // 啟用 3D 建築物
            tiltGesturesEnabled: true,
            rotateGesturesEnabled: true,
            zoomGesturesEnabled: true,
            scrollGesturesEnabled: true,
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            compassEnabled: true,
            mapToolbarEnabled: false,
            // 3D 效果優化
            indoorViewEnabled: true,
            // 室內 3D 效果
            trafficEnabled: false,
            // 避免干擾 3D 視覺
            liteModeEnabled: false,
            // 禁用簡化模式
            // 標記點（為平板調整尺寸）
            markers: {
              // 手機位置標記
              if (_phonePosition != null)
                GMaps.Marker(
                  markerId: const GMaps.MarkerId('phone_location'),
                  position: GMaps.LatLng(
                    _phonePosition!.latitude,
                    _phonePosition!.longitude,
                  ),
                  icon: GMaps.BitmapDescriptor.defaultMarkerWithHue(
                    GMaps.BitmapDescriptor.hueBlue,
                  ),
                  infoWindow: GMaps.InfoWindow(
                    title: '手機位置',
                    snippet: '您的當前位置 (${isTablet ? "平板" : "手機"}設備)',
                  ),
                ),
              // 無人機位置標記
              if (dronePosition != null)
                GMaps.Marker(
                  markerId: const GMaps.MarkerId('drone_location'),
                  position: GMaps.LatLng(
                    dronePosition!.latitude,
                    dronePosition!.longitude,
                  ),
                  icon: GMaps.BitmapDescriptor.defaultMarkerWithHue(
                    GMaps.BitmapDescriptor.hueRed,
                  ),
                  infoWindow: const GMaps.InfoWindow(
                    title: '無人機位置',
                    snippet: '無人機當前位置',
                  ),
                ),
            },
            // 地圖樣式（中文地名）
            onTap: (GMaps.LatLng position) {
              log.info(
                '點擊地圖位置: ${position.latitude}, ${position.longitude} - 設備: ${isTablet ? "平板" : "手機"}',
              );
            },
          ),
          // Google Maps API 金鑰提示覆蓋層（為平板優化位置）
          _buildApiKeyInfoOverlay(dialogSetState, isTablet),
        ],
      );
    } catch (e) {
      log.severe(
        'Google Maps 初始化失敗: $e（設備: ${MediaQuery.of(context).size.shortestSide >= 600 ? "平板" : "手機"}），切換到 FlutterMap',
      );
      return _buildFlutterMapFallback();
    }
  }

  Widget _buildApiKeyInfoOverlay([
    StateSetter? dialogSetState,
    bool isTablet = false,
  ]) {
    log.info(
      '試圖建立 API 金鑰覆蓋層，_showApiKeyOverlay = $_showApiKeyOverlay，設備類型: ${isTablet ? "平板" : "手機"}',
    );
    // 如果覆蓋層被關閉，則不顯示
    if (!_showApiKeyOverlay) {
      log.info('覆蓋層已關閉，返回空 widget');
      return const SizedBox.shrink();
    }

    log.info('顯示 API 金鑰覆蓋層');
    // 為平板調整位置和尺寸
    final overlayTop = isTablet ? 40.0 : 20.0;
    final overlayHorizontal = isTablet ? 40.0 : 20.0;

    return Positioned(
      top: overlayTop,
      left: overlayHorizontal,
      right: overlayHorizontal,
      child: Container(
        padding: EdgeInsets.all(isTablet ? 20 : 16),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.9),
          borderRadius: BorderRadius.circular(isTablet ? 16 : 12),
          border: Border.all(color: Colors.orange.shade700, width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: isTablet ? 12 : 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.red.shade800,
                  size: isTablet ? 28 : 24,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Google Maps 設定提示${isTablet ? " (平板模式)" : ""}',
                    style: TextStyle(
                      color: Colors.black87,
                      fontSize: isTablet ? 18 : 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    // 隐藏覆蓋層
                    log.info(
                      '點擊關閉按鈕，當前 _showApiKeyOverlay = $_showApiKeyOverlay',
                    );

                    // 使用主頁面的 setState 更新主狀態
                    setState(() {
                      _showApiKeyOverlay = false;
                    });

                    // 如果有 dialogSetState，也更新 Dialog 的狀態
                    if (dialogSetState != null) {
                      dialogSetState(() {
                        // 觸發 Dialog 內部重建
                      });
                    }

                    log.info(
                      '已設定 _showApiKeyOverlay = $_showApiKeyOverlay，關閉 API 金鑰提示覆蓋層',
                    );
                  },
                  child: Icon(
                    Icons.close,
                    color: Colors.white,
                    size: isTablet ? 24 : 20,
                  ),
                ),
              ],
            ),
            SizedBox(height: isTablet ? 16 : 12),
            Text(
              '如果地圖顯示空白，請檢查：',
              style: TextStyle(
                color: Colors.black87,
                fontSize: isTablet ? 16 : 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: isTablet ? 12 : 8),
            _buildInfoStep(
              '1. ',
              '在 AndroidManifest.xml 中設定有效的 Google Maps API 金鑰',
              isTablet,
            ),
            _buildInfoStep('2. ', '確保已啟用 "Maps SDK for Android" API', isTablet),
            _buildInfoStep('3. ', '網路連線正常', isTablet),
            if (isTablet) _buildInfoStep('4. ', '平板設備可能需要更長的地圖加載時間', isTablet),
            SizedBox(height: isTablet ? 16 : 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _showFlutterMapFallback();
                    },
                    icon: Icon(Icons.map, size: isTablet ? 22 : 18),
                    label: Text(
                      '使用備援地圖',
                      style: TextStyle(fontSize: isTablet ? 16 : 14),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade700,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(
                        vertical: isTablet ? 12 : 8,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 5),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      _showApiKeyOverlay = false;
                    },
                    label: Text(
                      '知道了',
                      style: TextStyle(fontSize: isTablet ? 16 : 14),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade700,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(
                        vertical: isTablet ? 12 : 8,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoStep(String number, String text, [bool isTablet = false]) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            number,
            style: TextStyle(
              color: Colors.red.shade800,
              fontSize: isTablet ? 15 : 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: Colors.black87,
                fontSize: isTablet ? 15 : 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _checkMapLoadingAndFallback() {
    // 這個方法檢查 Google Maps 是否正確加載
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.shortestSide >= 600;

    log.warning(
      '檢查 Google Maps 加載狀態 - 設備: ${isTablet ? "平板" : "手機"}, 螢幕尺寸: ${screenSize.width}x${screenSize.height}',
    );

    // 平板特殊處理：如果是平板且 Google Maps 無法正常顯示，切換到備援模式
    if (isTablet && !_showApiKeyOverlay) {
      log.info('平板設備檢測到可能的地圖加載問題，準備備援方案');
      // 平板上更容易出現 Google Maps 加載問題，提供更好的用戶提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('平板設備檢測到地圖加載問題，建議使用備援地圖模式'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: '使用備援地圖',
              onPressed: () {
                Navigator.of(context).pop();
                _showFlutterMapFallback();
              },
            ),
          ),
        );
      }
    }

    // 如果 API 金鑰無效，Google Maps 會顯示空白但控制器仍會初始化
    log.warning('如果為空白則可能需要有效的 API 金鑰');
  }

  // 決定最佳地圖類型的方法（3D模式永久啟用）
  GMaps.MapType _determineOptimalMapType() {
    if (_isSatelliteView) {
      // 衛星模式：使用 hybrid 以獲得 3D 衛星效果
      log.info('使用 hybrid 地圖類型以支援 3D 衛星模式');
      return GMaps.MapType.hybrid;
    } else {
      // 標準模式：使用 normal 但啟用 3D 建築
      return GMaps.MapType.normal;
    }
  }

  // 決定地圖中心位置的方法
  GMaps.LatLng _determineMapCenter() {
    GMaps.LatLng mapCenter;
    if (_usePhoneAsMapCenter) {
      mapCenter =
          _phonePosition != null
              ? GMaps.LatLng(
                _phonePosition!.latitude,
                _phonePosition!.longitude,
              )
              : (dronePosition != null
                  ? GMaps.LatLng(
                    dronePosition!.latitude,
                    dronePosition!.longitude,
                  )
                  : const GMaps.LatLng(25.0330, 121.5654)); // 台北101附近
      log.info(
        'Google Maps 地圖中心設為手機位置: ${_phonePosition?.latitude}, ${_phonePosition?.longitude}',
      );
    } else {
      mapCenter =
          dronePosition != null
              ? GMaps.LatLng(dronePosition!.latitude, dronePosition!.longitude)
              : (_phonePosition != null
                  ? GMaps.LatLng(
                    _phonePosition!.latitude,
                    _phonePosition!.longitude,
                  )
                  : const GMaps.LatLng(25.0330, 121.5654)); // 台北101附近
      log.info(
        'Google Maps 地圖中心設為無人機位置: ${dronePosition?.latitude}, ${dronePosition?.longitude}',
      );
    }
    return mapCenter;
  }

  // 強制設置 3D 視角的方法（所有模式都使用 3D）
  void _force3DView(GMaps.GoogleMapController controller) {
    final target = GMaps.LatLng(
      _currentCameraPosition?.target.latitude ?? 25.0330, // 台北101
      _currentCameraPosition?.target.longitude ?? 121.5654,
    );

    // 為所有模式設置 3D 參數，平板使用更高的縮放以確保 3D 建築顯示
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.shortestSide >= 600;
    final zoomLevel =
        isTablet ? 18.0 : (_currentCameraPosition?.zoom ?? 16.0); // 平板使用更高縮放
    final tiltAngle =
        _isSatelliteView ? 70.0 : (isTablet ? 60.0 : 45.0); // 平板使用更大傾斜

    controller.animateCamera(
      GMaps.CameraUpdate.newCameraPosition(
        GMaps.CameraPosition(
          target: target,
          zoom: zoomLevel,
          tilt: tiltAngle,
          bearing: 45.0, // 平板使用更好的旋轉角度
        ),
      ),
    );

    log.info(
      '設置 3D 視角 - 縮放: $zoomLevel, 傾斜: $tiltAngle°, 模式: ${_isSatelliteView ? "衛星" : "標準"}, 設備: ${isTablet ? "平板" : "手機"}',
    );

    // 更新當前攝影機位置
    _currentCameraPosition = GMaps.CameraPosition(
      target: target,
      zoom: zoomLevel,
      tilt: tiltAngle,
      bearing: 45.0,
    );
  }

  //flutter 援備地圖
  Widget _buildFlutterMapFallback() {
    log.info('使用 FlutterMap 作為地圖備援');
    // 根據設置決定地圖中心位置
    latLng.LatLng mapCenter;
    if (_usePhoneAsMapCenter) {
      mapCenter =
          _phonePosition ??
          dronePosition ??
          const latLng.LatLng(23.016725, 120.232065);
      log.info(
        '地圖中心設為手機位置: ${_phonePosition?.latitude}, ${_phonePosition?.longitude}',
      );
    } else {
      mapCenter =
          dronePosition ??
          _phonePosition ??
          const latLng.LatLng(23.016725, 120.232065);
      log.info(
        '地圖中心設為無人機位置: ${dronePosition?.latitude}, ${dronePosition?.longitude}',
      );
    }
    return FMap.FlutterMap(
      options: FMap.MapOptions(
        initialCenter: mapCenter,
        initialZoom: 16,
        interactionOptions: const FMap.InteractionOptions(
          flags: FMap.InteractiveFlag.all,
        ),
      ),
      children: [
        FMap.TileLayer(
          urlTemplate:
              _isSatelliteView
                  ? 'https://mt{s}.google.com/vt/lyrs=s&x={x}&y={y}&z={z}&hl=zh-TW' // 衛星視圖
                  : 'https://mt{s}.google.com/vt/lyrs=m&x={x}&y={y}&z={z}&hl=zh-TW',
          // 標準地圖
          subdomains: const ['0', '1', '2', '3'],
          userAgentPackageName: 'com.example.drone_app',
        ),
        if (dronePosition != null || _phonePosition != null)
          FMap.MarkerLayer(
            markers: [
              // 手機位置標記
              if (_phonePosition != null)
                FMap.Marker(
                  point: _phonePosition!,
                  width: 40,
                  height: 40,
                  child: const Icon(
                    Icons.phone_android,
                    color: Colors.blue,
                    size: 35,
                  ),
                ),
              // 無人機位置標記
              if (dronePosition != null)
                FMap.Marker(
                  point: dronePosition!,
                  width: 45,
                  height: 45,
                  child: const Icon(
                    Icons.airplanemode_active,
                    color: Colors.red,
                    size: 40,
                  ),
                ),
            ],
          ),
      ],
    );
  }

  void _showFlutterMapFallback() {
    log.info('顯示 FlutterMap 備援全螢幕地圖');
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return Dialog.fullscreen(
          child: Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              title: const Text(
                '無人機地圖 (備援模式)',
                style: TextStyle(color: Colors.white),
              ),
              backgroundColor: Colors.black.withOpacity(0.8),
              iconTheme: const IconThemeData(color: Colors.white),
              actions: [
                IconButton(
                  icon: Icon(
                    _isSatelliteView ? Icons.map : Icons.satellite,
                    color: _isSatelliteView ? Colors.orange : Colors.white,
                  ),
                  onPressed: () {
                    setState(() {
                      _isSatelliteView = !_isSatelliteView;
                    });
                    Navigator.of(context).pop();
                    _showFlutterMapFallback();
                  },
                  tooltip: '切換地圖類型',
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '關閉',
                ),
              ],
            ),
            body: _buildFlutterMapFallback(),
          ),
        );
      },
    );
  }

  void _updateServoAngle(double newAngle) {
    _debounceTimer?.cancel();
    // Increase debounce time to reduce jitter
    _debounceTimer = Timer(const Duration(milliseconds: 50), () {
      final clampedAngle = newAngle.clamp(-45.0, 90.0);
      setState(() {
        _servoAngle = double.parse(
          clampedAngle.toStringAsFixed(1),
        ); // Reduce precision to avoid jitter
      });
      if (isWebSocketConnected) {
        log.info('【伺服指令】即將送出角度: ${_servoAngle!.toStringAsFixed(1)}°');
        _controller.sendServoAngle(_servoAngle!);
        log.info('【伺服指令】已送出角度: ${_servoAngle!.toStringAsFixed(1)}°');
      } else {
        log.warning('WebSocket未連線，伺服指令未發送');
      }
    });
  }

  void _incrementServoAngle() {
    final newAngle = (_servoAngle ?? 0.0) + 5.0;
    _updateServoAngle(newAngle);
    log.info('按鈕控制：伺服角度增加至 ${newAngle.toStringAsFixed(2)}°');
  }

  void _decrementServoAngle() {
    final newAngle = (_servoAngle ?? 0.0) - 5.0;
    _updateServoAngle(newAngle);
    log.info('按鈕控制：伺服角度減少至 ${newAngle.toStringAsFixed(2)}°');
  }

  void _toggleLed() {
    if (isWebSocketConnected) {
      _controller.sendLedCommand(
        jsonEncode({
          'type': 'led_control',
          'action': _ledEnabled ? 'LED_OFF' : 'LED_ON',
        }),
      );
      log.info('發送 LED 切換指令');
    } else {
      log.warning('WebSocket未連線，LED指令未發送');
    }
  }

  void _connectToStream() async {
    if (_socket != null) return;
    setState(() {
      isStreamLoaded = true;
      isCameraConnected = false;
    });
    int retries = 0;
    const maxRetries = 5;
    while (retries < maxRetries && mounted) {
      try {
        _socket = await Socket.connect(
          AppConfig.droneIP,
          AppConfig.videoPort,
          timeout: const Duration(seconds: 15),
        );
        log.info('成功連接到視訊串流：${AppConfig.droneIP}:${AppConfig.videoPort}');
        _socketSubscription = _socket!.listen(
          (data) {
            try {
              _buffer.addAll(data);
              int start, end;
              while ((start = _findJpegStart(_buffer)) != -1 &&
                  (end = _findJpegEnd(_buffer, start)) != -1) {
                final frame = _buffer.sublist(start, end + 2);
                _buffer = _buffer.sublist(end + 2);
                setState(() {
                  _currentFrame = Uint8List.fromList(frame);
                  isCameraConnected = true;
                });
              }
              if (_buffer.length > 500000) {
                _buffer = _buffer.sublist(_buffer.length - 250000);
                log.warning('緩衝區過大，已裁剪至 ${_buffer.length} 位元組');
              }
            } catch (e) {
              log.severe('處理串流數據時出錯：$e');
            }
          },
          onError: (error) {
            log.severe('串流錯誤：$error');
            setState(() {
              isCameraConnected = false;
              isStreamLoaded = false;
            });
            _disconnectFromStream();
            _scheduleStreamReconnect();
          },
          onDone: () {
            log.warning('串流已關閉');
            setState(() {
              isCameraConnected = false;
              isStreamLoaded = false;
            });
            _disconnectFromStream();
            _scheduleStreamReconnect();
          },
        );
        return;
      } catch (e) {
        retries++;
        log.severe('連線失敗（嘗試 $retries/$maxRetries）：$e');
        if (retries < maxRetries) {
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }
    setState(() {
      isCameraConnected = false;
      isStreamLoaded = false;
    });
    log.severe('視訊串流連線失敗，已達到最大重試次數');
  }

  void _disconnectFromStream() {
    _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket?.close();
    _socket = null;
    setState(() {
      isCameraConnected = false;
      isStreamLoaded = false;
    });
    log.info('已斷開視訊串流連線');
  }

  void _scheduleStreamReconnect() {
    Timer(const Duration(seconds: 2), () {
      if (mounted && !isStreamLoaded) {
        log.info('嘗試重新連線到視訊串流...');
        _connectToStream();
      }
    });
  }

  int _findJpegStart(List<int> buffer) {
    for (int i = 0; i < buffer.length - 1; i++) {
      if (buffer[i] == 0xFF && buffer[i + 1] == 0xD8) {
        return i;
      }
    }
    return -1;
  }

  int _findJpegEnd(List<int> buffer, int start) {
    for (int i = start; i < buffer.length - 1; i++) {
      if (buffer[i] == 0xFF && buffer[i + 1] == 0xD9) {
        return i;
      }
    }
    return -1;
  }

  void _changeUIMode(String newMode, StateSetter innerState) {
    innerState((){
      selectedMode = newMode;
    });
    setState(() {
      selectedMode = newMode;
    });
    log.info('UI模式已切換至：$newMode');
  }

  bool _shouldShowControls() {
    return selectedMode == '顯示加控制' || selectedMode == '協同作業';
  }

  bool _shouldShowServoControls() {
    return selectedMode == '顯示加控制' || selectedMode == '僅顯示';
  }

  void _showMenuDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext dialogContext) {
        String selectedMenu = '設定';
        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 400,
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(dialogContext).size.height * 0.95,
              ),
              margin: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.5),
                borderRadius: const BorderRadius.all(Radius.circular(20)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: 10,
                    offset: const Offset(-5, 0),
                  ),
                ],
              ),
              child: StatefulBuilder(
                builder: (
                  BuildContext innerContext,
                  StateSetter innerSetState,
                ) {
                  return Stack(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height: 75,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16.0,
                                vertical: 8.0,
                              ),
                              children: [
                                _MenuItem(
                                  icon: Icons.settings,
                                  title: '設定',
                                  isSelected: selectedMenu == '設定',
                                  onTap: () {
                                    innerSetState(() {
                                      selectedMenu = '設定';
                                    });
                                  },
                                ),
                                _MenuItem(
                                  icon: Icons.info,
                                  title: '資訊',
                                  isSelected: selectedMenu == '資訊',
                                  onTap: () {
                                    innerSetState(() {
                                      selectedMenu = '資訊';
                                    });
                                  },
                                ),
                                _MenuItem(
                                  icon: Icons.help,
                                  title: '幫助',
                                  isSelected: selectedMenu == '幫助',
                                  onTap: () {
                                    innerSetState(() {
                                      selectedMenu = '幫助';
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                          Container(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                            ),
                            height: 1.0,
                            color: Colors.white.withOpacity(0.3),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(12.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (selectedMenu == '設定')
                                    ..._buildSettingsUI(
                                      innerContext,
                                      selectedMode,
                                      innerSetState,
                                    ),
                                  if (selectedMenu == '資訊')
                                    ..._buildInfoUI(innerContext),
                                  if (selectedMenu == '幫助')
                                    ..._buildHelpUI(innerContext),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: IconButton(
                          icon: const Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 20,
                          ),
                          onPressed: () {
                            Navigator.of(innerContext).pop();
                          },
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black.withOpacity(0.3),
                            shape: const CircleBorder(),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _MenuItem({
    required IconData icon,
    required String title,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashColor: Colors.white.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: isSelected ? Colors.white : Colors.white70,
                size: 28,
              ),
              const SizedBox(height: 4),
              Text(
                title,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white70,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                ),
              ),
              if (isSelected)
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  height: 2,
                  width: 20,
                  color: Colors.white,
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSettingsUI(
    BuildContext context,
    final String selectedMode,
    StateSetter innerSetState,
  ) {
    return [
      const Text(
        '設定',
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 8),
      ListTile(
        leading: const Icon(Icons.adjust, color: Colors.white),
        title: const Text('手電筒', style: TextStyle(color: Colors.white)),
        trailing: _buildLedButton(),
      ),
      ListTile(
        leading: const Icon(Icons.waving_hand, color: Colors.white),
        title: const Text('手勢辨識', style: TextStyle(color: Colors.white)),
        trailing: Switch(
          value: _gestureRecognitionEnabled,
          activeColor: Colors.green,
          onChanged: (bool value) {
            innerSetState(() {
              _gestureRecognitionEnabled = value;
            });
            setState(() {
              _gestureRecognitionEnabled = value;
            });
          },
        ),
      ),
      ListTile(
        leading: const Icon(Icons.photo_camera, color: Colors.white),
        title: const Text('AI 辨識', style: TextStyle(color: Colors.white)),
        trailing: Switch(
          value: _aiRecognitionEnabled,
          activeColor: Colors.green,
          onChanged: (bool value) {
            innerSetState(() {
              _aiRecognitionEnabled = value;
            });
            setState(() {
              _aiRecognitionEnabled = value;
            });
          },
        ),
      ),
      ListTile(
        leading: const Icon(Icons.photo_camera, color: Colors.white),
        title: const Text('AI 搜救', style: TextStyle(color: Colors.white)),
        trailing: Switch(
          value: _aiRescueEnabled,
          activeColor: Colors.green,
          onChanged: (bool value) {
            innerSetState(() {
              _aiRescueEnabled = value;
            });
            setState(() {
              _aiRescueEnabled = value;
            });
          },
        ),
      ),
      ListTile(
        leading: const Icon(Icons.settings, color: Colors.white),
        title: Text(
          '伺服控制方式: ${_useSliderControl ? '滑桿' : '按鈕'}',
          style: const TextStyle(color: Colors.white),
        ),
        trailing: Switch(
          value: _useSliderControl,
          activeColor: Colors.green,
          onChanged: (bool value) {
            innerSetState(() {
              _useSliderControl = value;
            });
            setState(() {
              _useSliderControl = value;
              log.info('伺服控制方式切換為: ${_useSliderControl ? '滑桿' : '按鈕'}');
            });
          },
        ),
      ),
      ListTile(
        leading: const Icon(Icons.map, color: Colors.white),
        title: const Text('地圖中心顯示', style: TextStyle(color: Colors.white)),
        subtitle: Text(
          _usePhoneAsMapCenter ? '以手機位置為中心' : '以無人機位置為中心',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        trailing: Switch(
          value: _usePhoneAsMapCenter,
          activeColor: Colors.green,
          onChanged: (bool value) {
            innerSetState(() {
              _usePhoneAsMapCenter = value;
            });
            setState(() {
              _usePhoneAsMapCenter = value;
              log.info('地圖中心顯示切換為: ${_usePhoneAsMapCenter ? '手機位置' : '無人機位置'}');
            });
          },
        ),
      ),
      ListTile(
        leading: const Icon(Icons.photo_camera, color: Colors.white),
        title: const Text('拍照輔助線', style: TextStyle(color: Colors.white)),
        trailing: Switch(
          value: _auxiliaryLine,
          activeColor: Colors.green,
          onChanged: (bool value) {
            innerSetState(() {
              _auxiliaryLine = value;
            });
            setState(() {
              _auxiliaryLine = value;
            });
          },
        ),
      ),
      const Text(
        '模式選擇',
        style: TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Wrap(
            spacing: 8.0,
            children: [
              _ModeOption(
                label: '顯示加控制',
                isSelected: selectedMode == '顯示加控制',
                onTap: () => _changeUIMode('顯示加控制',innerSetState),
              ),
              _ModeOption(
                label: '僅顯示',
                isSelected: selectedMode == '僅顯示',
                onTap: () => _changeUIMode('僅顯示',innerSetState),
              ),
              _ModeOption(
                label: '協同作業',
                isSelected: selectedMode == '協同作業',
                onTap: () => _changeUIMode('協同作業',innerSetState),
              ),
            ],
          ),
        ],
      ),
      const SizedBox(height: 16),
      TextField(
        decoration: const InputDecoration(
          labelText: 'Drone IP',
          labelStyle: TextStyle(color: Colors.white),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.white),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.blue),
          ),
        ),
        style: const TextStyle(color: Colors.white),
        controller: TextEditingController(text: droneIP),
        onChanged: (value) {
          innerSetState(() {
            droneIP = value;
          });
          setState(() {
            droneIP = value;
            AppConfig.droneIP = value;
          });
          _controller.disconnect();
          _controller.connect();
          _disconnectFromStream();
          _connectToStream();
        },
      ),
    ];
  }

  List<Widget> _buildInfoUI(BuildContext dialogContext) {
    return [
      const Text(
        '應用資訊',
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 8),
      const ListTile(
        leading: Icon(Icons.info_outline, color: Colors.white),
        title: Text('版本號: 2.4.6.8', style: TextStyle(color: Colors.white)),
      ),
      const ListTile(
        leading: Icon(Icons.person, color: Colors.white),
        title: Text('開發者: drone Team', style: TextStyle(color: Colors.white)),
      ),
      ListTile(
        leading: const Icon(Icons.email, color: Colors.white),
        title: const Text('聯繫我們', style: TextStyle(color: Colors.white)),
        onTap: () {
          showDialog(
            context: dialogContext,
            builder:
                (context) => AlertDialog(
                  title: const Text('聯繫我們'),
                  content: const Text('請發送郵件至: jerrysh0227@gmail.com'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('關閉'),
                    ),
                  ],
                ),
          );
        },
      ),
    ];
  }

  List<Widget> _buildHelpUI(BuildContext dialogContext) {
    return [
      const Text(
        '幫助與支援',
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 8),
      const ListTile(
        leading: Icon(Icons.book, color: Colors.white),
        title: Text('使用手冊', style: TextStyle(color: Colors.white)),
      ),
      ListTile(
        leading: const Icon(Icons.question_answer, color: Colors.white),
        title: const Text('常見問題', style: TextStyle(color: Colors.white)),
        onTap: () {
          showDialog(
            context: dialogContext,
            builder:
                (context) => AlertDialog(
                  title: const Text('常見問題'),
                  content: const Text('Q: 如何連線無人機?\nA: 請確保分享開啟且IP位址正確。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('關閉'),
                    ),
                  ],
                ),
          );
        },
      ),
      const ListTile(
        leading: Icon(Icons.support, color: Colors.white),
        title: Text('技術支援', style: TextStyle(color: Colors.white)),
      ),
    ];
  }

  Widget _buildTopStatusBar() {
    return Positioned(
      top: 0,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        // decoration: BoxDecoration(
        //   color: Colors.black.withOpacity(0.6),
        //   borderRadius: BorderRadius.circular(16),
        // ),
        child: Row(
          children: [
            IconButton(
              onPressed: () async {
                await SystemChrome.setPreferredOrientations([
                  DeviceOrientation.portraitUp,
                ]);
                if (mounted) {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (context) => const Home()),
                    (route) => false,
                  );
                  log.info('已跳轉到 Home 頁面');
                }
              },
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
            _buildConnectionButton(
              icon:
                  isWebSocketConnected
                      ? Icons.wifi_rounded
                      : Icons.wifi_off_rounded,
              isConnected: isWebSocketConnected,
              onPressed: () {
                if (!isWebSocketConnected) _controller.connect();
              },
              tooltip: 'WebSocket連線',
            ),
            const SizedBox(width: 8),
            _buildConnectionButton(
              icon:
                  isCameraConnected
                      ? Icons.videocam_rounded
                      : Icons.videocam_off_rounded,
              isConnected: isCameraConnected,
              onPressed: () {
                if (isStreamLoaded)
                  _disconnectFromStream();
                else
                  _connectToStream();
              },
              tooltip: '視訊串流',
            ),
            const SizedBox(width: 8),
            const Spacer(),
            Text(
              '伺服: ${_servoAngle?.toStringAsFixed(1) ?? 0.0}°',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _showMenuDialog,
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

  Widget _buildConnectionButton({
    required IconData icon,
    required bool isConnected,
    required VoidCallback onPressed,
    required String tooltip,
  }) {
    Color activeColor = Colors.greenAccent.shade700;
    Color inactiveColor = Colors.redAccent.shade400;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color:
                  isConnected
                      ? activeColor.withOpacity(0.25)
                      : inactiveColor.withOpacity(0.25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color:
                    isConnected
                        ? activeColor.withOpacity(0.5)
                        : inactiveColor.withOpacity(0.5),
                width: 1.5,
              ),
            ),
            child: AnimatedBuilder(
              animation: _pulseController,
              builder:
                  (context, child) => Transform.scale(
                    scale: isConnected ? _pulseAnimation.value : 1.0,
                    child: Icon(
                      icon,
                      color: isConnected ? activeColor : inactiveColor,
                      size: 22,
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLedButton() {
    return _buildConnectionButton(
      icon: _ledEnabled ? Icons.lightbulb : Icons.lightbulb_outline,
      isConnected: _ledEnabled,
      onPressed: _toggleLed,
      tooltip: 'LED控制',
    );
  }

  Widget _buildServoSlider1() {
    if (_useSliderControl) {
      return Positioned(
        left: 20,
        top: 110,
        child: Container(
          height: 250,
          width: 80,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.6),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.4),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 16.0),
                child: Text(
                  '雲台\n角度',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    height: 1.2,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: GestureDetector(
                  onVerticalDragStart: (details) {
                    setState(() {
                      _isDraggingServo = true;
                      log.info('開始拖拽伺服控制（滑桿）');
                    });
                  },
                  onVerticalDragUpdate: (details) {
                    final double maxDragDistance = 150.0;
                    final double dragPosition = details.localPosition.dy;
                    final double normalizedPosition =
                        1 - (dragPosition / maxDragDistance);
                    final double newAngle = (normalizedPosition * 135 - 45)
                        .clamp(-45.0, 90.0);
                    _updateServoAngle(newAngle);
                  },
                  onVerticalDragEnd: (details) {
                    setState(() {
                      _isDraggingServo = false;
                      log.info('結束拖拽伺服控制（滑桿）');
                    });
                  },
                  child: Container(
                    alignment: Alignment.center,
                    child: CustomPaint(
                      size: const Size(80, 200),
                      painter: ServoTrackPainter(
                        servoAngle: _servoAngle ?? 0.0,
                        isDragging: _isDraggingServo,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '角度: ${_servoAngle?.toStringAsFixed(1) ?? 0.0}°',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      // Touch-to-appear servo control
      return Stack(
        children: [
          // Invisible gesture detector covering the entire screen
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (details) {
                if (!isWebSocketConnected) return;
                setState(() {
                  _isDraggingServo = true;
                });
                log.info('開始拖拽伺服控制');
              },
              onPanUpdate: (details) {
                if (!isWebSocketConnected || !_isDraggingServo) return;
                setState(() {
                  double sensitivity = 0.5;
                  _servoAngle =
                      (_servoAngle ?? 0.0) - details.delta.dy * sensitivity;
                  _servoAngle = _servoAngle!.clamp(-45.0, 90.0);
                });
                _updateServoAngle(_servoAngle!);
              },
              onPanEnd: (details) {
                setState(() {
                  _isDraggingServo = false;
                });
                log.info('結束拖拽伺服控制');
              },
              onTap: () {
                if (!isWebSocketConnected) return;
                setState(() {
                  _servoAngle = 0.0;
                });
                _updateServoAngle(0.0);
                log.info('伺服角度歸零');
              },
            ),
          ),
          // Servo control interface - only show when dragging
          if (_isDraggingServo)
            Center(
              child: AnimatedOpacity(
                opacity: _isDraggingServo ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.blue.withOpacity(0.7),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.5),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.keyboard_arrow_up,
                            color: Colors.white,
                            size: 20,
                          ),
                          Text(
                            '向上',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 20),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '雲台角度',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            '${_servoAngle?.toStringAsFixed(1)}°',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 20),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.keyboard_arrow_down,
                            color: Colors.white,
                            size: 20,
                          ),
                          Text(
                            '向下',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    }
  }

  // 應用死區處理（減少死區以提高靈敏度）
  double _applyDeadzone(double value, {double deadzone = 0.03}) {
    if (value.abs() < deadzone) return 0.0;
    final sign = value.isNegative ? -1.0 : 1.0;
    final magnitude = ((value.abs() - deadzone) / (1.0 - deadzone)).clamp(
      0.0,
      1.0,
    );
    return sign * magnitude;
  }

  // 特別的油門死區處理（減少死區以提高靈敏度）
  double _applyThrottleDeadzone(double value) {
    const throttleDeadzone = 0.04; // 減少油門死區以提高靈敏度
    if (value.abs() < throttleDeadzone) return 0.0;
    final sign = value.isNegative ? -1.0 : 1.0;
    final magnitude = ((value.abs() - throttleDeadzone) /
            (1.0 - throttleDeadzone))
        .clamp(0.0, 1.0);
    return sign * magnitude;
  }

  // 應用指數曲線增強精確控制（減少指數效應以提高靈敏度）
  double _applyExpo(double value, {double expo = 0.15}) {
    return value * (1.0 - expo) + (value * value * value) * expo;
  }

  // 線性插值平滑處理（減少平滑以降低延遲）
  double _lerp(double current, double target, double smoothing) {
    return current + (target - current) * smoothing;
  }

  void _updateControlValues(JoystickMode mode, double x, double y) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 20), () {
      setState(() {
        if (mode == JoystickMode.all) {
          throttle = -y; // 油門：Y軸反向
          yaw = x; // 偏航：X軸
        } else {
          forward = -y; // 前進：Y軸反向
          lateral = x; // 橫移：X軸
        }
        if (isWebSocketConnected) {
          _controller.startContinuousControl(throttle, yaw, forward, lateral);
        } else {
          _controller.stopContinuousControl();
        }
      });
    });
  }

  Widget _buildBottomControlArea() {
    return Positioned(
      bottom: 16,
      left: 110,
      right: 100,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildJoystickWithLabel(
            label: "",
            mode: JoystickMode.all,
            onUpdate: (x, y) => _updateControlValues(JoystickMode.all, x, y),
            onEnd: () {
              setState(() {
                throttle = yaw = 0;
                if (isWebSocketConnected) {
                  _controller.startContinuousControl(0, 0, forward, lateral);
                }
              });
            },
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildActionButton(
                    Icons.flight_takeoff_rounded,
                    '啟動',
                    isWebSocketConnected
                        ? Colors.greenAccent.shade700
                        : Colors.grey.shade700,
                    isWebSocketConnected
                        ? () {
                          // 使用舊版本簡潔的 ARM 邏輯
                          _controller.sendCommand('ARM');
                        }
                        : null,
                  ),
                  const SizedBox(width: 10),
                  _buildActionButton(
                    Icons.flight_land_rounded,
                    '解除',
                    isWebSocketConnected
                        ? Colors.redAccent.shade400
                        : Colors.grey.shade700,
                    isWebSocketConnected
                        ? () {
                          // 使用舊版本簡潔的 DISARM 邏輯
                          _controller.sendCommand('DISARM');
                        }
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 80),
            ],
          ),
          _buildJoystickWithLabel(
            label: "",
            mode: JoystickMode.all,
            onUpdate:
                (x, y) => _updateControlValues(
                  JoystickMode.horizontalAndVertical,
                  x,
                  y,
                ),
            onEnd: () {
              setState(() {
                forward = lateral = 0;
                if (isWebSocketConnected) {
                  _controller.startContinuousControl(throttle, yaw, 0, 0);
                }
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildJoystickWithLabel({
    required String label,
    required JoystickMode mode,
    required void Function(double, double) onUpdate,
    required VoidCallback onEnd,
  }) {
    double xValue = (label == '') ? yaw : lateral;
    double yValue = (label == '') ? throttle : forward;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 160,
          height: 160,
          // decoration: BoxDecoration(
          //   color: Colors.black.withOpacity(0.5),
          //   borderRadius: BorderRadius.circular(80),
          //   boxShadow: [
          //     BoxShadow(
          //       color: Colors.black.withOpacity(0.3),
          //       blurRadius: 8,
          //       offset: const Offset(0, 3),
          //     ),
          //   ],
          // ),
          child: Joystick(
            stick: AnimatedJoystickStick(x: xValue, y: yValue),
            base: JoystickBase(mode: mode),
            listener: (details) => onUpdate(details.x, details.y),
            onStickDragEnd: onEnd,
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton(
    IconData icon,
    String label,
    Color color,
    VoidCallback? onTap,
  ) {
    bool isDisabled = onTap == null;
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: isDisabled ? Colors.grey.shade800 : color,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        elevation: 4,
        shadowColor: Colors.black.withOpacity(0.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22),
          const SizedBox(height: 5),
          Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  void _showRecordingOptionsDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.3),
      builder: (BuildContext dialogContext) {
        return const RecordingOptionsDialog();
      },
    );
  }

  void startRecording() {
    setState(() {
      isRecording = true;
    });
    log.info('開始錄影');
  }

  void stopRecording() {
    setState(() {
      isRecording = false;
    });
    log.info('停止錄影');
  }

  void takePhoto() async {
    try {
      final uri = Uri.parse('http://${AppConfig.droneIP}:8770/photo');
      final res = await http.post(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        log.info('拍照成功');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已拍照')));
      } else {
        log.severe('拍照失敗: ${res.body}');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('拍照失敗: ${res.statusCode}')));
      }
    } catch (e) {
      log.severe('拍照錯誤: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('拍照錯誤: $e')));
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controlDebounceTimer?.cancel();
    _anglePollTimer?.cancel();
    _locationUpdateTimer?.cancel(); // 清理位置更新計時器
    _pulseController.dispose();
    _fullScreenController.dispose();
    _controller.dispose();
    _disconnectFromStream();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              onTap: _toggleFullScreen,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                decoration: BoxDecoration(
                  color: Colors.black,
                  boxShadow:
                      isFullScreen
                          ? [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.8),
                              blurRadius: 20,
                            ),
                          ]
                          : null,
                ),
                child: AnimatedBuilder(
                  animation: _fullScreenAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: 1.0 + _fullScreenAnimation.value * 0.1,
                      child:
                          _currentFrame != null
                              ? Transform.rotate(
                                angle: math.pi,
                                child: Image.memory(
                                  _currentFrame!,
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                  errorBuilder:
                                      (context, error, stackTrace) => Container(
                                        color: Colors.black,
                                        child: const Center(
                                          child: Text(
                                            '影像解碼錯誤',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                            ),
                                          ),
                                        ),
                                      ),
                                ),
                              )
                              : child,
                    );
                  },
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedBuilder(
                          animation: _pulseAnimation,
                          builder: (context, child) {
                            return Transform.scale(
                              scale: _pulseAnimation.value,
                              child: const CircularProgressIndicator(
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                                strokeWidth: 3,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Container(color: Colors.black.withOpacity(0.1)),
            if (_shouldShowServoControls()) _buildServoSlider1(),

            _buildTopStatusBar(),
            if(_auxiliaryLine)
              Positioned.fill(
                child: IgnorePointer(child: CustomPaint(painter: _GridPainter())),
              ),
            if (_shouldShowControls()) _buildBottomControlArea(),
            Positioned(
              left: 20,
              bottom: MediaQuery.of(context).size.height * 0.55,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.5),
                    width: 2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      width: 150,
                      height: 100,
                      child: Stack(
                        children: [
                          FMap.FlutterMap(
                            mapController: _miniMapController,
                            options: FMap.MapOptions(
                              initialCenter:
                                  dronePosition ??
                                  _phonePosition ??
                                  const latLng.LatLng(23.016725, 120.232065),
                              initialZoom: 18,
                              interactionOptions: const FMap.InteractionOptions(
                                flags:
                                    FMap.InteractiveFlag.drag |
                                    FMap.InteractiveFlag.pinchZoom, // 允許拖拽和縮放
                              ),
                            ),
                            children: [
                              FMap.TileLayer(
                                // 根據視圖類型選擇不同的地圖服務
                                urlTemplate:
                                    _isSatelliteView
                                        ? 'https://mt{s}.google.com/vt/lyrs=s&x={x}&y={y}&z={z}&hl=zh-TW' // 衛星視圖
                                        : 'https://mt{s}.google.com/vt/lyrs=m&x={x}&y={y}&z={z}&hl=zh-TW',
                                // 標準地圖
                                subdomains: const ['0', '1', '2', '3'],
                                userAgentPackageName: 'com.example.drone_app',
                                additionalOptions: const {
                                  'User-Agent': 'drone_app/1.0.0',
                                },
                                // 備用中文地圖服務
                                fallbackUrl:
                                    'https://api.mapbox.com/styles/v1/mapbox/streets-v11/tiles/{z}/{x}/{y}?access_token=pk.eyJ1IjoibWFwYm94IiwiYSI6ImNpejY4NXVycTA2emYycXBndHRqcmZ3N3gifQ.rJcFIG214AriISLbB6B5aw&language=zh',
                              ),
                              if (dronePosition != null ||
                                  _phonePosition != null)
                                FMap.MarkerLayer(
                                  markers: [
                                    // 手機位置標記
                                    if (_phonePosition != null)
                                      FMap.Marker(
                                        point: _phonePosition!,
                                        width: 25,
                                        height: 25,
                                        child: const Icon(
                                          Icons.phone_android,
                                          color: Colors.blue,
                                          size: 20,
                                        ),
                                      ),
                                    // 無人機位置標記
                                    if (dronePosition != null)
                                      FMap.Marker(
                                        point: dronePosition!,
                                        width: 30,
                                        height: 30,
                                        child: const Icon(
                                          Icons.airplanemode_active,
                                          color: Colors.red,
                                          size: 25,
                                        ),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                          // 添加衛星視圖切換按鈕
                          Positioned(
                            top: 5,
                            left: 5,
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _isSatelliteView = !_isSatelliteView;
                                });
                                log.info(
                                  '小地圖視圖切換為: ${_isSatelliteView ? "衛星視圖" : "標準地圖"}',
                                );
                              },
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.6),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  _isSatelliteView
                                      ? Icons.map
                                      : Icons.satellite,
                                  color:
                                      _isSatelliteView
                                          ? Colors.orange
                                          : Colors.white,
                                  size: 16,
                                ),
                              ),
                            ),
                          ),
                          // 添加地圖中心切換按鈕
                          Positioned(
                            top: 5,
                            right: 35,
                            child: GestureDetector(
                              onTap: () {
                                // 回到目前模式中心（不切換圖示與模式）
                                final latLng.LatLng? target =
                                    _usePhoneAsMapCenter
                                        ? (_phonePosition ?? dronePosition)
                                        : (dronePosition ?? _phonePosition);
                                if (target != null) {
                                  try {
                                    _miniMapController.move(target, 18.0);
                                    log.info(
                                      '小地圖回到目前模式中心: ${_usePhoneAsMapCenter ? "手機" : "無人機"} -> (${target.latitude}, ${target.longitude})',
                                    );
                                  } catch (e) {
                                    log.warning('小地圖移動失敗: $e');
                                  }
                                } else {
                                  log.warning('小地圖無可用位置可回到中心');
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.6),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  _usePhoneAsMapCenter
                                      ? Icons.phone_android
                                      : Icons.airplanemode_active, // 修正图标逻辑
                                  color:
                                      _usePhoneAsMapCenter
                                          ? Colors.blue
                                          : Colors.red, // 修正颜色逻辑
                                  size: 16,
                                ),
                              ),
                            ),
                          ),
                          // 添加全螢幕按鈕
                          Positioned(
                            top: 5,
                            right: 5,
                            child: GestureDetector(
                              onTap: () {
                                log.info('小地圖全螢幕按鈕被點擊，開啟全螢幕地圖');
                                _showFullScreenMap();
                              },
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.6),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(
                                  Icons.fullscreen,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Positioned(
            //   right: 20,
            //   top: (MediaQuery.of(context).size.height - 60) / 2 - 50,
            //   child: IconButton(
            //     onPressed: () {
            //       _showRecordingOptionsDialog(context);
            //     },
            //     icon: const Icon(Icons.movie, color: Colors.white, size: 30),
            //     style: IconButton.styleFrom(
            //       backgroundColor: Colors.black.withOpacity(0.3),
            //       shape: const CircleBorder(),
            //       padding: const EdgeInsets.all(10),
            //     ),
            //     tooltip: '錄影選項',
            //   ),
            // ),
            if (isFullScreen)
              Positioned(
                top: 100,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.fullscreen,
                        color: Colors.white,
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        '全螢幕模式',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Positioned(
              right: 20,
              top: (MediaQuery.of(context).size.height - 60) / 2 + 80,
              child: IconButton(
                onPressed: takePhoto,
                icon: const Icon(
                  Icons.camera_alt,
                  color: Colors.white,
                  size: 28,
                ),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withOpacity(0.3),
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(12),
                ),
                tooltip: '拍照',
              ),
            ),
            Positioned(
              right: 20,
              top: (MediaQuery.of(context).size.height - 60) / 2,
              child: RecordButton(
                isRecording: isRecording,
                onTap: () {
                  if (!isRecording) {
                    startRecording();
                  } else {
                    stopRecording();
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AnimatedJoystickStick extends StatefulWidget {
  final double x;
  final double y;

  const AnimatedJoystickStick({super.key, required this.x, required this.y});

  @override
  _AnimatedJoystickStickState createState() => _AnimatedJoystickStickState();
}

class _AnimatedJoystickStickState extends State<AnimatedJoystickStick>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(AnimatedJoystickStick oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.x != 0 || widget.y != 0) &&
        (_scaleController.status == AnimationStatus.dismissed ||
            _scaleController.status == AnimationStatus.reverse)) {
      _scaleController.forward();
    } else if (widget.x == 0 &&
        widget.y == 0 &&
        (_scaleController.status == AnimationStatus.completed ||
            _scaleController.status == AnimationStatus.forward)) {
      _scaleController.reverse();
    }
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _scaleAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Container(
            width: 55,
            height: 55,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Colors.blueGrey.shade600, Colors.blueGrey.shade400],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 6,
                  offset: const Offset(2, 2),
                ),
              ],
            ),
            child: Center(
              child: Icon(
                Icons.control_camera_rounded,
                color: Colors.white.withOpacity(0.8),
                size: 24,
              ),
            ),
          ),
        );
      },
    );
  }
}

class ServoTrackPainter extends CustomPainter {
  final double servoAngle;
  final bool isDragging;

  ServoTrackPainter({required this.servoAngle, required this.isDragging});

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = Colors.white.withOpacity(isDragging ? 0.9 : 0.5)
          ..strokeWidth = 4.0
          ..style = PaintingStyle.stroke;

    final trackPaint =
        Paint()
          ..color = Colors.grey.withOpacity(0.4)
          ..strokeWidth = 8.0
          ..style = PaintingStyle.stroke;

    final sliderPaint =
        Paint()
          ..color = isDragging ? Colors.blueAccent.shade400 : Colors.white
          ..style = PaintingStyle.fill;

    final centerX = size.width / 2;
    final trackHeight = size.height - 20;
    final trackTop = 10.0;
    final trackBottom = trackHeight + 10;

    // 繪製軌道
    canvas.drawLine(
      Offset(centerX, trackTop),
      Offset(centerX, trackBottom),
      trackPaint,
    );

    // 計算滑塊位置
    final normalized = (servoAngle + 45) / 135;
    final sliderY = trackBottom - normalized * trackHeight;
    canvas.drawCircle(
      Offset(centerX, sliderY.clamp(trackTop, trackBottom)),
      isDragging ? 12.0 : 10.0,
      sliderPaint,
    );

    // 繪製滑塊陰影
    if (isDragging) {
      canvas.drawCircle(
        Offset(centerX, sliderY.clamp(trackTop, trackBottom)),
        14.0,
        Paint()
          ..color = Colors.black.withOpacity(0.3)
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class JoystickCrosshairPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint =
        Paint()
          ..color = Colors.white.withOpacity(0.2)
          ..strokeWidth = 1.0;

    double lineLength = size.width * 0.35;
    canvas.drawLine(
      Offset(center.dx - lineLength / 2, center.dy),
      Offset(center.dx + lineLength / 2, center.dy),
      paint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - lineLength / 2),
      Offset(center.dx, center.dy + lineLength / 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class JoystickBase extends StatelessWidget {
  final JoystickMode mode;

  const JoystickBase({super.key, this.mode = JoystickMode.all});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      height: 150,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            Colors.blueGrey.shade800.withOpacity(0.3),
            Colors.black.withOpacity(0.6),
          ],
          stops: const [0.7, 1.0],
          center: Alignment.center,
          radius: 0.9,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: Colors.blueGrey.shade900.withOpacity(0.9),
            spreadRadius: -5.0,
            blurRadius: 10.0,
          ),
        ],
      ),
      child: CustomPaint(
        painter: JoystickCrosshairPainter(),
        size: const Size(150, 150),
      ),
    );
  }
}

class RecordButton extends StatefulWidget {
  final bool isRecording;
  final VoidCallback onTap;

  const RecordButton({
    super.key,
    required this.isRecording,
    required this.onTap,
  });

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _sizeAnim;
  late Animation<BorderRadius?> _borderAnim;
  late Animation<double> _pulseAnimIcon;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _sizeAnim = Tween<double>(begin: 30, end: 20).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
    _borderAnim = BorderRadiusTween(
      begin: BorderRadius.circular(30),
      end: BorderRadius.circular(8),
    ).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
    _pulseAnimIcon = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    if (widget.isRecording) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant RecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording != oldWidget.isRecording) {
      if (widget.isRecording) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color:
              widget.isRecording
                  ? Colors.red.withOpacity(0.7)
                  : Colors.black.withOpacity(0.3),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color:
                widget.isRecording ? Colors.red.shade900 : Colors.grey.shade700,
            width: 3,
          ),
          boxShadow:
              widget.isRecording
                  ? [
                    BoxShadow(
                      color: Colors.red.withOpacity(0.5),
                      blurRadius: 10,
                    ),
                  ]
                  : [],
        ),
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Container(
                width: _sizeAnim.value,
                height: _sizeAnim.value,
                decoration: BoxDecoration(
                  color: Colors.red.shade900,
                  borderRadius: _borderAnim.value,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.shade900.withOpacity(
                        widget.isRecording ? 0.7 : 0.3,
                      ),
                      blurRadius: widget.isRecording ? 8 : 3,
                      spreadRadius: widget.isRecording ? 2 : 0,
                    ),
                  ],
                ),
                child:
                    widget.isRecording
                        ? null
                        : FadeTransition(
                          opacity: ReverseAnimation(_pulseAnimIcon),
                          child: Icon(
                            Icons.videocam,
                            color: Colors.white,
                            size: _sizeAnim.value * 0.9,
                          ),
                        ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeOption({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label, style: const TextStyle(color: Colors.black87)),
      selected: isSelected,
      selectedColor: Colors.blueAccent.withOpacity(0.6),
      backgroundColor: Colors.white24,
      onSelected: (_) => onTap(),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
          ..color = Colors.white.withOpacity(0.3) // 半透明白色
          ..strokeWidth = 1;

    // 垂直線 (三等分)
    final dx = size.width / 3;
    for (int i = 1; i < 3; i++) {
      canvas.drawLine(Offset(dx * i, 0), Offset(dx * i, size.height), paint);
    }

    // 水平線 (三等分)
    final dy = size.height / 3;
    for (int i = 1; i < 3; i++) {
      canvas.drawLine(Offset(0, dy * i), Offset(size.width, dy * i), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
