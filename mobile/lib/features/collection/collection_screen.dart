import 'package:flutter/material.dart';

import '../../core/widgets/placeholder_view.dart';

class CollectionScreen extends StatelessWidget {
  const CollectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kolekcja')),
      body: const PlaceholderView(
        icon: Icons.grid_view_outlined,
        text: 'Kolekcja stworków — etap 8',
      ),
    );
  }
}
