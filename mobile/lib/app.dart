import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme/app_theme.dart';
import 'core/widgets/phone_frame.dart';
import 'data/repositories/profile_repository.dart';
import 'features/catch/catch_screen.dart';
import 'features/collection/collection_screen.dart';
import 'features/map/map_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/place/place_detail_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/rewards/rewards_screen.dart';
import 'features/shell/home_shell.dart';

GoRouter _buildRouter() => GoRouter(
  initialLocation: '/map',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => HomeShell(navigationShell: shell),
      branches: [
        _branch('/map', const MapScreen()),
        _branch('/rewards', const RewardsScreen()),
        _branch('/catch', const CatchScreen()),
        _branch('/collection', const CollectionScreen()),
        _branch('/profile', const ProfileScreen()),
      ],
    ),
    GoRoute(
      path: '/place/:id',
      builder: (context, state) =>
          PlaceDetailScreen(placeId: state.pathParameters['id']!),
    ),
  ],
);

StatefulShellBranch _branch(String path, Widget screen) => StatefulShellBranch(
      routes: [GoRoute(path: path, builder: (context, state) => screen)],
    );

class KrakowBezBarierApp extends StatefulWidget {
  const KrakowBezBarierApp({super.key});

  @override
  State<KrakowBezBarierApp> createState() => _KrakowBezBarierAppState();
}

class _KrakowBezBarierAppState extends State<KrakowBezBarierApp> {
  late final _router = _buildRouter();

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Kraków bez barier',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      routerConfig: _router,
      builder: (context, child) => PhoneFrame(child: _ProfileGate(child: child!)),
    );
  }
}

/// Shows onboarding until the user picks a needs profile.
class _ProfileGate extends ConsumerWidget {
  const _ProfileGate({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(profileProvider).when(
          data: (profile) => profile == null ? const OnboardingScreen() : child,
          loading: () => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => const OnboardingScreen(),
        );
  }
}
