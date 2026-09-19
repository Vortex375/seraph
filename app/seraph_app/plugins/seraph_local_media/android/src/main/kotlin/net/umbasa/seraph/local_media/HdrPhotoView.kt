package net.umbasa.seraph.local_media

import android.content.Context
import android.graphics.ImageDecoder
import android.os.Handler
import android.os.Looper
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.widget.ImageView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.Executors

/**
 * The native half of the gallery photo viewer's HDR path
 * (`.scratch/hdr-photo-viewer/spec.md`): a plain Android `ImageView`, decoded
 * with `ImageDecoder` so an Ultra HDR JPEG's gain map survives - Flutter's
 * Android backend cannot draw one (flutter/flutter#127852), this view can.
 * Hosted under Classic Hybrid Composition; the composition mode is decided
 * entirely by which `PlatformViewsService.init*AndroidView` function Dart
 * calls (always `initExpensiveAndroidView` in production - see the spec's
 * "Composition and renderer"), not by this class.
 *
 * `creationParams` is the raw photo bytes (a Dart `Uint8List`, decoded by
 * `StandardMessageCodec` into a Kotlin `ByteArray`) - the same bytes the
 * fetch layer produced, with no second MediaStore round trip.
 *
 * The view owns its transform: pinch zoom to [MAX_SCALE] and clamped pan
 * live in the ImageView's own view properties (`scaleX`/`scaleY` about its
 * centre pivot, `translationX`/`translationY` carrying the focal-point
 * correction), mirroring the viewer's previous `InteractiveViewer` limits.
 * Flutter never applies a matrix to the platform view.
 *
 * Reports back to Dart over the per-view channel
 * `seraph/hdr_photo/view/<viewId>` (keyed by the platform view id so the
 * current page and a mid-swipe neighbour cannot cross-talk; never the shared
 * `seraph/local_media` channel, whose inbound handler slot is owned by
 * AndroidLocalSource's change listener):
 *
 *  - `zoomChanged` (bool) - entered/exited the zoomed state; Dart gates the
 *    pager's scroll physics on it and, through the surface's
 *    gestureRecognizers, whether a 1x horizontal drag pages instead.
 *  - `tap` - the user tapped the photo; toggles the viewer chrome.
 *  - `decodeError` - the bytes could not be decoded; Dart falls back to the
 *    existing Flutter error state instead of a blank view.
 */
