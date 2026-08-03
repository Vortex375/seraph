package net.umbasa.seraph.app

import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * The Android half of Gallery Mode's Local Source seam (ticket 15,
 * .scratch/gallery-mode/issues/15-local-source-scan-and-merged-gallery.md;
 * permission handling added by ticket 16,
 * .scratch/gallery-mode/issues/16-photo-permissions-and-partial-grant.md;
 * the incremental scan and content observer added by ticket 17,
 * .scratch/gallery-mode/issues/17-incremental-scan-and-observer.md).
 *
 * MediaStore, and the permission it sits behind, are queried ONLY in this
 * file - everything above the `seraph/local_media` channel, starting with
 * `AndroidLocalSource` on the Dart side, is platform-neutral and knows
 * nothing about either.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "seraph/local_media"

    // MediaStore's own resolver.query is a blocking call; running it on the
    // platform thread would stall the whole Flutter UI for as long as the
    // cursor takes to build, which is exactly what "runs at app start
    // without a visible delay" (ticket 15) rules out.
    private val executor = Executors.newSingleThreadExecutor()

    // The UI only ever has one "request access" affordance active at a
    // time, so one pending result is enough. Set while ActivityCompat.
    // requestPermissions() is awaiting the user's answer; resolved and
    // cleared by onRequestPermissionsResult.
    private var pendingPermissionResult: MethodChannel.Result? = null
    private val permissionRequestCode = 4201

    // Retained so the content observer (registered/unregistered with
    // onStart/onStop, below) can call back into Dart independently of
    // whatever method call is in flight.
    private var localMediaChannel: MethodChannel? = null

    // Non-null exactly while registered with the resolver - onStart/onStop
    // is what ticket 17 means by "registered and released with the app's
    // lifecycle": a ContentObserver left registered past onStop would keep
    // this Activity reachable from the resolver's observer list even while
    // backgrounded, which is the leak the ticket's criterion rules out.
    private var mediaObserver: ContentObserver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        localMediaChannel = channel
        channel.setMethodCallHandler { call, result ->
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
                else -> result.notImplemented()
            }
        }
    }

    override fun onStart() {
        super.onStart()
        registerMediaObserver()
    }

    override fun onStop() {
        unregisterMediaObserver()
        super.onStop()
    }

    /**
     * Ticket 17's content observer: registers for any change under the
     * images collection and, on each one, forwards a trigger-only
     * "onLocalMediaChanged" call to Dart - no arguments, no description of
     * what changed. The Dart side (`AndroidLocalSource.changes`,
     * `LocalScanService.watchForChanges`) decides what to do about it,
     * including debouncing a burst of these into one incremental scan; this
     * method's only job is to notice and forward.
     */
    private fun registerMediaObserver() {
        if (mediaObserver != null) {
            return
        }
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                // Fire-and-forget: this is a trigger only (ticket 17's
                // governing rule), never awaited and never allowed to block
                // on Dart doing anything with it.
                localMediaChannel?.invokeMethod("onLocalMediaChanged", null)
            }
        }
        mediaObserver = observer
        applicationContext.contentResolver.registerContentObserver(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            true,
            observer,
        )
    }

    private fun unregisterMediaObserver() {
        val observer = mediaObserver ?: return
        mediaObserver = null
        applicationContext.contentResolver.unregisterContentObserver(observer)
    }

    private fun hasFullImageAccess(): Boolean = ContextCompat.checkSelfPermission(
        this,
        android.Manifest.permission.READ_MEDIA_IMAGES
    ) == PackageManager.PERMISSION_GRANTED

    private fun hasPartialImageAccess(): Boolean = ContextCompat.checkSelfPermission(
        this,
        android.Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
    ) == PackageManager.PERMISSION_GRANTED

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
        pendingPermissionResult = result
        // Requesting both together is what makes Android 14 offer its
        // three-way "Allow all / Select photos / Don't allow" dialog on
        // first ask, and re-opens the selected-photos picker for more
        // choices when a partial grant already exists.
        ActivityCompat.requestPermissions(
            this,
            arrayOf(
                android.Manifest.permission.READ_MEDIA_IMAGES,
                android.Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            ),
            permissionRequestCode,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionRequestCode) {
            return
        }
        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null
        // Re-check via ContextCompat rather than trust grantResults' order -
        // it is simpler and it is exactly what permissionStatus() itself
        // reports, so the two channel calls can never disagree.
        result.success(currentPermissionStatus())
    }

    private fun openAppSettingsScreen() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", packageName, null)
        }
        startActivity(intent)
    }

    private fun handleFullScan(result: MethodChannel.Result) {
        if (!hasFullImageAccess() && !hasPartialImageAccess()) {
            // Asking for the permission - with the explanation the user is
            // owed - is ticket 16's job, done from the Dart side before this
            // channel is ever called this way. No grant simply means no
            // device photos here, the same shape as a platform with no
            // Local Source at all (ticket 15's platform-neutrality
            // criterion), never a thrown error.
            result.success(emptyList<Map<String, Any?>>())
            return
        }

        executor.execute {
            try {
                // Under a partial grant, MediaStore's own query already
                // restricts EXTERNAL_CONTENT_URI to the photos the user
                // selected - nothing here has to filter by hand.
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
     * Ticket 17's fast path: the same projection as [handleFullScan], but
     * restricted to rows MediaStore's own `GENERATION_MODIFIED` column
     * reports as newer than `since` - available unconditionally at this
     * app's minSdk (34, well past the API 30 floor for this column and for
     * [currentGeneration]), so there is no version gate to write. Reports
     * additions and modifications only; a deletion leaves no row to report a
     * generation for; noticing one is [handleFullScan]'s job alone.
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
                // Read AFTER the query: if a change lands between the two,
                // the resulting watermark is still <= the true current
                // generation, so that change is simply seen again (harmless
                // - upserts are idempotent) on the very next incremental
                // scan rather than silently skipped.
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
     * against the library at all, just a cheap platform call. Used to prime
     * the incremental scan's watermark right after a full scan, and to
     * report the new watermark after each incremental scan.
     */
    private fun currentGeneration(): Long =
        MediaStore.getGeneration(applicationContext, MediaStore.VOLUME_EXTERNAL)

    /**
     * The correctness anchor: one projection-only cursor over exactly the
     * six columns ticket 15 names - id, date taken, date modified, size,
     * relative path, display name. No joins, no per-row extra queries, so
     * this stays sub-second for 10,000 images. [sinceGeneration], when
     * given, adds a single indexed `GENERATION_MODIFIED > ?` filter for
     * ticket 17's incremental scan - still one query, never a per-row extra
     * lookup.
     */
    private fun queryMediaStore(sinceGeneration: Long? = null): List<Map<String, Any?>> {
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
        applicationContext.contentResolver.query(
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
                // Normalised to milliseconds here so the Dart side - and the
                // gallery mirror's capturedAt, which is seconds throughout -
                // never has to know MediaStore's column-by-column units.
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
}
