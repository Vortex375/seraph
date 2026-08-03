package net.umbasa.seraph.app

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * The Android half of Gallery Mode's Local Source seam (ticket 15,
 * .scratch/gallery-mode/issues/15-local-source-scan-and-merged-gallery.md;
 * permission handling added by ticket 16,
 * .scratch/gallery-mode/issues/16-photo-permissions-and-partial-grant.md).
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "fullScan" -> handleFullScan(result)
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
     * The correctness anchor: one projection-only cursor over exactly the
     * six columns ticket 15 names - id, date taken, date modified, size,
     * relative path, display name. No joins, no per-row extra queries, so
     * this stays sub-second for 10,000 images.
     */
    private fun queryMediaStore(): List<Map<String, Any?>> {
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DATE_TAKEN,
            MediaStore.Images.Media.DATE_MODIFIED,
            MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.RELATIVE_PATH,
            MediaStore.Images.Media.DISPLAY_NAME,
        )

        val items = mutableListOf<Map<String, Any?>>()
        applicationContext.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection,
            null,
            null,
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
