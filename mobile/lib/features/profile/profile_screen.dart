import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/needs_profile.dart';
import '../../data/repositories/profile_repository.dart';
import 'preset_labels.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    if (profile == null) return const SizedBox.shrink();

    void save(NeedsProfile p) => ref.read(profileProvider.notifier).save(p);


    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          const _SectionTitle('Jak się poruszasz'),
          SegmentedButton<ProfilePreset>(
            segments: [
              for (final preset in selectablePresets)
                ButtonSegment(
                  value: preset,
                  icon: Icon(preset.icon),
                  label: Text(preset.shortLabel),
                  tooltip: preset.label,
                ),
            ],
            selected: {
              profile.preset == ProfilePreset.custom
                  ? ProfilePreset.wheelchair
                  : profile.preset,
            },
            showSelectedIcon: false,
            onSelectionChanged: (s) => save(s.first.defaults),
          ),
          const SizedBox(height: 8),
          Text(
            profile.preset.description,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('Udogodnienia'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.wc),
                  title: const Text('Potrzebuję dostępnej toalety'),
                  value: profile.needsToilet,
                  onChanged: (v) => save(profile.copyWith(needsToilet: v)),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.chair_outlined),
                  title: const Text('Miejsca do odpoczynku na trasie'),
                  value: profile.needsBenches,
                  onChanged: (v) => save(profile.copyWith(needsBenches: v)),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.groups_outlined),
                  title: const Text('Omijaj tłumy'),
                  value: profile.avoidCrowds,
                  onChanged: (v) => save(profile.copyWith(avoidCrowds: v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Nie pytamy o niepełnosprawność. Ustawienia zostają tylko na Twoim urządzeniu.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}
