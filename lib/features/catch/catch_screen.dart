import 'package:flutter/material.dart';

import '../../core/widgets/placeholder_view.dart';

class CatchScreen extends StatelessWidget {
  const CatchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Złap')),
      body: const PlaceholderView(
        icon: Icons.camera_alt_outlined,
        text: 'Złap i zgłoś barierę — etap 8',
      ),
    );
  }
}
