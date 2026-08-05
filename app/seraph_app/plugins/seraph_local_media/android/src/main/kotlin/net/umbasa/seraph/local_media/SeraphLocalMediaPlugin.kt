package net.umbasa.seraph.local_media

import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.util.Size
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * The native half of Gallery Mode's Local Source seam, registered on every
 * FlutterEngine the app runs. See the package doc in
 * `lib/seraph_local_media.dart` for why this is a plugin (the short version:
 * background backup runs on a SEPARATE engine from MainActivity's, and the
 * `seraph/local_media` channel handler used to be registered only in
 * `MainActivity.configureFlutterEngine`, so `loadOriginal` from a headless
 * backup isolate threw `MissingPluginException` and every upload reported
 * `deviceFileUnavailable` even though the photo was perfectly readable from
 * the UI).
 *
 * Implements [FlutterPlugin] so `GeneratedPluginRegistrant` auto-adds it to
 * each engine Flutter creates for this app - MainActivity's, the
 * `flutter_foreground_task` engine (its own `FlutterEngine` per
 * `ForegroundTask.kt`), and the `workmanager` engine (`BackgroundWorker.kt`)
 * alike - with no per-engine wiring on the app's part. The first two
 * auto-register via the generated registrant the same way every pub plugin
 * does; the third does too, because `FlutterEngine(context)` runs that
 * registrant in its constructor.
 *
 * Implements [ActivityAware] so the two channel methods that genuinely need
 * an Activity - `requestPermission` (launches the system permission dialog)
 * and `openAppSettings` (launches the system app-details screen) - only act
 * when an Activity is attached. On a headless backup engine neither is ever
 * invoked (permission is requested only from the UI, on MainActivity's
 * engine, which IS activity-bound); a defensive call from a background
 * engine reports `denied` for `requestPermission` and is a no-op for
 * `openAppSettings`, rather than crashing on a null Activity. Every other
 * method (`fullScan`, `incrementalScan`, `currentGeneration`,
 * `permissionStatus`, `loadThumbnail`, `loadOriginal`) works off
 * `applicationContext`'s `ContentResolver` and needs no Activity at all -
 * which is exactly what makes the headless backup path work once the channel
 * has a handler on its engine.
 *
 * The Dart side of this channel lives in the host app's `AndroidLocalSource`
 * (`lib/src/gallery/local/android_local_source.dart`); this file is the
 * single native counterpart, moved here from `MainActivity.kt` wholesale so
 * the channel has ONE registration site (this plugin) rather than two that
 * could drift apart.
 */
class SeraphLocalMediaPlugin : FlutterPlugin, ActivityAware, PluginRegistry.RequestPermissionsResultListener {

    private val channelName = "seraph/local_media"

    // Background executor for the blocking MediaStore queries - same shape as
    // the original MainActivity implementation: never block the platform
    // thread on a cursor.
    private val executor = Executors.newSingleThreadExecutor()

    private var appContext: Context? = null
    private var activity: Activity? = null

    // Held across the `requestPermission` -> `onRequestPermissionsResult`
    // pair; resolved and cleared there. Activity-scoped state, so a second
    // request while one is pending reports `REQUEST_IN_PROGRESS` exactly as
    // the original MainActivity code did.
    private var pendingPermissionResult: MethodChannel.Result? = null
    private val permissionRequestCode = 4201

    private var channel: MethodChannel? = null
    private var localMediaChannelForObserver: MethodChannel? = null

