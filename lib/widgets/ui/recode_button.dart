import 'package:flutter/material.dart';

class RecordButton extends StatefulWidget {
  final bool isRecording;
  final VoidCallback onTap;

  const RecordButton({
    super.key,
    required this.isRecording,
    required this.onTap,
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

    if (widget.isRecording) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant RecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording != oldWidget.isRecording) {
      if (widget.isRecording) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color: widget.isRecording
              ? Colors.red.withOpacity(0.7)
              : Colors.black.withOpacity(0.3),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: widget.isRecording ? Colors.red.shade900 : Colors.grey.shade700,
            width: 3,
          ),
          boxShadow: widget.isRecording
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
                        widget.isRecording ? 0.7 : 0.3,
                      ),
                      blurRadius: widget.isRecording ? 8 : 3,
                      spreadRadius: widget.isRecording ? 2 : 0,
                    ),
                  ],
                ),
                child: widget.isRecording
                    ? null
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
    );
  }
}