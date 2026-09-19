
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

T identity<T>(T x) => x;

/// Turns the screen to full brightness while a photo viewer is open, and back
/// to the system value when it closes. Android only; a no-op everywhere else.
///
/// This is the cheap, format-independent part of what makes photos "pop" in
/// Google Photos. The expensive part - Ultra HDR gainmap rendering - is not
/// reachable from Flutter on Android (flutter/flutter#127852), so this does
/// not attempt it.
///
/// Uses the existing `seraph/local_media` channel rather than a second one:
/// the name is a slight misnomer for a window call, but the handler is
/// already Activity-bound and registered on every engine. `defaultTargetPlatform`
/// rather than `dart:io`'s `Platform` so the web build still compiles.
Future<void> setBrightnessBoost(bool on) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await const MethodChannel('seraph/local_media')
        .invokeMethod<void>('setBrightnessBoost', on);
  } on PlatformException {
    // Brightness is a nicety; a device that refuses it still shows the photo.
  } on MissingPluginException {
    // Same, for a engine without the plugin (tests, headless).
  }
}

Future<T> until<T>(Rx<T> rx, bool Function(T) when) {
  if (when(rx.value)) {
    return Future.value(rx.value);
  }
  
  final completer = Completer<T>();
  StreamSubscription? sub;
  sub = rx.listen((v) {
    if (when(v)) {
      sub!.cancel();
      completer.complete(v);
    }
  });
  
  return completer.future;
}