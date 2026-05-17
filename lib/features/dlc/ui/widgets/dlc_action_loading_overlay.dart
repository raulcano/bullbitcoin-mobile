import 'package:bb_mobile/generated/flutter_gen/assets.gen.dart';
import 'package:flutter/material.dart';
import 'package:gif/gif.dart';

/// Full-screen scrim with the Bull Bitcoin sync animation for blocking DLC actions.
class DlcActionLoadingOverlay extends StatelessWidget {
  const DlcActionLoadingOverlay({
    required this.visible,
    required this.child,
    super.key,
  });

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (visible)
          Positioned.fill(
            child: AbsorbPointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.35),
                child: Center(
                  child: Gif(
                    image: AssetImage(Assets.animations.bbSync.path),
                    autostart: Autostart.loop,
                    height: 80,
                    width: 80,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
