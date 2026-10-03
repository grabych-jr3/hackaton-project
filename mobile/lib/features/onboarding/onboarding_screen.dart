import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/needs_profile.dart';
import '../../data/repositories/profile_repository.dart';
import '../profile/preset_labels.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  ProfilePreset _selected = ProfilePreset.wheelchair;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
          children: [
            const Icon(Icons.explore_outlined, size: 48, color: AppColors.mint500),
            const SizedBox(height: 16),
            Semantics(
              header: true,
              child: Text(
                'Kraków bez barier',
                style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Wybierz, jak się poruszasz. Dopasujemy miejsca i trasy do Twoich potrzeb.',
              style: text.bodyLarge?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: 24),
            for (final preset in ProfilePreset.values) ...[
              _PresetCard(
                preset: preset,
                selected: preset == _selected,
                onTap: () => setState(() => _selected = preset),
              ),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 4),
            const _PrivacyNote(),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () =>
                  ref.read(profileProvider.notifier).save(_selected.defaults),
              child: const Text('Dalej'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final ProfilePreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      child: Material(
        color: selected ? AppColors.mint100 : AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(preset.icon, size: 32, color: AppColors.primary),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        preset.label,
                        style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        preset.description,
                        style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
                Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: selected ? AppColors.primary : AppColors.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.lock_outline, size: 20, color: AppColors.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Nie pytamy o niepełnosprawność. Ustawienia zostają tylko na Twoim urządzeniu.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textMuted),
          ),
        ),
      ],
    );
  }
}
