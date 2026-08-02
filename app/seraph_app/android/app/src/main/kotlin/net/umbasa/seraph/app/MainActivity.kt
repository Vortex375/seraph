package net.umbasa.seraph.app

import android.content.pm.PackageManager
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * The Android half of Gallery Mode's Local Source seam (ticket 15,
 * .scratch/gallery-mode/issues/15-local-source-scan-and-merged-gallery.md).
 *
 * MediaStore is queried ONLY in this file - everything above the
 * `seraph/local_media` channel, starting with `AndroidLocalSource` on the
 * Dart side, is platform-neutral and knows nothing about it.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "seraph/local_media"

    // MediaStore's own resolver.query is a blocking call; running it on the
    // platform thread would stall the whole Flutter UI for as long as the
    // cursor takes to build, which is exactly what "runs at app start
    // without a visible delay" (ticket 15) rules out.
    private val executor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "fullScan" -> handleFullScan(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleFullScan(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(
                this,
                android.Manifest.permission.READ_MEDIA_IMAGES
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            // Asking for the permission - with the explanation the user is
            // owed - is ticket 16's job. No grant simply means no device
            // photos here, the same shape as a platform with no Local
            // Source at all (ticket 15's platform-neutrality criterion),
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
