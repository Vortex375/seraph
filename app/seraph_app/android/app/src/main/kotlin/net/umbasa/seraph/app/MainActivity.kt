package net.umbasa.seraph.app

import com.ryanheise.audioservice.AudioServiceActivity

/**
 * The app's launcher Activity. Extends [AudioServiceActivity] rather than
 * `FlutterActivity` directly: audio_service keeps its own long-lived
 * `FlutterEngine` (via `AudioServicePlugin.getFlutterEngine`) so playback
 * survives the Activity being destroyed, and [AudioServiceActivity] is the
 * plugin's documented seam for supplying that engine. AndroidManifest.xml's
 * launcher activity must be this class (`.MainActivity`), not
 * `com.ryanheise.audioservice.AudioServiceActivity` directly, so this file
 * remains the type the manifest names.
 *
 * Gallery Mode's `seraph/local_media` channel handler used to live here, but
 * has moved to the `seraph_local_media` FlutterPlugin
 * (`plugins/seraph_local_media/android/.../SeraphLocalMediaPlugin.kt`). That
 * plugin is auto-registered on EVERY FlutterEngine by
 * `GeneratedPluginRegistrant` - including the separate engines
 * `flutter_foreground_task` and `workmanager` create for headless background
 * backup, which never ran `MainActivity.configureFlutterEngine` and
 * therefore had no handler for `loadOriginal` (the cause of every backup
 * upload reporting "could not read this photo from the device" even though
 * the photo was perfectly readable from the UI). `FlutterActivity`'s own
 * `configureFlutterEngine` runs the generated registrant (and thus this
 * plugin) on MainActivity's engine, so the channel is registered here too
 * with no override needed - which is why this class now has none.
 */
class MainActivity : AudioServiceActivity()
