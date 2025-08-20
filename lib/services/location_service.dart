import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:logging/logging.dart';

class LocationService {
  final Logger _log = Logger('LocationService');
  final StreamController<LatLng> _locationController = StreamController<LatLng>.broadcast();
  StreamSubscription<Position>? _positionStream;

  Stream<LatLng> get locationStream => _locationController.stream;

  Future<LatLng?> getCurrentLocation() async {
    try {
      bool locationEnable = await Geolocator.isLocationServiceEnabled();
      if (!locationEnable) {
        _log.warning('位置服務未啟用');
        return null;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _log.warning('位置權限被拒絕');
          return null;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _log.warning('位置權限被永久拒絕');
        return null;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final location = LatLng(position.latitude, position.longitude);
      _locationController.add(location);
      return location;
    } catch (e) {
      _log.severe('獲取位置失敗: $e');
      return null;
    }
  }

  void startLocationTracking() {
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen(
          (Position position) {
        _locationController.add(LatLng(position.latitude, position.longitude));
      },
      onError: (e) {
        _log.severe('位置追蹤錯誤: $e');
      },
    );
  }

  void stopLocationTracking() {
    _positionStream?.cancel();
    _positionStream = null;
  }

  void dispose() {
    stopLocationTracking();
    _locationController.close();
  }
}