import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';

class DroneMapPage extends StatefulWidget {
  @override
  State<DroneMapPage> createState() => _DroneMapPageState();
}

class _DroneMapPageState extends State<DroneMapPage> {
  final Logger log = Logger('DroneMapPage');
  LatLng dronePosition = LatLng(23.016725, 120.232065);
  LatLng? _phonePosition; // 手機位置
  int _currentTileProvider = 0;
  bool _isSatelliteView = false; // 衛星視圖切換
  
  // Multiple tile providers for fallback
  final List<Map<String, dynamic>> tileProviders = [
    {
      'name': 'Google Maps (中文)',
      'urlTemplate': 'https://mt{s}.google.com/vt/lyrs=m&x={x}&y={y}&z={z}&hl=zh-TW',
      'subdomains': ['0', '1', '2', '3'],
    },
    {
      'name': 'Google 衛星圖',
      'urlTemplate': 'https://mt{s}.google.com/vt/lyrs=s&x={x}&y={y}&z={z}&hl=zh-TW',
      'subdomains': ['0', '1', '2', '3'],
    },
    {
      'name': 'Google 地形圖',
      'urlTemplate': 'https://mt{s}.google.com/vt/lyrs=p&x={x}&y={y}&z={z}&hl=zh-TW',
      'subdomains': ['0', '1', '2', '3'],
    },
    {
      'name': 'OpenStreetMap (中文)',
      'urlTemplate': 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png?lang=zh',
      'subdomains': ['a', 'b', 'c'],
    },
    {
      'name': 'CartoDB Positron',
      'urlTemplate': 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
      'subdomains': ['a', 'b', 'c', 'd'],
    },
  ];

  @override
  void initState() {
    super.initState();
    log.info('DroneMapPage initialized');
    _getCurrentLocation(); // 獲取手機位置
  }

  Future<void> _getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        log.warning('位置服務未啟用');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          log.warning('位置權限被拒絕');
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        log.warning('位置權限永久被拒絕');
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      setState(() {
        _phonePosition = LatLng(position.latitude, position.longitude);
      });
      log.info('獲取手機位置成功: ${position.latitude}, ${position.longitude}');
    } catch (e) {
      log.severe('獲取位置失敗: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Drone Tracker"),
        actions: [
          // 衛星視圖切換按鈕
          IconButton(
            icon: Icon(
              _isSatelliteView ? Icons.map : Icons.satellite,
              color: _isSatelliteView ? Colors.orange : null,
            ),
            onPressed: () {
              setState(() {
                _isSatelliteView = !_isSatelliteView;
                // 根據衛星視圖狀態選擇適合的地圖提供商
                if (_isSatelliteView) {
                  _currentTileProvider = 1; // Google 衛星圖
                } else {
                  _currentTileProvider = 0; // Google Maps 標準地圖
                }
              });
              log.info('地圖視圖切換為: ${_isSatelliteView ? "衛星視圖" : "標準地圖"}');
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('地圖視圖: ${_isSatelliteView ? "衛星視圖" : "標準地圖"}'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            tooltip: _isSatelliteView ? '切換到標準地圖' : '切換到衛星視圖',
          ),
          // 定位按鈕
          IconButton(
            icon: const Icon(Icons.my_location),
            onPressed: () {
              _getCurrentLocation();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('正在更新位置...'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            tooltip: '更新位置',
          ),
        ],
      ),
      body: FlutterMap(
        options: MapOptions(
          initialCenter: _phonePosition ?? dronePosition,
          initialZoom: 16,
        ),
        children: [
          TileLayer(
            urlTemplate: tileProviders[_currentTileProvider]['urlTemplate'],
            subdomains: List<String>.from(tileProviders[_currentTileProvider]['subdomains']),
            userAgentPackageName: 'com.example.drone_app',
            maxZoom: 19,
            additionalOptions: const {
              'User-Agent': 'drone_app/1.0.0 (contact@example.com)',
              'Referer': 'https://www.openstreetmap.org/',
            },
            errorTileCallback: (tile, error, stackTrace) {
              log.severe('地圖瓦片載入失敗 (${tileProviders[_currentTileProvider]['name']}): $error');
              // Auto switch to next provider on error
              if (_currentTileProvider < tileProviders.length - 1) {
                setState(() {
                  _currentTileProvider++;
                  log.info('切換到下一個地圖提供商: ${tileProviders[_currentTileProvider]['name']}');
                });
              }
            },
          ),
          MarkerLayer(
            markers: [
              // 無人機位置標記
              Marker(
                point: dronePosition,
                width: 40,
                height: 40,
                child: Icon(Icons.airplanemode_active, color: Colors.red, size: 40),
              ),
              // 手機位置標記
              if (_phonePosition != null)
                Marker(
                  point: _phonePosition!,
                  width: 40,
                  height: 40,
                  child: Icon(Icons.phone_android, color: Colors.blue, size: 40),
                ),
            ],
          ),
          RichAttributionWidget(
            attributions: [
              TextSourceAttribution(
                '© OpenStreetMap contributors',
                onTap: () => launchUrl(Uri.parse('https://www.openstreetmap.org/copyright')),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: "map_provider",
            mini: true,
            child: Icon(Icons.layers),
            onPressed: () {
              setState(() {
                _currentTileProvider = (_currentTileProvider + 1) % tileProviders.length;
                // 更新衛星視圖狀態
                _isSatelliteView = tileProviders[_currentTileProvider]['name'].contains('衛星');
                log.info('切換地圖提供商到: ${tileProviders[_currentTileProvider]['name']}');
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('地圖提供商: ${tileProviders[_currentTileProvider]['name']}'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            tooltip: '切換地圖提供商',
          ),
          SizedBox(height: 10),
          FloatingActionButton(
            heroTag: "drone_location",
            child: Icon(Icons.navigation),
            onPressed: () {
              setState(() {
                dronePosition = LatLng(25.034, 121.565);
                log.info('Drone position updated to: $dronePosition');
              });
            },
            tooltip: '更新無人機位置',
          ),
        ],
      ),
    );
  }
}