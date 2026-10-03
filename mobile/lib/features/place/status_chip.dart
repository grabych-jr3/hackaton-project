import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'place_labels.dart';

/// Pill with icon + text. Text is always present so the status is not
/// conveyed by color alone.
class StatusChip extends StatelessWidget {
  const StatusChip(this.style, {super.key, this.dense = false});

  final StatusStyle style;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 3 : 5),
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: style.color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: dense ? 14 : 16, color: style.color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              style.label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: style.color,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "DANE PRZYKŁADOWE" badge required for sample data.
class DemoBadge extends StatelessWidget {
  const DemoBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return const StatusChip(
      StatusStyle('DANE PRZYKŁADOWE', Icons.science_outlined, AppColors.warn,
          AppColors.warnBg),
      dense: true,
    );
  }
}
