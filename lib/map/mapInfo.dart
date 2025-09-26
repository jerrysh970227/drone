import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as GMaps;
import 'package:flutter_map/flutter_map.dart' as FMap;
import 'package:latlong2/latlong.dart' as latLng;
import 'package:logging/logging.dart';

class MapService {
  static final Logger log = Logger('MapService');

  // 地图相关状态
  GMaps.GoogleMapController? _googleMapController;
  GMaps.CameraPosition? _currentCameraPosition;
  final FMap.MapController _miniMapController = FMap.MapController();
  bool _isMapInitialized = false;
  bool _isSatelliteView = false;
  bool _showApiKeyOverlay = true;
  bool _usePhoneAsMapCenter = true;

  // 位置信息
  latLng.LatLng? _phonePosition;
  latLng.LatLng? dronePosition;

  // Getters
  bool get isSatelliteView => _isSatelliteView;
  bool get showApiKeyOverlay => _showApiKeyOverlay;
  bool get usePhoneAsMapCenter => _usePhoneAsMapCenter;
  latLng.LatLng? get phonePosition => _phonePosition;

  // Setters
  set isSatelliteView(bool value) => _isSatelliteView = value;
  set showApiKeyOverlay(bool value) => _showApiKeyOverlay = value;
  set usePhoneAsMapCenter(bool value) => _usePhoneAsMapCenter = value;
  set phonePosition(latLng.LatLng? position) => _phonePosition = position;

