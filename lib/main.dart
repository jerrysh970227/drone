import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:lottie/lottie.dart';
import 'drone_joystick_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 沉浸模式
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // 日誌設定
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint('${record.level.name}: ${record.time}: ${record.message}');
  });

  runApp(const DroneJoystickApp());
}


class DroneJoystickApp extends StatelessWidget {
  const DroneJoystickApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(debugShowCheckedModeBanner: false, home: Home());
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final bool isSelect = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Padding(
        padding: const EdgeInsets.all(30),
        child: Center(
          child: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        "Welcome to Our DIY Drone App! ",
                        maxLines: 5,
                        style: TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                      ),
                    ),
                    SizedBox(width: 5),
                    Lottie.asset(
                      "assets/lottie/droneFly.json",
                      width: 150,
                      height: 300,
                      repeat: true,
                    ),
                  ],
                ),
                flex: 2,
              ),
              SizedBox(height: 8),
              Expanded(
                child: DefaultTabController(
                  length: 2,
                  child: Column(
                    children: [
                      TabBar(
                        labelColor: Colors.white,
                        // 選中的文字顏色
                        unselectedLabelColor: Colors.black,
                        // 沒選中的顏色
                        indicator: BoxDecoration(
                          color: Colors.black, // 背景顏色
                          borderRadius: BorderRadius.circular(30), // 圓角半徑
                        ),
                        indicatorSize: TabBarIndicatorSize.tab,
                        labelStyle: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        tabs: [Tab(text: "我的裝置"), Tab(text: "未知裝置")],
                      ),
                      SizedBox(height: 30),
                      Expanded(
                        child: TabBarView(
                          children: [
                            // Tab 1：我的裝置
                            GridView.builder(
                              gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2, // 每行 2 個卡片
                                crossAxisSpacing: 8.0, // 水平間距
                                mainAxisSpacing: 8.0, // 垂直間距
                              ),
                              itemCount: 1, // 顯示 10 格
                              itemBuilder: (context, index) {
                                return Card(
                                  shadowColor: Colors.black,
                                  elevation: 10,
                                  color: const Color.fromARGB(255, 65, 62, 62),
                                  shape: RoundedRectangleBorder(
                                    side: BorderSide(color: Colors.black, width: 2),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: ListTile(
                                    leading: Icon(
                                      Icons.airplanemode_active,
                                      color: Colors.white,
                                    ),
                                    title: Text(
                                      "風暴毀滅者",
                                      style: TextStyle(color: Colors.white),
                                    ),
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder:
                                              (context) => DroneJoystickPage(),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                            // Tab 2：未知裝置
                            Center(
                              child: Text(
                                "查無裝置，請插入USB並開啟藍芽搜尋",
                                style: TextStyle(color: Colors.black),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                flex: 7,
              ),
            ],
          ),
        ),
      ),
    );
  }
}