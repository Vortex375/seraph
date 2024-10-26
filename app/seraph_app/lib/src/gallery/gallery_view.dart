
import 'package:flutter/material.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';

class GalleryView extends StatelessWidget {

  static const routeName = '/gallery';

  const GalleryView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: seraphAppBar(context, 'Gallery', routeName, []),
      body: const Text('Gallery mode coming soon')
    );
  }

}