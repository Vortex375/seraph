package net.umbasa.seraph.local_media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM unit tests for [HdrPhotoImageView.doubleTapDragScale] - the only
 * non-trivial custom math in the HDR photo view's gesture handling (`.scratch/
 * hdr-photo-viewer/issues/06`). The tap/double-tap detection itself is the
 * framework's GestureDetector; the view's gesture wiring is device-gated.
 *
 * The mapping follows the Google Maps double-tap-drag convention: dragging
 * DOWN from the tap point zooms in, dragging UP zooms out, and the drag is
 * measured from the tap point (the second tap's y), never from the view's
 * centre - so the direction is the same no matter where the double-tap
 * happened.
 */
class HdrPhotoViewTest {

    @Test
    fun `zero drag keeps the start scale`() {
        assertEquals(
            2f,
            HdrPhotoImageView.doubleTapDragScale(2f, 100f, 100f, 800f),
            0.0001f,
        )
    }

    @Test
    fun `dragging down zooms in proportionally`() {
        // A drag of DRAG_ZOOM_VIEW_FRACTION (a quarter) of the view height
        // doubles the scale: 800px view, 200px down from 500 -> 700.
        assertEquals(
            4f,
            HdrPhotoImageView.doubleTapDragScale(2f, 500f, 700f, 800f),
            0.0001f,
        )
    }

    @Test
    fun `dragging up zooms out proportionally`() {
        // The mirror image: 200px up from 500 -> 300 halves 2x to 1x.
        assertEquals(
            1f,
            HdrPhotoImageView.doubleTapDragScale(2f, 500f, 300f, 800f),
            0.0001f,
        )
    }

    @Test
    fun `the scale is clamped at fit-center`() {
        // Dragging up at 1x stays at 1x (the clamp IS fit-center, and the
        // zoom report re-enables the pager).
        assertEquals(
            1f,
            HdrPhotoImageView.doubleTapDragScale(1f, 500f, 100f, 800f),
            0.0001f,
        )
    }

    @Test
    fun `the scale is clamped at max scale`() {
        assertEquals(
            HdrPhotoImageView.MAX_SCALE,
            HdrPhotoImageView.doubleTapDragScale(4f, 500f, 900f, 800f),
            0.0001f,
        )
    }

    @Test
    fun `a degenerate view height keeps the start scale`() {
        // A not-yet-laid-out view (height 0) must not divide by zero or zoom.
        assertEquals(
            2f,
            HdrPhotoImageView.doubleTapDragScale(2f, 100f, 300f, 0f),
            0.0001f,
        )
    }

    @Test
    fun `the drag is measured from the tap point, not the view centre`() {
        // A tap near the top of an 800px view (startY = 100, centre = 400),
        // dragged 200px down: 2x. A centre-relative mapping would compute
        // (300 - 400) < 0 and clamp to fit-center - this test pins the
        // tap-relative origin.
        assertEquals(
            2f,
            HdrPhotoImageView.doubleTapDragScale(1f, 100f, 300f, 800f),
            0.0001f,
        )
    }

    @Test
    fun `the mapping is monotonic in the drag distance`() {
        // Dragging down from 1x zooms in continuously: every further step
        // down never zooms back out.
        var previous = 0f
        for (draggedDown in 0..400 step 10) {
            val scale = HdrPhotoImageView.doubleTapDragScale(
                1f,
                500f,
                (500 + draggedDown).toFloat(),
                800f,
            )
            assertTrue("scale $scale should not decrease below $previous", scale >= previous)
            previous = scale
        }
    }
}
