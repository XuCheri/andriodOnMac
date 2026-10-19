package chat.xucheri.androidonmac.receiver

import org.junit.Assert.*
import org.junit.Test

class VideoViewportTest {
    private fun assertClose(expected: Double, actual: Double) = assertEquals(expected, actual, 1e-8)
    private fun assertPoint(x: Double, y: Double, point: ContentPoint?) {
        assertNotNull(point); assertClose(x, point!!.x); assertClose(y, point.y)
    }

    @Test fun fitRejectsLetterboxBarsAndOutsideViewport() {
        val view = VideoViewport().apply { configure(1000, 1000, 1920, 1080) }
        assertClose(1000.0, view.baseWidth); assertClose(562.5, view.baseHeight)
        assertClose(0.0, view.left); assertClose(218.75, view.top)
        assertPoint(0.5, 0.5, view.point(500.0, 500.0))
        assertPoint(0.0, 0.0, view.point(0.0, 218.75))
        assertNull(view.point(500.0, 218.0)); assertNull(view.point(500.0, 782.0))
        assertNull(view.point(-1.0, 500.0)); assertNull(view.point(1001.0, 500.0))
    }

    @Test fun fitRejectsPillarboxBars() {
        val view = VideoViewport().apply { configure(1200, 600, 600, 1200) }
        assertClose(300.0, view.baseWidth); assertClose(600.0, view.baseHeight)
        assertClose(450.0, view.left); assertClose(0.0, view.top)
        assertNull(view.point(449.0, 300.0)); assertNull(view.point(751.0, 300.0))
        assertPoint(1.0, 1.0, view.point(750.0, 600.0))
    }

    @Test fun pinchPreservesItsAnchorWhileFocusMoves() {
        val view = VideoViewport().apply { configure(1000, 1000, 2000, 2000) }
        val anchor = view.point(250.0, 400.0)!!
        view.transform(2.0, 250.0, 400.0, 300.0, 450.0)
        assertClose(2.0, view.zoom); assertTrue(view.isZoomed)
        assertPoint(anchor.x, anchor.y, view.point(300.0, 450.0))
        assertClose(-200.0, view.left); assertClose(-350.0, view.top)
    }

    @Test fun zoomedCoordinateMappingUsesActualVisibleContent() {
        val view = VideoViewport().apply {
            configure(1000, 1000, 2000, 2000)
            transform(2.0, 500.0, 500.0, 500.0, 500.0)
        }
        assertPoint(0.25, 0.25, view.point(0.0, 0.0))
        assertPoint(0.75, 0.75, view.point(1000.0, 1000.0))
        assertNull(view.point(-1.0, 500.0)) // Content exists there, but viewport does not.
        assertPoint(0.25, 0.75, view.point(-100.0, 1200.0, clamp = true))
    }

    @Test fun panIsBoundedAndFitRecentersBothAxes() {
        val view = VideoViewport().apply { configure(1000, 1000, 2000, 2000); actualPixels() }
        view.pan(1e6, -1e6)
        assertClose(0.0, view.left); assertClose(-1000.0, view.top)
        view.pan(-1e6, 1e6)
        assertClose(-1000.0, view.left); assertClose(0.0, view.top)
        view.fit(); view.pan(100.0, -200.0)
        assertFalse(view.isZoomed); assertClose(0.0, view.left); assertClose(0.0, view.top)
        assertPoint(0.5, 0.5, view.point(500.0, 500.0))
    }

    @Test fun undersizedAxisStaysCenteredWhileOtherAxisPans() {
        val view = VideoViewport().apply {
            configure(1000, 1000, 2000, 1000)
            transform(1.5, 500.0, 500.0, 500.0, 500.0)
            pan(-100.0, -100.0)
        }
        assertClose(-350.0, view.left); assertClose(125.0, view.top)
    }

    @Test fun actualPixelsUsesEncodedPixelsAndCanExceedFourTimesFit() {
        val view = VideoViewport().apply { configure(400, 300, 4000, 3000); actualPixels() }
        assertClose(10.0, view.zoom)
        assertClose(4000.0, view.baseWidth * view.zoom)
        assertClose(3000.0, view.baseHeight * view.zoom)
        view.transform(5.0, 200.0, 150.0, 200.0, 150.0)
        assertClose(10.0, view.zoom)
    }

