import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Temporary body for screens that are implemented in later stages.
class PlaceholderView extends StatelessWidget {
  const PlaceholderView({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppColors.mint500),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
