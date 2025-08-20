import 'package:drone/pages/home.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 日誌設定
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint('${record.level.name}: ${record.time}: ${record.message}');
  });
  runApp(DroneJoystickApp());
}

class DroneJoystickApp extends StatelessWidget {
  const DroneJoystickApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        debugShowCheckedModeBanner: false,
        home:  Home());
  }
}

