import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../theme/app_colors.dart';

/// Shown in API mode when the backend is unreachable and local data is used.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  static const text = 'Serwer niedostępny — pokazujemy dane lokalne';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(serverUnavailableProvider)) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: Material(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 18, color: AppColors.textMuted),
              SizedBox(width: 8),
              Flexible(child: Text(text)),
            ],
          ),
        ),
      ),
    );
  }
}
