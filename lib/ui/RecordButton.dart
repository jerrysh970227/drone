import 'package:drone/model/RecordService.dart';
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

class RecordButton extends StatefulWidget {
  final VoidCallback onTap;
  final VideoRecordingService service;

  const RecordButton({
    super.key,
    required this.onTap,
    required this.service,
  });

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _sizeAnim;
  late Animation<BorderRadius?> _borderAnim;
  late Animation<double> _pulseAnimIcon;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _sizeAnim = Tween<double>(begin: 30, end: 20).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
    _borderAnim = BorderRadiusTween(
      begin: BorderRadius.circular(30),
      end: BorderRadius.circular(8),
    ).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
    _pulseAnimIcon = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    widget.service.addListener(_onRecordingStateChanged);

    if (widget.service.isRecording) {
      _controller.forward();
    }
  }

  void _onRecordingStateChanged() {
    if (mounted) {
      setState(() {
        if (widget.service.isRecording) {
          _controller.forward();
        } else {
          _controller.reverse();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant RecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.service.isRecording != oldWidget.service.isRecording) {
      if (widget.service.isRecording) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_onRecordingStateChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isRecording = widget.service.isRecording;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 錄影時間顯示（只在錄影時顯示）
        if (isRecording)
          Positioned(
            top: (MediaQuery.of(context).size.height - 50) / 2,
            child: Container(
              // margin: const EdgeInsets.only(bottom: 8),
              // padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.6),
                borderRadius: BorderRadius.circular(20),
                // boxShadow: [
                //   BoxShadow(
                //     color: Colors.red.withOpacity(0.3),
                //     blurRadius: 8,
                //     offset: const Offset(0, 2),
                //   ),
                // ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 閃爍的錄影圓點
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      return Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(
                              0.3 + (0.7 * (1 - _pulseAnimIcon.value))
                          ),
                          shape: BoxShape.circle,
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.service.formattedTime,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        // 錄影按鈕本體
        GestureDetector(
          onTap: () {
            // 切換錄影狀態：如果正在錄影則停止，否則開始
            if (widget.service.isRecording) {
              widget.service.stopRecording();
            } else {
              widget.service.startRecording();
            }
            // // 如果有額外的 onTap 回調，也執行它（例如用於其他邏輯）
            // widget.onTap();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: isRecording
                  ? Colors.red.withOpacity(0.7)
                  : Colors.black.withOpacity(0.3),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: isRecording
                    ? Colors.red.shade900
                    : Colors.grey.shade700,
                width: 3,
              ),
              boxShadow: isRecording
                  ? [
                BoxShadow(
                  color: Colors.red.withOpacity(0.5),
                  blurRadius: 10,
                ),
              ]
                  : [],
            ),
            child: Center(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Container(
                    width: _sizeAnim.value,
                    height: _sizeAnim.value,
                    decoration: BoxDecoration(
                      color: Colors.red.shade900,
                      borderRadius: _borderAnim.value,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.red.shade900.withOpacity(
                            isRecording ? 0.7 : 0.3,
                          ),
                          blurRadius: isRecording ? 8 : 3,
                          spreadRadius: isRecording ? 2 : 0,
                        ),
                      ],
                    ),
                    child: isRecording
                        ? Icon(
                      Icons.videocam_off,
                      color: Colors.white,
                      size: _sizeAnim.value * 0.9,
                    )
                        : FadeTransition(
                      opacity: ReverseAnimation(_pulseAnimIcon),
                      child: Icon(
                        Icons.videocam,
                        color: Colors.white,
                        size: _sizeAnim.value * 0.9,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}