import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class DroneMiniMap extends StatelessWidget {
  final LatLng? dronePosition;
  final VoidCallback? onTap;

  const DroneMiniMap({
    super.key,
    required this.dronePosition,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: 150,
          height: 100,
          child: FlutterMap(
            options: MapOptions(
              initialCenter: dronePosition ?? LatLng(25.0330, 121.5654), // 台北預設位置
              initialZoom: 18,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.drone_app',
              ),
              if (dronePosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: dronePosition!,
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.airplanemode_active,
                        color: Colors.black,
                        size: 30,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}