    // Non-null exactly while registered with the resolver. The observer is
    // tied to the plugin's engine lifecycle (onAttachedToEngine/
    // onDetachedFromEngine) rather than MainActivity's onStart/onStop, since
    // a background engine has no Activity lifecycle to hook. Unregistered on
    // detach so a destroyed engine does not keep the resolver's observer list
    // alive.
    private var mediaObserver: ContentObserver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        val ch = MethodChannel(binding.binaryMessenger, channelName)
        channel = ch
        localMediaChannelForObserver = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "fullScan" -> handleFullScan(result)
                "incrementalScan" -> handleIncrementalScan(call, result)
                "currentGeneration" -> result.success(currentGeneration())
                "permissionStatus" -> result.success(currentPermissionStatus())
                "requestPermission" -> handleRequestPermission(result)
                "openAppSettings" -> {
                    openAppSettingsScreen()
                    result.success(null)
                }
                "loadThumbnail" -> handleLoadThumbnail(call, result)
                "loadOriginal" -> handleLoadOriginal(call, result)
                else -> result.notImplemented()
            }
        }
        registerMediaObserver()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        unregisterMediaObserver()
        channel?.setMethodCallHandler(null)
        channel = null
        localMediaChannelForObserver = null
        // A pending permission result's Activity callback can no longer fire
        // through this plugin once its engine is gone; resolve it as `denied`
        // rather than leaving the Dart side awaiting forever. This path is
        // unreachable in practice (the only `requestPermission` caller is
        // MainActivity's engine, which outlives any single plugin instance),
        // but defensive correctness here costs nothing.
        pendingPermissionResult?.success("denied")
        pendingPermissionResult = null
        appContext = null
    }

    // --- ActivityAware -----------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        // Config changes recreate the Activity; a new binding will re-attach.
        // Clear the reference but leave a pending permission result in place -
        // the new Activity's binding will still receive the result via the
        // RequestPermissionsResultListener added in onReattachedToActivityForConfigChanges.
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
        // No Activity to deliver a pending result through anymore.
        pendingPermissionResult?.success("denied")
        pendingPermissionResult = null
    }

    // --- PluginRegistry.RequestPermissionsResultListener ------------------

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != permissionRequestCode) {
            return false
        }
        val result = pendingPermissionResult ?: return true
        pendingPermissionResult = null
        // Re-check via ContextCompat rather than trust grantResults' order -
        // it is simpler and it is exactly what permissionStatus() itself
        // reports, so the two channel calls can never disagree.
        result.success(currentPermissionStatus())
        return true
    }

    // --- ContentObserver ---------------------------------------------------

    /**
     * The same trigger-only content observer the original MainActivity
     * registered: fires `onLocalMediaChanged` (no arguments) on any change
     * under the images collection. Registered from [onAttachedToEngine] rather
     * than onStart because a background engine has no Activity onStart/onStop
     * of its own; unregistered on detach so a destroyed engine does not leak
     * via the resolver's observer list.
     */
    private fun registerMediaObserver() {
        if (mediaObserver != null) {
            return
        }
        val ctx = appContext ?: return
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                // Fire-and-forget: this is a trigger only, never awaited and
                // never allowed to block on Dart doing anything with it.
                localMediaChannelForObserver?.invokeMethod("onLocalMediaChanged", null)
            }
        }
        mediaObserver = observer
        ctx.contentResolver.registerContentObserver(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            true,
            observer,
        )
    }

    private fun unregisterMediaObserver() {
        val observer = mediaObserver ?: return
        mediaObserver = null
        appContext?.contentResolver?.unregisterContentObserver(observer)
    }

    // --- Permission --------------------------------------------------------

    private fun hasFullImageAccess(): Boolean = appContext?.let {
        ContextCompat.checkSelfPermission(it, android.Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED
    } ?: false

    private fun hasPartialImageAccess(): Boolean = appContext?.let {
        ContextCompat.checkSelfPermission(it, android.Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) == PackageManager.PERMISSION_GRANTED
    } ?: false

    /**
     * "granted" (full library), "partial" (Android 14's user-selected
     * subset - READ_MEDIA_VISUAL_USER_SELECTED without READ_MEDIA_IMAGES),
     * or "denied" (neither). Android's own API cannot tell "never asked"
     * apart from "explicitly refused" - both read as not-granted - so
     * "denied" covers both; the Dart side does not need the distinction
     * (see LocalPermissionStatus.denied's doc comment).
     */
    private fun currentPermissionStatus(): String = when {
        hasFullImageAccess() -> "granted"
        hasPartialImageAccess() -> "partial"
        else -> "denied"
    }

    private fun handleRequestPermission(result: MethodChannel.Result) {
        if (pendingPermissionResult != null) {
            result.error(
                "REQUEST_IN_PROGRESS",
                "A permission request is already pending",
                null,
            )
            return
        }
        if (hasFullImageAccess()) {
            // Already fully granted - nothing to ask the user for.
            result.success("granted")
            return
        }
        // No Activity means this engine cannot show the system permission
        // dialog. This only happens for a headless backup engine, from which
        // `requestPermission` is never called (permission is requested only
        // from the UI, on MainActivity's engine, which IS activity-bound) -
        // but reporting `denied` here, rather than crashing on a null
        // Activity, is what keeps a defensive call from a background engine
        // behaving as the "no access" case `AndroidLocalSource` already
        // handles.
        val act = activity
        if (act == null) {
            result.success("denied")
            return
        }
        pendingPermissionResult = result
        // Requesting both together is what makes Android 14 offer its
        // three-way "Allow all / Select photos / Don't allow" dialog on
        // first ask, and re-opens the selected-photos picker for more
        // choices when a partial grant already exists.
        ActivityCompat.requestPermissions(
            act,
            arrayOf(
                android.Manifest.permission.READ_MEDIA_IMAGES,
                android.Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            ),
            permissionRequestCode,
        )
    }

    private fun openAppSettingsScreen() {
        val ctx = appContext ?: return
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", ctx.packageName, null)
            // STARTED_FROM_BACKGROUND is acceptable here - opening the app's
            // own settings page is not a sensitive background-start that
            // Android 10+ restricts, and adding the flag keeps the system UI
            // from blaming the app for an unexpected background activity
            // launch when the user reaches this from a notification.
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        ctx.startActivity(intent)
    }

    // --- Scan --------------------------------------------------------------

    private fun handleFullScan(result: MethodChannel.Result) {
        if (!hasFullImageAccess() && !hasPartialImageAccess()) {
            // Asking for the permission - with the explanation the user is
            // owed - is the Dart side's job, done before this channel is
            // ever called this way. No grant simply means no device photos
            // here, the same shape as a platform with no Local Source at all,
            // never a thrown error.
            result.success(emptyList<Map<String, Any?>>())
            return
        }

        executor.execute {
            try {
                val items = queryMediaStore()
                runOnUiThread { result.success(items) }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("SCAN_FAILED", e.message, null)
                }
            }
        }
    }

    /**
     * The fast path: the same projection as [handleFullScan], but restricted
     * to rows MediaStore's own `GENERATION_MODIFIED` column reports as newer
     * than `since`. Reports additions and modifications only; a deletion
     * leaves no row to report a generation for; noticing one is
     * [handleFullScan]'s job alone.
     */
    private fun handleIncrementalScan(call: MethodCall, result: MethodChannel.Result) {
        if (!hasFullImageAccess() && !hasPartialImageAccess()) {
            result.success(mapOf("items" to emptyList<Map<String, Any?>>(), "generation" to currentGeneration()))
            return
        }

        val since = (call.argument<Number>("since") ?: 0L).toLong()
        executor.execute {
            try {
                val items = queryMediaStore(sinceGeneration = since)
                val generation = currentGeneration()
                runOnUiThread {
                    result.success(mapOf("items" to items, "generation" to generation))
                }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("SCAN_FAILED", e.message, null)
                }
            }
        }
    }

    /**
     * MediaStore's own change counter for the external volume - no query
     * against the library at all, just a cheap platform call.
     */
    private fun currentGeneration(): Long =
        appContext?.let { MediaStore.getGeneration(it, MediaStore.VOLUME_EXTERNAL) } ?: 0L

    /**
     * The correctness anchor: one projection-only cursor over exactly the
     * six columns the scan needs - id, date taken, date modified, size,
     * relative path, display name. No joins, no per-row extra queries, so
     * this stays sub-second for 10,000 images.
     */
    private fun queryMediaStore(sinceGeneration: Long? = null): List<Map<String, Any?>> {
        val ctx = appContext ?: return emptyList()
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DATE_TAKEN,
            MediaStore.Images.Media.DATE_MODIFIED,
            MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.RELATIVE_PATH,
            MediaStore.Images.Media.DISPLAY_NAME,
        )
        val selection = if (sinceGeneration != null) {
            "${MediaStore.Images.Media.GENERATION_MODIFIED} > ?"
        } else {
            null
        }
        val selectionArgs = if (sinceGeneration != null) {
            arrayOf(sinceGeneration.toString())
        } else {
            null
        }

        val items = mutableListOf<Map<String, Any?>>()
        ctx.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            null,
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
            val takenCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_TAKEN)
            val modifiedCol =
                cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_MODIFIED)
            val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
            val relativePathCol =
                cursor.getColumnIndexOrThrow(MediaStore.Images.Media.RELATIVE_PATH)
            val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)

            while (cursor.moveToNext()) {
                // MediaStore's one well-known unit inconsistency: DATE_TAKEN
                // is epoch MILLISECONDS, DATE_MODIFIED is epoch SECONDS.
                // Normalised to milliseconds here so the Dart side never has
                // to know MediaStore's column-by-column units.
                val dateModifiedMillis = cursor.getLong(modifiedCol) * 1000L

                items.add(
                    mapOf(
                        "id" to cursor.getLong(idCol),
                        "dateTaken" to cursor.getLong(takenCol),
                        "dateModified" to dateModifiedMillis,
                        "size" to cursor.getLong(sizeCol),
                        "relativePath" to (cursor.getString(relativePathCol) ?: ""),
                        "displayName" to (cursor.getString(nameCol) ?: ""),
                    )
                )
            }
        }
        return items
    }

    // --- Load --------------------------------------------------------------

    /**
     * Re-resolves the content Uri for one photo from its durable local
     * identity - [relativePath] plus [displayName], exactly the pair the
     * mirror persists - rather than trusting a media-store row id carried
     * from an earlier scan. Returns null - never throws - when no row
     * currently matches, which covers both "never existed under this id" and
     * "deleted between scan and render" with the same, deliberately
     * unremarkable, outcome.
     */
    private fun resolveUri(relativePath: String, displayName: String): Uri? {
        val ctx = appContext ?: return null
        val projection = arrayOf(MediaStore.Images.Media._ID)
        val selection = "${MediaStore.Images.Media.RELATIVE_PATH} = ? AND " +
            "${MediaStore.Images.Media.DISPLAY_NAME} = ?"
        val selectionArgs = arrayOf(relativePath, displayName)
        ctx.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID))
                return ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
            }
        }
        return null
    }

    /**
     * Grid thumbnail: `ContentResolver.loadThumbnail` hands back a
     * size-appropriate bitmap using the system thumbnail cache. Every failure
     * mode reports `null` rather than a channel error: per-item, quiet, left
     * for the Dart side to turn into a placeholder for that one tile alone.
     */
    private fun handleLoadThumbnail(call: MethodCall, result: MethodChannel.Result) {
        if (!hasFullImageAccess() && !hasPartialImageAccess()) {
            result.success(null)
            return
        }
        val relativePath = call.argument<String>("relativePath") ?: ""
        val displayName = call.argument<String>("displayName") ?: ""
        val width = (call.argument<Number>("width") ?: 0).toInt().coerceAtLeast(1)
        val height = (call.argument<Number>("height") ?: 0).toInt().coerceAtLeast(1)

        executor.execute {
            try {
                val uri = resolveUri(relativePath, displayName)
                if (uri == null) {
                    runOnUiThread { result.success(null) }
                    return@execute
                }
                val ctx = appContext ?: run {
                    runOnUiThread { result.success(null) }
                    return@execute
                }
                val bitmap = ctx.contentResolver.loadThumbnail(
                    uri,
                    Size(width, height),
                    null,
                )
                val bytes = encodeJpeg(bitmap)
                runOnUiThread { result.success(bytes) }
            } catch (e: Exception) {
                // Deliberately not result.error(): every cause here (a
                // vanished file, a revoked grant, a file the decoder cannot
                // read) is a per-item quiet failure, not something the caller
                // should treat as exceptional.
                runOnUiThread { result.success(null) }
            }
        }
    }

    /**
     * Full-screen viewer / upload: the original file's bytes at full
     * resolution, read straight through the resolved content Uri. Same quiet
     * null-on-failure contract as [handleLoadThumbnail]. This is the method
     * the headless backup isolate calls via `loadOriginal`; it works on a
     * background engine precisely because the plugin (and therefore this
     * handler) is registered on that engine too.
     */
    private fun handleLoadOriginal(call: MethodCall, result: MethodChannel.Result) {
        if (!hasFullImageAccess() && !hasPartialImageAccess()) {
            result.success(null)
            return
        }
        val relativePath = call.argument<String>("relativePath") ?: ""
        val displayName = call.argument<String>("displayName") ?: ""

        executor.execute {
            try {
                val uri = resolveUri(relativePath, displayName)
                if (uri == null) {
                    runOnUiThread { result.success(null) }
                    return@execute
                }
                val ctx = appContext ?: run {
                    runOnUiThread { result.success(null) }
                    return@execute
                }
                val bytes = ctx.contentResolver.openInputStream(uri)?.use {
                    it.readBytes()
                }
                runOnUiThread { result.success(bytes) }
            } catch (e: Exception) {
                runOnUiThread { result.success(null) }
            }
        }
    }

    private fun encodeJpeg(bitmap: Bitmap): ByteArray {
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 90, stream)
        return stream.toByteArray()
    }

    private fun runOnUiThread(action: () -> Unit) {
        // MethodChannel.Result must be replied to on the platform thread; the
        // executor's background thread cannot. Handler(getMainLooper()) is
        // the same shape the original MainActivity used via runOnUiThread.
        Handler(Looper.getMainLooper()).post(action)
    }
}
