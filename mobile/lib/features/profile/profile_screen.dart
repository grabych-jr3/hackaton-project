import 'package:flutter/material.dart';

import '../../core/widgets/placeholder_view.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      body: const PlaceholderView(
        icon: Icons.person_outline,
        text: 'Profil potrzeb — etap 3',
      ),
    );
  }
}
