import 'dart:io' as io;

import 'package:flutter/foundation.dart' show kIsWeb;

/// True on a real Android device; false on the desktop test host and on
/// every non-Android platform.
bool get isAndroidDevice => !kIsWeb && io.Platform.isAndroid;
