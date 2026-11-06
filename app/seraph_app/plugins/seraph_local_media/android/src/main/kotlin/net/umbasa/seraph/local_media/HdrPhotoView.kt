package net.umbasa.seraph.local_media

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.ImageDecoder
import android.os.Handler
import android.os.Looper
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.ViewConfiguration
import android.view.animation.DecelerateInterpolator
import android.widget.ImageView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.Executors
import kotlin.math.hypot

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
 * The view owns its transform: pinch zoom to [MAX_SCALE], clamped pan, and
 * double-tap zoom all live in the ImageView's own view properties
 * (`scaleX`/`scaleY` about its centre pivot, `translationX`/`translationY`
 * carrying the focal-point correction), mirroring the viewer's previous
 * `InteractiveViewer` limits plus the standard double-tap: a clean
 * double-tap animates between fit-center and [DOUBLE_TAP_SCALE] about the
 * tap point, and a double-tap followed by a vertical drag zooms
 * continuously, measured from the tap point (the Google Maps convention:
 * dragging down zooms in, dragging up zooms out). Tap detection itself is
 * the framework's [GestureDetector] double-tap machinery: a single tap is
 * reported only after the double-tap timeout elapses, so a double-tap never
 * also toggles the chrome. Flutter never applies a matrix to the platform
 * view.
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

    // Double-tap-drag zoom state, armed by the GestureDetector's
    // onDoubleTapEvent on the second tap's down.
    private var doubleTapDragArmed = false
    private var doubleTapDragMoved = false
    private var doubleTapDragStartScale = 1f
    private var doubleTapDragStartY = 0f
    private var doubleTapDragFocalX = 0f
    private var doubleTapDragFocalY = 0f

    // The running double-tap zoom-toggle animation, if any - cancelled when a
    // new gesture starts.
    private var zoomAnimation: ValueAnimator? = null

    // The distance the second tap of a double-tap may wander before it counts
    // as a drag rather than a clean double-tap.
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop

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

                // onDoubleTap itself fires on the second tap's DOWN - too
                // early to toggle the zoom, since the second tap may turn
                // into a drag. The whole double-tap handling lives here, in
                // onDoubleTapEvent, which receives the second tap's
                // down/move/up stream (with the detector's own scroll
                // detection suppressed while the double-tap is in progress).
                override fun onDoubleTapEvent(e: MotionEvent): Boolean {
                    when (e.actionMasked) {
                        MotionEvent.ACTION_DOWN ->
                            // The second tap of a double-tap: arm drag-to-zoom
                            // about this point. A clean release toggles the
                            // zoom (UP below); a drag zooms continuously.
                            armDoubleTapDrag(e.x, e.y)
                        MotionEvent.ACTION_MOVE ->
                            if (e.pointerCount == 1) dragZoom(e.x, e.y)
                        MotionEvent.ACTION_UP -> {
                            if (doubleTapDragArmed && !doubleTapDragMoved) {
                                animateZoomToggle(
                                    doubleTapDragFocalX,
                                    doubleTapDragFocalY,
                                )
                            }
                            disarmDoubleTapDrag()
                        }
                    }
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
                MotionEvent.ACTION_DOWN -> {
                    // A new gesture interrupts a running double-tap zoom
                    // animation. (The drag state is NOT reset here: a second
                    // tap's down arms it in onDoubleTapEvent just above.)
                    zoomAnimation?.cancel()
                    lastX = event.x
                    lastY = event.y
                }
                MotionEvent.ACTION_POINTER_DOWN ->
                    // A pinch takes over from any tap/drag state (the
                    // GestureDetector cancels its own tap state here too).
                    disarmDoubleTapDrag()
                MotionEvent.ACTION_MOVE -> {
                    if (event.pointerCount == 1 &&
                        scale > 1f &&
                        !doubleTapDragArmed
                    ) {
                        panBy(event.x - lastX, event.y - lastY)
                    }
                    lastX = event.x
                    lastY = event.y
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    disarmDoubleTapDrag()
                    if (scale <= 1f) setTransform(1f, 0f, 0f)
                }
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

    /** Arms a double-tap-drag zoom about (x, y) at the current scale. */
    private fun armDoubleTapDrag(x: Float, y: Float) {
        doubleTapDragArmed = true
        doubleTapDragMoved = false
        doubleTapDragStartScale = scale
        doubleTapDragStartY = y
        doubleTapDragFocalX = x
        doubleTapDragFocalY = y
    }

    /**
     * Applies one move of a double-tap-drag: once the finger has wandered
     * past the touch slop, the drag zooms continuously about the armed focal
     * point, measured from the tap point - down zooms in, up zooms out
     * (the Google Maps convention) - until the finger lifts.
     */
    private fun dragZoom(x: Float, y: Float) {
        if (!doubleTapDragMoved &&
            hypot(x - doubleTapDragFocalX, y - doubleTapDragFocalY) > touchSlop
        ) {
            doubleTapDragMoved = true
        }
        if (doubleTapDragMoved) {
            zoomTo(
                doubleTapDragScale(
                    doubleTapDragStartScale,
                    doubleTapDragStartY,
                    y,
                    imageView.height.toFloat(),
                ),
                doubleTapDragFocalX,
                doubleTapDragFocalY,
            )
        }
    }

    private fun disarmDoubleTapDrag() {
        doubleTapDragArmed = false
        doubleTapDragMoved = false
    }

    /**
     * Animates a clean double-tap between fit-center and [DOUBLE_TAP_SCALE],
     * keeping the tapped point fixed. Reuses [zoomTo]'s focal-point math per
     * frame; [setTransform] reports the zoom crossing to Dart as usual.
     */
    private fun animateZoomToggle(focalX: Float, focalY: Float) {
        val target = if (scale > 1f) 1f else DOUBLE_TAP_SCALE
        val start = scale
        if (start == target) {
            return
        }
        zoomAnimation?.cancel()
        val animator = ValueAnimator.ofFloat(0f, 1f)
        animator.duration = DOUBLE_TAP_ANIMATION_MS
        animator.interpolator = DecelerateInterpolator()
        animator.addUpdateListener { animation ->
            val t = animation.animatedValue as Float
            zoomTo(start + (target - start) * t, focalX, focalY)
        }
        zoomAnimation = animator
        animator.start()
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

        /** The scale a clean double-tap zooms to, about the tap point. */
        const val DOUBLE_TAP_SCALE = 2f

        /** The double-tap zoom-toggle animation length, in milliseconds. */
        const val DOUBLE_TAP_ANIMATION_MS = 250L

        /**
         * The fraction of the view height a double-tap-drag must cover to
         * double the scale: a drag down by this much zooms in 2x, a drag up by
         * the same zooms out 2x. Tuned for device feel.
         */
        const val DRAG_ZOOM_VIEW_FRACTION = 0.25f

        /**
         * The scale a double-tap-drag reaches: [startScale] scaled by the
         * vertical drag from [startY] to [y] - the Google Maps convention:
         * dragging DOWN from the tap point zooms in, dragging UP zooms out.
         * The drag is measured from [startY], the y where the second tap
         * landed - never from the view's centre - so the direction is the same
         * no matter where on the photo the double-tap happened. The result is
         * clamped to [1, MAX_SCALE]; at 1x the clamp IS fit-center, and the
         * zoom report re-enables the pager. Pure: the gesture state machine
         * lives in the view, this is the only non-trivial math, unit-tested
         * on the JVM.
         */
        fun doubleTapDragScale(
            startScale: Float,
            startY: Float,
            y: Float,
            viewHeight: Float,
        ): Float {
            val range = viewHeight * DRAG_ZOOM_VIEW_FRACTION
            if (range <= 0f) {
                return startScale.coerceIn(1f, MAX_SCALE)
            }
            val factor = 1f + (y - startY) / range
            return (startScale * factor).coerceIn(1f, MAX_SCALE)
        }
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
