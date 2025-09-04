import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:lottie/lottie.dart';
import 'drone_joystick_page.dart';
import 'maps.dart';

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

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final bool isSelect = false;
  bool isConnect = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF2E335A).withOpacity(0.4), // 深藍紫
              Color(0xFF1C1B33).withOpacity(0.9), // 更深藍
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [0.2, 1.0],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
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
                          dividerColor: Colors.transparent,
                          // Flutter 3.7+ 才有
                          indicatorSize: TabBarIndicatorSize.tab,
                          labelStyle: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          tabs: [Tab(text: "我的裝置"), Tab(text: "未知裝置")],
                        ),
                        Expanded(
                          child: TabBarView(
                            children: [
                              // Tab 1：我的裝置
                              Padding(
                                padding: const EdgeInsets.fromLTRB(0,10,0,0),
                                child: GridView.builder(
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: 2, // 每行 2 個卡片
                                        crossAxisSpacing: 8.0, // 水平間距
                                        mainAxisSpacing: 8.0, // 垂直間距
                                      ),
                                  itemCount: 1, // 顯示 10 格
                                  itemBuilder: (context, index) {
                                    return ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: InkWell(
                                        onTap: () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder:
                                                  (context) =>
                                                  DroneJoystickPage(),
                                            ),
                                          );
                                        },
                                        child: Stack(
                                          children: [
                                            BackdropFilter(
                                              filter: ImageFilter.blur(
                                                sigmaX: 10,
                                                sigmaY: 10,
                                              ),
                                              child: Container(),
                                            ),
                                            Container(
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                                border: Border.all(
                                                  color: Colors.white.withOpacity(
                                                    0.2,
                                                  ),
                                                  width: 1,
                                                ),
                                                gradient: LinearGradient(
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                  colors: [
                                                    Colors.transparent
                                                        .withOpacity(0.1),
                                                    Colors.transparent
                                                        .withOpacity(0.1),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            ListTile(
                                              leading: Icon(
                                                Icons.airplanemode_active,
                                                color: Colors.black,
                                              ),
                                              title: Text(
                                                "風暴毀滅者",
                                                style: TextStyle(
                                                  color: Colors.black,
                                                ),
                                              ),
                                              subtitle:
                                                  Row(
                                                    children: [
                                                      Container(
                                                        height: 10,
                                                        width: 10,
                                                        decoration: BoxDecoration(
                                                          color:
                                                              isConnect
                                                                  ? Colors.green
                                                                  : Colors.red,
                                                          shape: BoxShape.circle,
                                                        ),
                                                      ),
                                                      SizedBox(width: 5),
                                                      Text(
                                                        isConnect ? "已連接" : "未連接",
                                                      ),
                                                    ],
                                                  ),
                                            ),
                                            Padding(
                                              padding:  EdgeInsets.fromLTRB(0, 50, 0, 0),
                                              child: Image.asset(
                                                "assets/image/plane.png",
                                                width: 300,
                                                height: 300,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              // Tab 2：未知裝置
                              Center(
                                child: Text(
                                  "查無裝置，請插入USB並開啟藍芽搜尋",
                                  style: TextStyle(
                                    color: Colors.black,
                                    fontSize: 18,
                                  ),
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
      ),
    );
  }
}