class HdrPhotoImageView(
    context: Context,
    creationParams: Any?,
    messenger: BinaryMessenger,
    viewId: Int,
) : PlatformView {

    private val channel = MethodChannel(messenger, "seraph/hdr_photo/view/$viewId")
    private val main = Handler(Looper.getMainLooper())
    private val imageView = ImageView(context)

    // The decoded bitmap's width/height ratio, set when the decode lands.
    // The pan clamp needs it: the photo is drawn FIT-CENTER inside the
    // view, so the content rect is smaller than the view on at least one
    // axis, and clamping against the VIEW's size would let the photo be
    // dragged far past its own edge (exposing whatever sits behind it).
    private var bitmapAspect = 0f

    // One decode per view; nothing else ever queues on it, so a single
    // background thread is all the executor this needs.
    private val decoder = Executors.newSingleThreadExecutor()

    private var scale = 1f
    private var reportedZoomed = false
    private var lastX = 0f
    private var lastY = 0f

    init {
        imageView.scaleType = ImageView.ScaleType.FIT_CENTER
        val bytes = creationParams as? ByteArray
        if (bytes != null) {
            // Off the platform thread: a large photo's decode is long enough
            // to freeze input if done inline in create(). The bitmap lands
            // via [main]; a failure is reported, never swallowed.
            decoder.execute {
                val bitmap = try {
                    ImageDecoder.decodeBitmap(ImageDecoder.createSource(bytes))
                } catch (e: Exception) {
                    main.post { channel.invokeMethod("decodeError", null) }
                    null
                } ?: return@execute
                main.post {
                    imageView.setImageBitmap(bitmap)
                    // Used by the pan clamp: see [bitmapAspect].
                    bitmapAspect =
                        bitmap.width.toFloat() / bitmap.height.toFloat()
                }
            }
        }

        val taps = GestureDetector(
            context,
            object : GestureDetector.SimpleOnGestureListener() {
                override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                    channel.invokeMethod("tap", null)
                    return true
                }
            },
        )
        val scales = ScaleGestureDetector(
            context,
            object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
                override fun onScale(detector: ScaleGestureDetector): Boolean {
                    zoomTo(scale * detector.scaleFactor, detector.focusX, detector.focusY)
                    return true
                }
            },
        )

        imageView.setOnTouchListener { _, event ->
            taps.onTouchEvent(event)
            scales.onTouchEvent(event)
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE -> {
                    if (event.actionMasked == MotionEvent.ACTION_MOVE &&
                        event.pointerCount == 1 && scale > 1f
                    ) {
                        panBy(event.x - lastX, event.y - lastY)
                    }
                    lastX = event.x
                    lastY = event.y
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL ->
                    if (scale <= 1f) setTransform(1f, 0f, 0f)
            }
            // The Dart side decides which gestures reach this view at all
            // (its gestureRecognizers at 1x yield horizontal drags to the
            // pager); whatever arrives here is consumed here.
            true
        }
    }

    /** Scales to [target] keeping the photo point under (focusX, focusY). */
    private fun zoomTo(target: Float, focusX: Float, focusY: Float) {
        val s0 = scale
        val s1 = target.coerceIn(1f, MAX_SCALE)
        if (s1 == s0) {
            return
        }
        val cx = imageView.width / 2f
        val cy = imageView.height / 2f
        // Translation that keeps the focal point fixed across the scale
        // change; [setTransform] clamps it against the view's edges.
        val tx = focusX - cx - (s1 / s0) * (focusX - cx - imageView.translationX)
        val ty = focusY - cy - (s1 / s0) * (focusY - cy - imageView.translationY)
        setTransform(s1, tx, ty)
    }

    private fun panBy(dx: Float, dy: Float) {
        setTransform(scale, imageView.translationX + dx, imageView.translationY + dy)
    }

    /**
     * Applies scale about the view's centre plus a clamped translation.
     *
     * The photo is drawn FIT-CENTER, so the content rect is
     * `viewSize * min(1, viewAspect/bitmapAspect)`-ish - smaller than the
     * view on at least one axis. An axis can pan only once the SCALED
     * content exceeds the view on that axis (the behaviour every photo
     * viewer has): the free slack per axis is
     * `(scaledContentSize - viewSize) / 2`, split evenly either side of
     * centre, and zero pins the photo's centre to the view's. Back at 1x
     * every axis is slack-free, so the clamp IS fit-center again, and the
     * zoom report re-enables paging.
     */
    private fun setTransform(s: Float, tx: Float, ty: Float) {
        val clamped = s.coerceIn(1f, MAX_SCALE)
        val w = imageView.width.toFloat()
        val h = imageView.height.toFloat()
        var contentW = w
        var contentH = h
        if (bitmapAspect > 0f && w > 0f && h > 0f) {
            val viewAspect = w / h
            if (bitmapAspect > viewAspect) {
                // Photo wider than the view: it fills the width, the
                // HEIGHT is letterboxed.
                contentH = w / bitmapAspect
            } else {
                // Photo taller (or matching): fills the height, the WIDTH
                // is pillarboxed.
                contentW = h * bitmapAspect
            }
        }
        val maxTx = ((contentW * clamped - w) / 2f).coerceAtLeast(0f)
        val maxTy = ((contentH * clamped - h) / 2f).coerceAtLeast(0f)
        scale = clamped
        imageView.scaleX = clamped
        imageView.scaleY = clamped
        imageView.translationX = tx.coerceIn(-maxTx, maxTx)
        imageView.translationY = ty.coerceIn(-maxTy, maxTy)
        val zoomed = clamped > 1f
        if (zoomed != reportedZoomed) {
            reportedZoomed = zoomed
            channel.invokeMethod("zoomChanged", zoomed)
        }
    }

    override fun getView(): View = imageView

    override fun dispose() {
        decoder.shutdown()
    }

    companion object {
        /** The previous viewer's `InteractiveViewer` maxScale, kept for parity. */
        const val MAX_SCALE = 4f
    }
}

/**
 * Registered once, from [SeraphLocalMediaPlugin.onAttachedToEngine], under
 * viewType "seraph/hdr_photo". The factory carries the plugin's messenger so
 * each created view can report on its own keyed channel.
 */
class HdrPhotoViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        HdrPhotoImageView(context, args, messenger, viewId)
}
