import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/needs_profile.dart';

/// Keeps the needs profile on the device only (TZ, section 11).
class ProfileRepository {
  static const _key = 'needs_profile';

  Future<NeedsProfile?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    return NeedsProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(NeedsProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(profile.toJson()));
  }
}

final profileRepositoryProvider = Provider((ref) => ProfileRepository());

/// `null` means the user has not finished onboarding yet.
class ProfileNotifier extends AsyncNotifier<NeedsProfile?> {
  @override
  Future<NeedsProfile?> build() => ref.read(profileRepositoryProvider).load();

  Future<void> save(NeedsProfile profile) async {
    state = AsyncData(profile);
    await ref.read(profileRepositoryProvider).save(profile);
  }
}

final profileProvider =
    AsyncNotifierProvider<ProfileNotifier, NeedsProfile?>(ProfileNotifier.new);
