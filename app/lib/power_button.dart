import 'package:flutter/material.dart';

import 'theme.dart';

/// The app's main control. Its color shows the state, and its label says what
/// tapping does.
class PowerButton extends StatelessWidget {
  const PowerButton({super.key, required this.colors, required this.label, required this.busy, required this.onTap});

  final StatusColors colors;
  final String label;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final duration = still ? Duration.zero : const Duration(milliseconds: 250);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: SizedBox.square(
        dimension: 208,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedContainer(
              duration: duration,
              decoration: BoxDecoration(color: colors.halo, shape: BoxShape.circle),
            ),
            if (busy)
              Positioned.fill(
                child: CircularProgressIndicator(strokeWidth: 4, color: colors.fill, value: still ? 1 : null),
              ),
            AnimatedContainer(
              duration: duration,
              width: 144,
              height: 144,
              decoration: BoxDecoration(color: colors.fill, shape: BoxShape.circle),
              child: Material(
                type: MaterialType.transparency,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTap,
                  child: Icon(busy ? Icons.close : Icons.power_settings_new, size: 56, color: colors.onFill),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
