import 'package:flutter/material.dart';
import 'mode_option.dart';

class MenuDialog extends StatefulWidget {
  final String selectedMode;
  final bool aiRecognitionEnabled;
  final bool aiRescueEnabled;
  final String droneIP;
  final Function(String) onModeChanged;
  final Function(bool) onAiRecognitionChanged;
  final Function(bool) onAiRescueChanged;
  final Function(String) onDroneIPChanged;
  final Widget ledButton;

  const MenuDialog({
    super.key,
    required this.selectedMode,
    required this.aiRecognitionEnabled,
    required this.aiRescueEnabled,
    required this.droneIP,
    required this.onModeChanged,
    required this.onAiRecognitionChanged,
    required this.onAiRescueChanged,
    required this.onDroneIPChanged,
    required this.ledButton,
  });

  @override
  State<MenuDialog> createState() => _MenuDialogState();
}

class _MenuDialogState extends State<MenuDialog> {
  String selectedMenu = '設定';

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 400,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.95,
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
          child: Stack(
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
                          onTap: () => setState(() => selectedMenu = '設定'),
                        ),
                        _MenuItem(
                          icon: Icons.info,
                          title: '資訊',
                          isSelected: selectedMenu == '資訊',
                          onTap: () => setState(() => selectedMenu = '資訊'),
                        ),
                        _MenuItem(
                          icon: Icons.help,
                          title: '幫助',
                          isSelected: selectedMenu == '幫助',
                          onTap: () => setState(() => selectedMenu = '幫助'),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16.0),
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
                            ..._buildSettingsUI(),
                          if (selectedMenu == '資訊')
                            ..._buildInfoUI(context),
                          if (selectedMenu == '幫助')
                            ..._buildHelpUI(context),
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
                  icon: const Icon(Icons.close, color: Colors.white, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withOpacity(0.3),
                    shape: const CircleBorder(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSettingsUI() {
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
        trailing: widget.ledButton,
      ),
      ListTile(
        leading: const Icon(Icons.photo_camera, color: Colors.white),
        title: const Text('AI 辨識', style: TextStyle(color: Colors.white)),
        trailing: Switch(
          value: widget.aiRecognitionEnabled,
          onChanged:widget.onAiRecognitionChanged,
        ),
      ),
      ListTile(
        leading: const Icon(Icons.photo_camera, color: Colors.white),
        title: const Text('AI 搜救', style: TextStyle(color: Colors.white)),
        trailing: Switch(
          value: widget.aiRescueEnabled,
          onChanged: widget.onAiRescueChanged,
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
      Wrap(
        spacing: 8.0,
        children: [
          ModeOption(
            label: '顯示加控制',
            isSelected: widget.selectedMode == '顯示加控制',
            onTap: () => widget.onModeChanged('顯示加控制'),
          ),
          ModeOption(
            label: '僅顯示',
            isSelected: widget.selectedMode == '僅顯示',
            onTap: () => widget.onModeChanged('僅顯示'),
          ),
          ModeOption(
            label: '協同作業',
            isSelected: widget.selectedMode == '協同作業',
            onTap: () => widget.onModeChanged('協同作業'),
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
        controller: TextEditingController(text: widget.droneIP),
        onChanged: widget.onDroneIPChanged,
      ),
    ];
  }

  List<Widget> _buildInfoUI(BuildContext context) {
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
            context: context,
            builder: (context) => AlertDialog(
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

  List<Widget> _buildHelpUI(BuildContext context) {
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
            context: context,
            builder: (context) => AlertDialog(
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
}