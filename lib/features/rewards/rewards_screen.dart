import 'package:flutter/material.dart';

import '../../core/widgets/placeholder_view.dart';

class RewardsScreen extends StatelessWidget {
  const RewardsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nagrody')),
      body: const PlaceholderView(
        icon: Icons.card_giftcard_outlined,
        text: 'Nagrody i vouchery — etap 8',
      ),
    );
  }
}
