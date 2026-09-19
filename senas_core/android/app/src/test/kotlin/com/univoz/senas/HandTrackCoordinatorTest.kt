package com.univoz.senas

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HandTrackCoordinatorTest {
    private fun hand(x: Double, y: Double = .55, direction: Double = 1.0): DoubleArray =
        DoubleArray(63).also { points ->
            fun point(index: Int, px: Double, py: Double) {
                points[index * 3] = px
                points[index * 3 + 1] = py
            }
            for (index in 0 until 21) point(index, x, y)
            point(1, x + .06 * direction, y + .01)
            point(5, x + .04 * direction, y - .02)
            point(9, x, y - .08)
            point(17, x - .04 * direction, y - .02)
        }

    @Test
    fun palmOrientationUsesCmcToChooseRadialSign() {
        val tracker = HandTrackCoordinator()
        val points = hand(.5, direction = -1.0).also {
            it[1 * 3] = .56
            it[1 * 3 + 1] = .56
        }
        val orientation = tracker.palmOrientation(points)
        assertNotNull(orientation)
        assertTrue(orientation!![0] > 0.0)
    }

    @Test
    fun sharedContactFixtureKeepsIdentityAcrossDetectionOrderChanges() {
        val tracker = HandTrackCoordinator()
        val rows = javaClass.classLoader!!.getResourceAsStream("hand_tracking.tsv")!!
            .bufferedReader().readLines()
            .filterNot { it.startsWith("#") || it.isBlank() }
        var contactSeen = false
        rows.forEach { row ->
            val columns = row.split(Regex("\\s+"))
            val t = columns[0].toLong()
            val leftX = columns[1].toDouble()
            val rightX = columns[2].toDouble()
            val flipped = columns[4] == "flipped"
            val left = HandTrackCoordinator.Candidate(
                hand(leftX), if (flipped) "right" else "left", .9)
            val right = HandTrackCoordinator.Candidate(
                hand(rightX), if (flipped) "left" else "right", .9)
            val detections = if (columns[3] == "LR") listOf(left, right)
                else listOf(right, left)
            val result = tracker.update(
                detections,
                HandTrackCoordinator.PoseHint(.68, .55, .32, .55, .4),
                t,
            )
            assertEquals(leftX, result.left.detected!!.get(0), 1e-9)
            assertEquals(rightX, result.right.detected!!.get(0), 1e-9)
            contactSeen = contactSeen || result.contact
        }
        assertTrue(contactSeen)
    }

    @Test
    fun oneDetectionNeverDuplicatesRawLandmarksAndPredictsOnlyRender() {
        val tracker = HandTrackCoordinator()
        val pose = HandTrackCoordinator.PoseHint(.68, .55, .32, .55, .4)
        tracker.update(listOf(
            HandTrackCoordinator.Candidate(hand(.68), "left", 1.0),
            HandTrackCoordinator.Candidate(hand(.32), "right", 1.0),
        ), pose, 0)
        val result = tracker.update(listOf(
            HandTrackCoordinator.Candidate(hand(.66), "left", 1.0),
        ), pose, 200)
        assertNotNull(result.left.detected)
        assertNull(result.right.detected)
        assertEquals("OCCLUDED", result.right.state)
        assertNotNull(result.right.render)
    }

    @Test
    fun explicitContradictoryHandLabelIsReportedWithoutMovingOtherTrack() {
        val tracker = HandTrackCoordinator()
        val pose = HandTrackCoordinator.PoseHint(.68, .55, .32, .55, .4)
        tracker.update(listOf(
            HandTrackCoordinator.Candidate(hand(.68), "left", .9),
        ), pose, 0)
        val result = tracker.update(listOf(
            HandTrackCoordinator.Candidate(hand(.67), "right", .9),
        ), pose, 33)
        assertEquals(.67, result.left.detected!!.get(0), 1e-9)
        assertTrue(result.errors.any {
            it["code"] == "hand_identity_swap" && it["side"] == "left"
        })
    }

    @Test
    fun poseArmChainLockPreventsCrossSideAssignment() {
        val tracker = HandTrackCoordinator()
        val pose = HandTrackCoordinator.PoseHint(.68, .55, .32, .55, .4)
        tracker.update(listOf(
            HandTrackCoordinator.Candidate(hand(.68), "left", .9),
            HandTrackCoordinator.Candidate(hand(.32), "right", .9),
        ), pose, 0)
        val result = tracker.update(listOf(
            HandTrackCoordinator.Candidate(hand(.32), "right", .9, sideLocked = true),
            HandTrackCoordinator.Candidate(hand(.68), "left", .9, sideLocked = true),
        ), pose, 33)
        assertEquals(.68, result.left.detected!!.get(0), 1e-9)
        assertEquals(.32, result.right.detected!!.get(0), 1e-9)
    }

    @Test
    fun rapidCrossingHoldsIdentityThroughTransientLockedSideInversion() {
        val tracker = HandTrackCoordinator()
        val pose = HandTrackCoordinator.PoseHint(.68, .55, .32, .55, .4)
        tracker.update(listOf(
            HandTrackCoordinator.Candidate(hand(.68), "left", .95),
            HandTrackCoordinator.Candidate(hand(.32), "right", .95),
        ), pose, 0)
        val result = tracker.update(listOf(
            // A transient pose-chain label glitch must not overwrite temporal identity.
            HandTrackCoordinator.Candidate(hand(.64), "right", .95, sideLocked = true),
            HandTrackCoordinator.Candidate(hand(.36), "left", .95, sideLocked = true),
        ), pose, 33)
        assertEquals(.64, result.left.detected!!.get(0), 1e-9)
        assertEquals(.36, result.right.detected!!.get(0), 1e-9)
        assertTrue(result.errors.any { it["code"] == "hand_assignment_hysteresis" })
    }

    @Test
    fun handSurfaceFlipIsHeldOnceThenAcceptedAfterConfirmation() {
        val tracker = HandTrackCoordinator()
        val pose = HandTrackCoordinator.PoseHint(.68, .55, .32, .55, .4)
        tracker.update(listOf(
            HandTrackCoordinator.Candidate(hand(.68, direction = 1.0), "left", 1.0),
        ), pose, 0)
        val held = tracker.update(listOf(
            HandTrackCoordinator.Candidate(hand(.68, direction = -1.0), "left", 1.0),
        ), pose, 33)
        assertNull(held.left.detected)
        assertEquals(.72, held.left.render!!.get(5 * 3), 1e-9)
        assertTrue(held.errors.any {
            it["code"] == "hand_surface_flip" && it["action"] == "hold_previous"
        })

        val confirmed = tracker.update(listOf(
            HandTrackCoordinator.Candidate(hand(.68, direction = -1.0), "left", 1.0),
        ), pose, 66)
        assertEquals(.64, confirmed.left.detected!!.get(5 * 3), 1e-9)
        assertTrue(confirmed.errors.none { it["code"] == "hand_surface_flip" })
    }

    @Test
    fun ambiguousArmChainHoldsPreviousTracksWithoutGuessingSide() {
        val tracker = HandTrackCoordinator()
        tracker.update(listOf(
            HandTrackCoordinator.Candidate(hand(.68), "left", .9),
            HandTrackCoordinator.Candidate(hand(.32), "right", .9),
        ), HandTrackCoordinator.PoseHint(.68, .55, .32, .55, .4), 0)
        val result = tracker.update(listOf(
            HandTrackCoordinator.Candidate(
                hand(.50), null, .9, sideAmbiguous = true,
            ),
            HandTrackCoordinator.Candidate(
                hand(.50), null, .9, sideAmbiguous = true,
            ),
        ), HandTrackCoordinator.PoseHint(.50, .55, .50, .55, .4), 33)
        assertNull(result.left.detected)
        assertNull(result.right.detected)
        assertTrue(result.errors.any { it["code"] == "hand_side_ambiguous" })
    }

    @Test
    fun pendingAssociationDoesNotTrustHandednessBeforePoseChain() {
        val tracker = HandTrackCoordinator()
        val result = tracker.update(listOf(
            HandTrackCoordinator.Candidate(
                hand(.68), "right", .9, sideAmbiguous = true,
            ),
        ), null, 0)
        assertNull(result.left.detected)
        assertNull(result.right.detected)
        assertTrue(result.errors.any { it["code"] == "hand_side_ambiguous" })
    }

    @Test
    fun skewBoundariesMatchRenderFusionContract() {
        assertEquals("direct", HandTrackCoordinator.sourceSkewMode(50))
        assertEquals("project", HandTrackCoordinator.sourceSkewMode(80))
        assertEquals("project", HandTrackCoordinator.sourceSkewMode(120))
        assertEquals("reject", HandTrackCoordinator.sourceSkewMode(121))
    }

    @Test
    fun staleHandTimestampHoldsPreviousLandmarksAndReportsError() {
        val tracker = HandTrackCoordinator()
        val pose = HandTrackCoordinator.PoseHint(.68, .55, .32, .55, .4)
        tracker.update(listOf(
            HandTrackCoordinator.Candidate(
                hand(.68), "left", .9, sideLocked = true,
            ),
        ), pose, 100)
        val result = tracker.update(listOf(
            HandTrackCoordinator.Candidate(
                hand(.67), "left", .9, sideLocked = true,
            ),
        ), pose, 100)
        assertNull(result.left.detected)
        assertEquals(.68, result.left.render!!.get(0), 1e-9)
        assertTrue(result.errors.any {
            it["code"] == "stale_frame" && it["action"] == "hold_previous"
        })
    }

    @Test
    fun degeneratePalmFrameHoldsPreviousLandmarksAndReportsError() {
        val tracker = HandTrackCoordinator()
        val pose = HandTrackCoordinator.PoseHint(.68, .55, .32, .55, .4)
        tracker.update(listOf(
            HandTrackCoordinator.Candidate(
                hand(.68), "left", .9, sideLocked = true,
            ),
        ), pose, 100)
        val degenerate = hand(.68).also {
            it[17 * 3] = it[5 * 3]
            it[17 * 3 + 1] = it[5 * 3 + 1]
        }
        val result = tracker.update(listOf(
            HandTrackCoordinator.Candidate(
                degenerate, "left", .9, sideLocked = true,
            ),
        ), pose, 133)
        assertNull(result.left.detected)
        assertEquals(.68, result.left.render!!.get(0), 1e-9)
        assertTrue(result.errors.any {
            it["code"] == "hand_geometry_degenerate" &&
                it["action"] == "hold_previous"
        })
    }

    @Test
    fun moreThanTwoCandidatesReportsExplicitCaptureError() {
        val tracker = HandTrackCoordinator()
        val pose = HandTrackCoordinator.PoseHint(.68, .55, .32, .55, .4)
        val result = tracker.update(listOf(
            HandTrackCoordinator.Candidate(hand(.68), "left", .9),
            HandTrackCoordinator.Candidate(hand(.32), "right", .9),
            HandTrackCoordinator.Candidate(hand(.50), null, .4),
        ), pose, 100)
        assertTrue(result.errors.any { it["code"] == "too_many_hand_candidates" })
    }
}
