import 'dart:io';

import 'package:seraph_app/src/gallery/local/android_local_source.dart';
import 'package:seraph_app/src/gallery/local/local_media_item.dart';

/// Every native platform this app ships to. Only Android gets a real
/// [LocalSource] in this iteration (D7 in the design notes) - iOS and
/// desktop fall through to null, same as the web build, and the gallery
/// stays cloud-only there exactly as it was before ticket 15.
LocalSource? createLocalSource() =>
    Platform.isAndroid ? AndroidLocalSource() : null;