    @Test fun smallVideosNeverZoomBelowFitAndHaveFourTimesMaximum() {
        val view = VideoViewport().apply { configure(1000, 1000, 500, 500); actualPixels() }
        assertClose(1.0, view.zoom)
        view.transform(100.0, 500.0, 500.0, 500.0, 500.0); assertClose(4.0, view.zoom)
        view.transform(0.0001, 500.0, 500.0, 500.0, 500.0); assertClose(1.0, view.zoom)
    }

    @Test fun resizePreservesZoomAndNormalizedCenter() {
        val view = VideoViewport().apply { configure(1000, 1000, 3000, 3000) }
        view.transform(2.0, 500.0, 500.0, 500.0, 500.0); view.pan(-100.0, 100.0)
        val center = view.point(500.0, 500.0)!!
        view.configure(800, 1200, 3000, 3000)
        assertClose(2.0, view.zoom)
        assertPoint(center.x, center.y, view.point(400.0, 600.0))
        view.configure(800, 1200, 6000, 6000)
        assertClose(2.0, view.zoom)
        assertPoint(center.x, center.y, view.point(400.0, 600.0))
    }

    @Test fun missingSurfacePreservesViewAndDoesNotProduceCoordinates() {
        val view = VideoViewport().apply { configure(1000, 1000, 3000, 3000); actualPixels(); pan(-100.0, 100.0) }
        val center = view.point(500.0, 500.0)!!
        view.configure(0, 0, 3000, 3000)
        assertNull(view.point(0.0, 0.0)); assertNull(view.point(0.0, 0.0, clamp = true))
        assertClose(0.0, view.baseWidth); assertClose(0.0, view.left)
        view.configure(1000, 1000, 3000, 3000)
        assertClose(3.0, view.zoom); assertPoint(center.x, center.y, view.point(500.0, 500.0))
    }

    @Test fun invalidDimensionsAndNonFiniteGesturesAreHarmless() {
        val view = VideoViewport()
        view.configure(-1, 600, 1920, 0); view.actualPixels(); view.pan(1.0, 2.0)
        view.transform(2.0, 0.0, 0.0, 0.0, 0.0)
        assertNull(view.point(1.0, 1.0)); assertTrue(view.zoom.isFinite()); assertTrue(view.left.isFinite())
        view.configure(1000, 1000, 1000, 1000)
        for (factor in listOf(Double.NaN, Double.POSITIVE_INFINITY, 0.0, -1.0)) view.transform(factor, 500.0, 500.0, 500.0, 500.0)
        view.pan(Double.NaN, 0.0); view.transform(2.0, Double.NaN, 0.0, 0.0, 0.0)
        assertClose(1.0, view.zoom); assertClose(0.0, view.left)
        assertNull(view.point(Double.NaN, 0.0, clamp = true))
        assertNull(view.point(Double.POSITIVE_INFINITY, 0.0))
    }

    @Test fun clampedDragReleaseReachesContentEdgeAcrossBlackBars() {
        val view = VideoViewport().apply { configure(1000, 1000, 1920, 1080) }
        assertPoint(0.5, 0.0, view.point(500.0, -100.0, clamp = true))
        assertPoint(1.0, 1.0, view.point(1500.0, 1100.0, clamp = true))
    }

    @Test fun unilateralPinchHasPriorityOverCenterMotion() {
        val motion = TwoFingerMotion(8.0)
        motion.begin(100.0, 100.0, 200.0, 100.0, zoomed = false)
        val change = motion.move(100.0, 100.0, 230.0, 100.0)
        assertEquals(TwoFingerMotion.Kind.PINCH, change.kind)
        assertClose(1.3, change.factor); assertClose(15.0, change.dx)
        assertClose(150.0, change.previousX); assertClose(165.0, change.focusX)
    }

