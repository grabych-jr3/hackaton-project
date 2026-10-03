import 'package:flutter/material.dart';

import '../../core/widgets/placeholder_view.dart';

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mapa')),
      body: const PlaceholderView(
        icon: Icons.map_outlined,
        text: 'Mapa dostępności — etap 5',
      ),
    );
  }
}
