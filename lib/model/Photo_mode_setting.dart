import 'package:flutter/material.dart';

class RecordingOptionsDialog extends StatefulWidget {
  const RecordingOptionsDialog({super.key});

  @override
  State<RecordingOptionsDialog> createState() => _RecordingOptionsDialogState();
}

class _RecordingOptionsDialogState extends State<RecordingOptionsDialog> {
  String _selectedMain = '拍照';
  String _selectedSub = '';

  static const Color _iconColor = Colors.white;
  static const Color _textColor = Colors.white;
  static const Color _selectedColor = Colors.yellow;
  static const Color _dialogBackgroundColor = Color.fromRGBO(30, 30, 30, 0.85);

  final List<Map<String, dynamic>> _mainItems = [
    {'icon': Icons.photo_camera, 'label': "拍照"},
    {'icon': Icons.movie_filter_outlined, 'label': '錄影'},
    {'icon': Icons.nightlight_round_outlined, 'label': '夜景'},
    {'icon': Icons.slow_motion_video_outlined, 'label': '慢动作'},
    {'icon': Icons.star_outline, 'label': '大师镜头'},
    {'icon': Icons.movie_creation_outlined, 'label': '一键短片'},
    {'icon': Icons.hourglass_empty_outlined, 'label': '延时摄影'},
  ];

  final Map<String, List<String>> _subItems = const {
    '拍照': ['標準', '廣角', '人像', 'HDR'],
    '錄影': ['1080P', '4K', '慢動作'],
    '夜景': ['自動', '光軌模式', '星空'],
    '慢动作': ['120fps', '240fps'],
    '大师镜头': ['電影感', '復古', '黑白'],
    '一键短片': ['15秒', '30秒', '60秒'],
    '延时摄影': ['日出', '星軌', '車流'],
  };

  Widget _buildMainItem(Map<String, dynamic> item) {
    final bool isSelected = _selectedMain == item['label'];
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedMain = item['label'] as String;
          _selectedSub = '';
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        color: isSelected ? Colors.white24 : Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              item['icon'] as IconData,
              color: isSelected ? _selectedColor : _iconColor,
              size: 28,
            ),
            const SizedBox(height: 6),
            Text(
              item['label'] as String,
              style: TextStyle(
                color: isSelected ? _selectedColor : _textColor,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubItem(String label) {
    final bool isSelected = _selectedSub == label;
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedSub = label;
        });
        if (mounted) {
          Navigator.of(context).pop('$_selectedMain - $label');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('選擇了: $_selectedMain - $label')),
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
        color: isSelected ? Colors.white24 : Colors.transparent,
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? _selectedColor : _textColor,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const double dialogWidth = 260;
    const double dialogHeight = 320;

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: dialogWidth,
        height: dialogHeight,
        margin: const EdgeInsets.only(right: 70),
        decoration: BoxDecoration(
          color: _dialogBackgroundColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              flex: 1,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                children: (_subItems[_selectedMain] ?? [])
                    .map(_buildSubItem)
                    .toList(),
              ),
            ),
            Container(width: 1, color: Colors.grey),
            Expanded(
              flex: 1,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 10),
                children: _mainItems.map(_buildMainItem).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
