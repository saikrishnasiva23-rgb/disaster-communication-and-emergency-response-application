import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';

/// The main SOS action: a large round button that fires only after being
/// held for [holdDuration], with a progress ring, so an accidental tap never
/// sends an SOS. Purely presentational: [onTriggered] runs the real flow.
class HoldSosButton extends StatefulWidget {
  const HoldSosButton({
    super.key,
    required this.onTriggered,
    this.busy = false,
    this.busyLabel = 'SENDING...',
    this.size = 188,
    this.holdDuration = const Duration(milliseconds: 1100),
  });

  final VoidCallback onTriggered;

  /// While true the button ignores presses (no duplicate submissions).
  final bool busy;
  final String busyLabel;
  final double size;
  final Duration holdDuration;

  @override
  State<HoldSosButton> createState() => _HoldSosButtonState();
}

class _HoldSosButtonState extends State<HoldSosButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: widget.holdDuration,
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        HapticFeedback.heavyImpact();
        if (!widget.busy) widget.onTriggered();
        _hold.reset();
      }
    });

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  void _start() {
    if (widget.busy) return;
    HapticFeedback.selectionClick();
    _hold.forward(from: 0);
  }

  void _cancel() {
    if (_hold.status != AnimationStatus.completed) _hold.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final track = Theme.of(context).colorScheme.outlineVariant;

    return Semantics(
      button: true,
      enabled: !widget.busy,
      label: 'Send SOS. Press and hold to send.',
      onLongPress: widget.busy ? null : widget.onTriggered,
      child: GestureDetector(
        onTapDown: (_) => _start(),
        onTapUp: (_) => _cancel(),
        onTapCancel: _cancel,
        child: AnimatedBuilder(
          animation: _hold,
          builder: (context, _) {
            final progress = _hold.value;
            return SizedBox(
              width: size,
              height: size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.brand.withValues(alpha: 0.10),
                    ),
                  ),
                  SizedBox(
                    width: size - 8,
                    height: size - 8,
                    child: CircularProgressIndicator(
                      value: widget.busy ? null : progress,
                      strokeWidth: 6,
                      backgroundColor: track,
                      valueColor: const AlwaysStoppedAnimation(AppColors.brandDark),
                    ),
                  ),
                  AnimatedScale(
                    scale: 1 - progress * 0.05,
                    duration: const Duration(milliseconds: 80),
                    child: Container(
                      width: size - 30,
                      height: size - 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.busy
                            ? AppColors.brand.withValues(alpha: 0.65)
                            : AppColors.brand,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.brand.withValues(alpha: 0.30),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.sos, color: Colors.white, size: 40),
                            const SizedBox(height: 4),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                widget.busy ? widget.busyLabel : 'SEND SOS',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ),
                            if (!widget.busy) ...[
                              const SizedBox(height: 2),
                              const FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  'Hold to send',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                    fontSize: 12.5,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