  /// 获取当前位置
  Future<void> getCurrentLocation(BuildContext context) async {
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

      _phonePosition = latLng.LatLng(position.latitude, position.longitude);
      log.info('獲取手機位置成功: ${position.latitude}, ${position.longitude}');

      // 顯示成功提示
      if (context.mounted) {
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
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('獲取位置失敗: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  /// 显示全屏地图
  void showFullScreenMap(BuildContext context, {VoidCallback? onStateChanged}) {
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
                  appBar: _buildMapAppBar(context, dialogSetState, isTablet, onStateChanged),
                  body: _buildFullScreenMapBody(context, dialogSetState),
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
        showTabletOptimizedMap(context, onStateChanged: onStateChanged);
      } else {
        // 手機設備的簡單處理
        showFlutterMapFallback(context, onStateChanged: onStateChanged);
      }
    }
  }

  /// 构建地图应用栏
  PreferredSizeWidget _buildMapAppBar(BuildContext context, StateSetter dialogSetState, bool isTablet, VoidCallback? onStateChanged) {
    return AppBar(
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
        // 衛星視圖切換按鈕
        IconButton(
          icon: Icon(
            _isSatelliteView ? Icons.map : Icons.satellite,
            color: _isSatelliteView ? Colors.orange : Colors.white,
            size: isTablet ? 28 : 24,
          ),
          onPressed: () {
            // 儲存當前攝影機位置
            if (_googleMapController != null) {
              _googleMapController!.getVisibleRegion().then((bounds) {
                final center = GMaps.LatLng(
                  (bounds.northeast.latitude + bounds.southwest.latitude) / 2,
                  (bounds.northeast.longitude + bounds.southwest.longitude) / 2,
                );
                _isSatelliteView = !_isSatelliteView;
                // 保持當前位置和視角（所有模式都使用 3D）
                _currentCameraPosition = GMaps.CameraPosition(
                  target: center,
                  zoom: _currentCameraPosition?.zoom ?? 16.0,
                  tilt: _currentCameraPosition?.tilt ?? (_isSatelliteView ? 60.0 : 45.0),
                  bearing: _currentCameraPosition?.bearing ?? 30.0,
                );

                // 在當前對話框中更新地圖
                dialogSetState(() {
                  // 觸發對話框內部重建
                });
                onStateChanged?.call();

                log.info(
                  '地圖視圖切換為: ${_isSatelliteView ? "衛星視圖" : "標準地圖"}，保持當前位置: ${center.latitude}, ${center.longitude}',
                );
              });
            } else {
              _isSatelliteView = !_isSatelliteView;
              dialogSetState(() {});
              onStateChanged?.call();
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
            getCurrentLocation(context);
            // 更新 Google Maps 攝影機位置（所有模式都使用 3D）
            if (_googleMapController != null && _phonePosition != null) {
              _googleMapController!.animateCamera(
                GMaps.CameraUpdate.newCameraPosition(
                  GMaps.CameraPosition(
                    target: GMaps.LatLng(
                      _phonePosition!.latitude,
                      _phonePosition!.longitude,
                    ),
                    zoom: 16.0,
                    tilt: _isSatelliteView ? 60.0 : 45.0,
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
              showTabletOptimizedMap(context, onStateChanged: onStateChanged);
              log.info('平板切換到 FlutterMap 降級模式');
            },
            tooltip: '切換到備援地圖',
          ),
        IconButton(
          icon: Icon(Icons.close, size: isTablet ? 28 : 24),
          onPressed: () {
            log.info('關閉全螢幕地圖 - 設備: ${isTablet ? "平板" : "手機"}');
            Navigator.of(context).pop();
          },
          tooltip: '關閉',
        ),
      ],
    );
  }

  /// 专为平板优化的地图显示方法
  void showTabletOptimizedMap(BuildContext context, {VoidCallback? onStateChanged}) {
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
                    _isSatelliteView = !_isSatelliteView;
                    onStateChanged?.call();
                    // 重新顯示地圖以應用新設置
                    Navigator.of(context).pop();
                    showTabletOptimizedMap(context, onStateChanged: onStateChanged);
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
                    showFullScreenMap(context, onStateChanged: onStateChanged); // 嘗試使用 Google Maps 3D
                    log.info('平板嘗試切換到 Google Maps 3D 模式');
                  },
                  tooltip: '嘗試 3D 模式 (Google Maps)',
                ),
                IconButton(
                  icon: const Icon(Icons.my_location, size: 28),
                  onPressed: () {
                    getCurrentLocation(context);
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

  /// 为平板构建优化的 FlutterMap
  Widget _buildTabletFlutterMap() {
    log.info('構建平板專用 FlutterMap - 衛星模式: $_isSatelliteView');

    // 根據設置決定地圖中心位置
    latLng.LatLng mapCenter;
    if (_usePhoneAsMapCenter) {
      mapCenter = _phonePosition ?? dronePosition ?? const latLng.LatLng(25.0330, 121.5654);
      log.info('平板地圖中心設為手機位置: ${_phonePosition?.latitude}, ${_phonePosition?.longitude}');
    } else {
      mapCenter = dronePosition ?? _phonePosition ?? const latLng.LatLng(25.0330, 121.5654);
      log.info('平板地圖中心設為無人機位置: ${dronePosition?.latitude}, ${dronePosition?.longitude}');
    }

    return FMap.FlutterMap(
      options: FMap.MapOptions(
        initialCenter: mapCenter,
        initialZoom: 16.0,
        minZoom: 3.0,
        maxZoom: 22.0,
        interactionOptions: const FMap.InteractionOptions(
          flags: FMap.InteractiveFlag.all,
        ),
      ),
      children: [
        FMap.TileLayer(
          urlTemplate: _isSatelliteView
              ? 'https://mt{s}.google.com/vt/lyrs=s&x={x}&y={y}&z={z}&hl=zh-TW'
              : 'https://mt{s}.google.com/vt/lyrs=m&x={x}&y={y}&z={z}&hl=zh-TW',
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
                  width: 50.0,
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
                  width: 55.0,
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
        _buildTabletStatusOverlay(),
        // 平板備援模式提示訊息
        _buildTabletFallbackMessage(),
      ],
    );
  }

  /// 构建平板状态覆盖层
  Widget _buildTabletStatusOverlay() {
    return Positioned(
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
    );
  }

  /// 构建平板备援模式提示消息
  Widget _buildTabletFallbackMessage() {
    return Positioned(
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
    );
  }

  /// 构建全屏地图主体
  Widget _buildFullScreenMapBody(BuildContext context, [StateSetter? dialogSetState]) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.shortestSide >= 600;
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;

    log.info(
      '設備資訊 - 螢幕尺寸: ${screenSize.width}x${screenSize.height}, 最短邊: ${screenSize.shortestSide}, 是否為平板: $isTablet, 像素比: $pixelRatio',
    );

    try {
      return Stack(
        children: [
          GMaps.GoogleMap(
            mapType: _determineOptimalMapType(),
            initialCameraPosition: _currentCameraPosition ??
                GMaps.CameraPosition(
                  target: _determineMapCenter(),
                  zoom: isTablet ? 18.0 : 16.0,
                  tilt: _isSatelliteView ? 70.0 : (isTablet ? 60.0 : 45.0),
                  bearing: 45.0,
                ),
            onMapCreated: (GMaps.GoogleMapController controller) {
              _onMapCreated(controller, context, isTablet);
            },
            onCameraMove: (GMaps.CameraPosition position) {
              _currentCameraPosition = position;
            },
            buildingsEnabled: true,
            tiltGesturesEnabled: true,
            rotateGesturesEnabled: true,
            zoomGesturesEnabled: true,
            scrollGesturesEnabled: true,
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            compassEnabled: true,
            mapToolbarEnabled: false,
            indoorViewEnabled: true,
            trafficEnabled: false,
            liteModeEnabled: false,
            markers: _buildMapMarkers(isTablet),
            onTap: (GMaps.LatLng position) {
              log.info(
                '點擊地圖位置: ${position.latitude}, ${position.longitude} - 設備: ${isTablet ? "平板" : "手機"}',
              );
            },
          ),
          _buildApiKeyInfoOverlay(context, dialogSetState, isTablet),
        ],
      );
    } catch (e) {
      log.severe('Google Maps 初始化失敗: $e，切換到 FlutterMap');
      return _buildFlutterMapFallback();
    }
  }

  /// 处理地图创建完成事件
  void _onMapCreated(GMaps.GoogleMapController controller, BuildContext context, bool isTablet) {
    _googleMapController = controller;
    _isMapInitialized = true;

    log.info(
      '${isTablet ? "平板" : "手機"} Google Maps 控制器初始化 - 永久 3D 模式, 衛星模式: $_isSatelliteView, 地圖類型: ${_determineOptimalMapType()}',
    );

    if (isTablet) {
      // 平板專用：更積極的 3D 加載策略
      log.info('平板設備啟動強化 3D 建築加載模式');

      _force3DView(controller, isTablet);

      Timer(const Duration(seconds: 1), () {
        if (_googleMapController != null) {
          _force3DView(_googleMapController!, isTablet);
          log.info('平板 3D 建築第一次強化完成');
        }
      });

      Timer(const Duration(seconds: 3), () {
        if (_googleMapController != null) {
          _force3DView(_googleMapController!, isTablet);
          log.info('平板 3D 建築最終強化完成 - 確保 3D 顯示');
        }
      });

      Timer(const Duration(seconds: 5), () {
        _checkMapLoadingAndFallback(context, isTablet);
      });
    } else {
      // 手机设备的标准逻辑
      Timer(const Duration(seconds: 3), () {
        _checkMapLoadingAndFallback(context, isTablet);
      });

      Timer(const Duration(milliseconds: 500), () {
        if (controller != null) {
          _force3DView(controller, isTablet);
        }
      });

      Timer(const Duration(seconds: 2), () {
        if (controller != null) {
          _force3DView(controller, isTablet);
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
  }

  /// 构建地图标记点
  Set<GMaps.Marker> _buildMapMarkers(bool isTablet) {
    Set<GMaps.Marker> markers = {};

    // 手機位置標記
    if (_phonePosition != null) {
      markers.add(
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
      );
    }

    // 無人機位置標記
    if (dronePosition != null) {
      markers.add(
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
      );
    }

    return markers;
  }

  /// 构建API密钥信息覆盖层
  Widget _buildApiKeyInfoOverlay(BuildContext context, [StateSetter? dialogSetState, bool isTablet = false]) {
    log.info('試圖建立 API 金鑰覆蓋層，_showApiKeyOverlay = $_showApiKeyOverlay，設備類型: ${isTablet ? "平板" : "手機"}');

    if (!_showApiKeyOverlay) {
      log.info('覆蓋層已關閉，返回空 widget');
      return const SizedBox.shrink();
    }

    log.info('顯示 API 金鑰覆蓋層');
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
                    log.info('點擊關閉按鈕，當前 _showApiKeyOverlay = $_showApiKeyOverlay');
                    _showApiKeyOverlay = false;
                    if (dialogSetState != null) {
                      dialogSetState(() {});
                    }
                    log.info('已設定 _showApiKeyOverlay = $_showApiKeyOverlay，關閉 API 金鑰提示覆蓋層');
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
            _buildInfoStep('1. ', '在 AndroidManifest.xml 中設定有效的 Google Maps API 金鑰', isTablet),
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
                      showFlutterMapFallback(context);
                    },
                    icon: Icon(Icons.map, size: isTablet ? 22 : 18),
                    label: Text(
                      '使用備援地圖',
                      style: TextStyle(fontSize: isTablet ? 16 : 14),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade700,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(vertical: isTablet ? 12 : 8),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      _showApiKeyOverlay = false;
                      if (dialogSetState != null) {
                        dialogSetState(() {});
                      }
                    },
                    label: Text(
                      '知道了',
                      style: TextStyle(fontSize: isTablet ? 16 : 14),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade700,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(vertical: isTablet ? 12 : 8),
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

  /// 构建信息步骤
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

  /// 检查地图加载状态和备用方案
  void _checkMapLoadingAndFallback(BuildContext context, bool isTablet) {
    log.warning('檢查 Google Maps 加載狀態 - 設備: ${isTablet ? "平板" : "手機"}');

    if (isTablet && !_showApiKeyOverlay) {
      log.info('平板設備檢測到可能的地圖加載問題，準備備援方案');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('平板設備檢測到地圖加載問題，建議使用備援地圖模式'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: '使用備援地圖',
              onPressed: () {
                Navigator.of(context).pop();
                showFlutterMapFallback(context);
              },
            ),
          ),
        );
      }
    }
    log.warning('如果為空白則可能需要有效的 API 金鑰');
  }

  /// 决定最佳地图类型
  GMaps.MapType _determineOptimalMapType() {
    if (_isSatelliteView) {
      log.info('使用 hybrid 地圖類型以支援 3D 衛星模式');
      return GMaps.MapType.hybrid;
    } else {
      return GMaps.MapType.normal;
    }
  }

  /// 决定地图中心位置
  GMaps.LatLng _determineMapCenter() {
    GMaps.LatLng mapCenter;
    if (_usePhoneAsMapCenter) {
      mapCenter = _phonePosition != null
          ? GMaps.LatLng(_phonePosition!.latitude, _phonePosition!.longitude)
          : (dronePosition != null
          ? GMaps.LatLng(dronePosition!.latitude, dronePosition!.longitude)
          : const GMaps.LatLng(25.0330, 121.5654));
      log.info('Google Maps 地圖中心設為手機位置: ${_phonePosition?.latitude}, ${_phonePosition?.longitude}');
    } else {
      mapCenter = dronePosition != null
          ? GMaps.LatLng(dronePosition!.latitude, dronePosition!.longitude)
          : (_phonePosition != null
          ? GMaps.LatLng(_phonePosition!.latitude, _phonePosition!.longitude)
          : const GMaps.LatLng(25.0330, 121.5654));
      log.info('Google Maps 地圖中心設為無人機位置: ${dronePosition?.latitude}, ${dronePosition?.longitude}');
    }
    return mapCenter;
  }

  /// 强制设置3D视角
  void _force3DView(GMaps.GoogleMapController controller, bool isTablet) {
    final target = GMaps.LatLng(
      _currentCameraPosition?.target.latitude ?? 25.0330,
      _currentCameraPosition?.target.longitude ?? 121.5654,
    );

    final zoomLevel = isTablet ? 18.0 : (_currentCameraPosition?.zoom ?? 16.0);
    final tiltAngle = _isSatelliteView ? 70.0 : (isTablet ? 60.0 : 45.0);

    controller.animateCamera(
      GMaps.CameraUpdate.newCameraPosition(
        GMaps.CameraPosition(
          target: target,
          zoom: zoomLevel,
          tilt: tiltAngle,
          bearing: 45.0,
        ),
      ),
    );

    log.info(
      '設置 3D 視角 - 縮放: $zoomLevel, 傾斜: $tiltAngle°, 模式: ${_isSatelliteView ? "衛星" : "標準"}, 設備: ${isTablet ? "平板" : "手機"}',
    );

    _currentCameraPosition = GMaps.CameraPosition(
      target: target,
      zoom: zoomLevel,
      tilt: tiltAngle,
      bearing: 45.0,
    );
  }

  /// 构建FlutterMap备援地图
  Widget _buildFlutterMapFallback() {
    log.info('使用 FlutterMap 作為地圖備援');

    latLng.LatLng mapCenter;
    if (_usePhoneAsMapCenter) {
      mapCenter = _phonePosition ?? dronePosition ?? const latLng.LatLng(23.016725, 120.232065);
      log.info('地圖中心設為手機位置: ${_phonePosition?.latitude}, ${_phonePosition?.longitude}');
    } else {
      mapCenter = dronePosition ?? _phonePosition ?? const latLng.LatLng(23.016725, 120.232065);
      log.info('地圖中心設為無人機位置: ${dronePosition?.latitude}, ${dronePosition?.longitude}');
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
          urlTemplate: _isSatelliteView
              ? 'https://mt{s}.google.com/vt/lyrs=s&x={x}&y={y}&z={z}&hl=zh-TW'
              : 'https://mt{s}.google.com/vt/lyrs=m&x={x}&y={y}&z={z}&hl=zh-TW',
          subdomains: const ['0', '1', '2', '3'],
          userAgentPackageName: 'com.example.drone_app',
        ),
        if (dronePosition != null || _phonePosition != null)
          FMap.MarkerLayer(
            markers: [
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

  /// 显示FlutterMap备援全屏地图
  void showFlutterMapFallback(BuildContext context, {VoidCallback? onStateChanged}) {
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
                    _isSatelliteView = !_isSatelliteView;
                    onStateChanged?.call();
                    Navigator.of(context).pop();
                    showFlutterMapFallback(context, onStateChanged: onStateChanged);
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

  Widget buildMiniMap(){
    return FMap.FlutterMap(
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
    );
  }

  Widget buildMiniMapControl(BuildContext context,{VoidCallback ? onStateChanged}){
    return Stack(
      children: [
        // 添加衛星視圖切換按鈕
        Positioned(
          top: 5,
          left: 5,
          child: GestureDetector(
            onTap: () {
              _isSatelliteView = !_isSatelliteView;
              log.info(
                '小地圖視圖切換為: ${_isSatelliteView ? "衛星視圖" : "標準地圖"}',
              );
              onStateChanged?.call();
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
              showFullScreenMap(context,onStateChanged: onStateChanged);
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
    );
  }

  /// 清理资源
  void dispose() {
    _googleMapController = null;
    _currentCameraPosition = null;
    _isMapInitialized = false;
  }
}