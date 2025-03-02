import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'file_browser/file_service.dart';

class AppProviders extends StatelessWidget {

  const AppProviders({
    super.key,
    required this.fileService,
    required this.child
  });

  final FileService fileService;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider.value(value: fileService)
      ],
      child: child,
    );
  }
}