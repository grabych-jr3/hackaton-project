import 'package:flutter/material.dart';

import '../place/places_list.dart';

/// Stage 5 adds the map; until then the tab shows the text list of places.
class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Miejsca')),
      body: const PlacesList(),
    );
  }
}
