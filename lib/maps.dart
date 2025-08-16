import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class DroneMapPage extends StatefulWidget {
  @override
  State<DroneMapPage> createState() => _DroneMapPageState();
}

class _DroneMapPageState extends State<DroneMapPage> {
  // 模擬無人機初始位置 (台北 101)
  LatLng dronePosition = LatLng(25.0330, 121.5654);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Drone Tracker")),
      body: FlutterMap(
        options: MapOptions(
          initialCenter: dronePosition,
          initialZoom: 16,
        ),
        children: [
          TileLayer(
            urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
            userAgentPackageName: "com.example.app",
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: dronePosition,
                width: 40,
                height: 40,
                child: Icon(Icons.airplanemode_active, color: Colors.red, size: 40),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: Icon(Icons.navigation),
        onPressed: () {
          // TODO: 在這裡接收樹莓派傳來的新座標，然後 setState 更新
          setState(() {
            dronePosition = LatLng(25.034, 121.565); // 模擬移動
          });
        },
      ),
    );
  }
}