    @Test fun pinchRequiresSlopAndPreservesAccumulatedScale() {
        val motion = TwoFingerMotion(8.0)
        motion.begin(100.0, 100.0, 200.0, 100.0, zoomed = false)
        assertEquals(TwoFingerMotion.Kind.NONE, motion.move(100.0, 100.0, 205.0, 100.0).kind)
        val change = motion.move(100.0, 100.0, 210.0, 100.0)
        assertEquals(TwoFingerMotion.Kind.PINCH, change.kind)
        assertClose(1.1, change.factor); assertClose(5.0, change.dx)
        val next = motion.move(100.0, 100.0, 221.0, 100.0)
        assertClose(1.1, next.factor); assertClose(5.5, next.dx)
    }

    @Test fun fitScrollAccumulatesPendingMotionAndStaysScroll() {
        val motion = TwoFingerMotion(8.0)
        motion.begin(100.0, 100.0, 200.0, 100.0, zoomed = false)
        assertEquals(TwoFingerMotion.Kind.NONE, motion.move(100.0, 105.0, 200.0, 105.0).kind)
        val change = motion.move(100.0, 112.0, 200.0, 112.0)
        assertEquals(TwoFingerMotion.Kind.SCROLL, change.kind); assertClose(12.0, change.dy)
        val next = motion.move(90.0, 116.0, 230.0, 116.0)
        assertEquals(TwoFingerMotion.Kind.SCROLL, next.kind); assertClose(4.0, next.dy); assertClose(1.0, next.factor)
    }

    @Test fun zoomedGesturePansLocallyAndResetStartsFresh() {
        val motion = TwoFingerMotion(8.0)
        motion.begin(100.0, 100.0, 200.0, 100.0, zoomed = true)
        assertEquals(TwoFingerMotion.Kind.PAN, motion.move(112.0, 100.0, 212.0, 100.0).kind)
        motion.reset()
        assertEquals(TwoFingerMotion.Kind.NONE, motion.move(130.0, 100.0, 230.0, 100.0).kind)
        motion.begin(100.0, 100.0, 200.0, 100.0, zoomed = false)
        assertEquals(TwoFingerMotion.Kind.SCROLL, motion.move(112.0, 100.0, 212.0, 100.0).kind)
    }

    @Test fun smallOpposingMovementDoesNotBecomeScroll() {
        val motion = TwoFingerMotion(8.0)
        motion.begin(100.0, 100.0, 1100.0, 100.0, zoomed = false)
        // Center moves 10 px, but one finger is stationary and span changes only 2%.
        assertEquals(TwoFingerMotion.Kind.NONE, motion.move(100.0, 100.0, 1120.0, 100.0).kind)
        assertEquals(TwoFingerMotion.Kind.PINCH, motion.move(100.0, 100.0, 1150.0, 100.0).kind)
    }

    @Test fun pinchRemainsPinchWhenTheNextMovementIsOnlyTranslation() {
        val motion = TwoFingerMotion(8.0)
        motion.begin(100.0, 100.0, 200.0, 100.0, zoomed = false)
        motion.move(90.0, 100.0, 210.0, 100.0)
        val translated = motion.move(100.0, 120.0, 220.0, 120.0)
        assertEquals(TwoFingerMotion.Kind.PINCH, translated.kind)
        assertClose(1.0, translated.factor); assertClose(10.0, translated.dx); assertClose(20.0, translated.dy)
    }

    @Test fun invalidOrCoincidentPointersNeverEmitNonFiniteChanges() {
        val motion = TwoFingerMotion(Double.NaN)
        motion.begin(0.0, 0.0, 0.0, 0.0, zoomed = false)
        assertEquals(TwoFingerMotion.Kind.NONE, motion.move(0.0, 0.0, 10.0, 0.0).kind)
        motion.begin(0.0, 0.0, 100.0, 0.0, zoomed = false)
        val invalid = motion.move(Double.NaN, 1.0, 100.0, 1.0)
        assertEquals(TwoFingerMotion.Kind.NONE, invalid.kind)
        assertTrue(invalid.factor.isFinite()); assertTrue(invalid.focusX.isFinite())
        assertEquals(TwoFingerMotion.Kind.SCROLL, motion.move(0.0, 10.0, 100.0, 10.0).kind)
    }
}
