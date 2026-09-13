package com.univoz.senas

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** Temporal hand association. Raw detections and predicted render stay separate. */
class HandTrackCoordinator {
    data class Candidate(
        val points: DoubleArray,
        val side: String?,
        val confidence: Double,
        /** True when pose arm-chain assigned anatomical side. */
        val sideLocked: Boolean = false,
        /** True when pose could not distinguish anatomical side this frame. */
        val sideAmbiguous: Boolean = false,
    )

    data class PoseHint(
        val leftWristX: Double,
        val leftWristY: Double,
        val rightWristX: Double,
        val rightWristY: Double,
        val shoulderWidth: Double,
    )

    data class TrackView(
        val side: String,
        val state: String,
        val detected: DoubleArray?,
        val render: DoubleArray?,
        val velocityX: Double,
        val velocityY: Double,
        val confidence: Double,
        val restBlend: Double,
    )

    data class Result(
        val left: TrackView,
        val right: TrackView,
        val contact: Boolean,
        val contactWristDistance: Double?,
        val costs: Map<String, Double?>,
        val errors: List<Map<String, String>>,
    )

    private data class Track(
        val side: String,
        var state: String = "LOST",
        var points: DoubleArray? = null,
        var velocityX: Double = 0.0,
        var velocityY: Double = 0.0,
        var velocityZ: Double = 0.0,
        var orientation: DoubleArray? = null,
        var confidence: Double = 0.0,
        var lastSeenMs: Long? = null,
        var hits: Int = 0,
        var statedSide: String? = null,
    )

    private var left = Track("left")
    private var right = Track("right")

    fun reset() {
        left = Track("left")
        right = Track("right")
    }

    fun update(
        rawCandidates: List<Candidate>,
        pose: PoseHint?,
        timestampMs: Long,
    ): Result {
        val candidates = rawCandidates.filter {
            it.points.size == 63 && it.points.all(Double::isFinite)
        }.take(2)
        val shoulderWidth = max(.05, pose?.shoulderWidth ?: .4)
        val contactBefore = candidates.size == 2 &&
            isContact(candidates[0].points, candidates[1].points, shoulderWidth)
        val matrix = candidates.map { candidate ->
            mapOf(
                "left" to cost(left, candidate, pose, timestampMs, contactBefore),
                "right" to cost(right, candidate, pose, timestampMs, contactBefore),
            )
        }
        val assigned = mutableMapOf<String, Candidate?>("left" to null, "right" to null)
        val assignedCosts = mutableMapOf<String, Double?>("left" to null, "right" to null)
        fun canAssign(candidate: Candidate, value: Double): Boolean =
            value <= .65 || (candidate.sideLocked && value <= .95)

        if (candidates.size == 2) {
            val normal = matrix[0].getValue("left") + matrix[1].getValue("right")
            val crossed = matrix[0].getValue("right") + matrix[1].getValue("left")
            val margin = max(.06, shoulderWidth * .16)
            val ambiguous = candidates.all { it.sideAmbiguous } &&
                normal.isFinite() && crossed.isFinite() &&
                abs(normal - crossed) < margin
            if (!ambiguous) {
                val pairs = if (normal <= crossed) {
                    listOf("left" to 0, "right" to 1)
                } else {
                    listOf("left" to 1, "right" to 0)
                }
                pairs.forEach { (side, index) ->
                    val value = matrix[index].getValue(side)
                    if (canAssign(candidates[index], value)) {
                        assigned[side] = candidates[index]
                        assignedCosts[side] = value
                    }
                }
            }
        } else if (candidates.size == 1) {
            val side = if (matrix[0].getValue("left") <= matrix[0].getValue("right"))
                "left" else "right"
            val value = matrix[0].getValue(side)
            val margin = max(.06, shoulderWidth * .16)
            val ambiguous = candidates[0].sideAmbiguous &&
                abs(matrix[0].getValue("left") - matrix[0].getValue("right")) < margin
            if (!ambiguous && canAssign(candidates[0], value)) {
                assigned[side] = candidates[0]
                assignedCosts[side] = value
            }
        }

        updateTrack(left, assigned["left"], timestampMs)
        updateTrack(right, assigned["right"], timestampMs)
        return result(
            timestampMs,
            shoulderWidth,
            assignedCosts,
            candidates.any { it.sideAmbiguous },
        )
    }

    /** Reprojects last valid wrists for render. Does not create raw detections. */
    fun renderAt(timestampMs: Long, shoulderWidth: Double = .4): Result =
        result(
            timestampMs,
            max(.05, shoulderWidth),
            mapOf("left" to null, "right" to null),
        )

    private fun result(
        timestampMs: Long,
        shoulderWidth: Double,
        costs: Map<String, Double?>,
        sideAmbiguous: Boolean = false,
    ): Result {
        val leftView = view(left, timestampMs)
        val rightView = view(right, timestampMs)
        val wristDistance = if (leftView.render != null && rightView.render != null) {
            pointDistance(leftView.render, rightView.render, 0) / shoulderWidth
        } else null
        val contact = leftView.render != null && rightView.render != null &&
            isContact(leftView.render, rightView.render, shoulderWidth)
        val errors = mutableListOf<Map<String, String>>()
        if (leftView.state == "OCCLUDED") errors += mapOf(
            "stage" to "association", "code" to "hand_occluded", "side" to "left")
        if (rightView.state == "OCCLUDED") errors += mapOf(
            "stage" to "association", "code" to "hand_occluded", "side" to "right")
        if (left.statedSide != null && left.statedSide != "left") errors += mapOf(
            "stage" to "association", "code" to "hand_identity_swap", "side" to "left")
        if (right.statedSide != null && right.statedSide != "right") errors += mapOf(
            "stage" to "association", "code" to "hand_identity_swap", "side" to "right")
        if (sideAmbiguous) errors += mapOf(
            "stage" to "association", "code" to "hand_side_ambiguous")
        return Result(leftView, rightView, contact, wristDistance, costs, errors)
    }

    private fun updateTrack(track: Track, candidate: Candidate?, timestampMs: Long) {
        if (candidate == null) return
        val previous = track.points
        val lastSeen = track.lastSeenMs
        if (previous != null && lastSeen != null && timestampMs > lastSeen) {
            val dt = max(.001, (timestampMs - lastSeen) / 1000.0)
            val vx = (candidate.points[0] - previous[0]) / dt
            val vy = (candidate.points[1] - previous[1]) / dt
            val vz = (candidate.points[2] - previous[2]) / dt
            track.velocityX = vx * .65 + track.velocityX * .35
            track.velocityY = vy * .65 + track.velocityY * .35
            track.velocityZ = vz * .65 + track.velocityZ * .35
        }
        track.points = candidate.points.copyOf()
        track.orientation = palmOrientation(candidate.points)
        track.confidence = clamp(candidate.confidence)
        track.lastSeenMs = timestampMs
        track.hits++
        track.statedSide = candidate.side?.lowercase()
        track.state = if (track.hits >= 2) "TRACKING" else "TENTATIVE"
    }

    private fun view(track: Track, timestampMs: Long): TrackView {
        val points = track.points
        val lastSeen = track.lastSeenMs
        if (points == null || lastSeen == null) {
            return TrackView(track.side, "LOST", null, null, 0.0, 0.0, 0.0, 1.0)
        }
        val elapsed = max(0L, timestampMs - lastSeen)
        if (elapsed > 500) {
            return TrackView(track.side, "LOST", null, null,
                track.velocityX, track.velocityY, track.confidence, 1.0)
        }
        val visible = elapsed == 0L
        val predictMs = min(300L, elapsed)
        val render = points.copyOf()
        if (!visible) {
            val dx = track.velocityX * predictMs / 1000.0
            val dy = track.velocityY * predictMs / 1000.0
            val dz = track.velocityZ * predictMs / 1000.0
            for (index in 0 until render.size / 3) {
                render[index * 3] += dx
                render[index * 3 + 1] += dy
                render[index * 3 + 2] += dz
            }
        }
        val state = if (visible) track.state else "OCCLUDED"
        val restBlend = if (elapsed <= 300) 0.0 else clamp((elapsed - 300) / 200.0)
        return TrackView(
            track.side,
            state,
            if (visible) points.copyOf() else null,
            render,
            track.velocityX,
            track.velocityY,
            track.confidence,
            restBlend,
        )
    }

    private fun cost(
        track: Track,
        candidate: Candidate,
        pose: PoseHint?,
        timestampMs: Long,
        contact: Boolean,
    ): Double {
        if (candidate.sideLocked && candidate.side?.lowercase() != track.side) {
            return Double.POSITIVE_INFINITY
        }
        val width = max(.05, pose?.shoulderWidth ?: .4)
        val expected = expectedWrist(track, timestampMs) ?: when (track.side) {
            "left" -> pose?.let { doubleArrayOf(it.leftWristX, it.leftWristY, 0.0) }
            else -> pose?.let { doubleArrayOf(it.rightWristX, it.rightWristY, 0.0) }
        }
        val position = if (expected == null) .5 else clamp(hypot(
            candidate.points[0] - expected[0], candidate.points[1] - expected[1]) / width)
        var velocity = .5
        val previous = track.points
        val lastSeen = track.lastSeenMs
        if (previous != null && lastSeen != null && timestampMs > lastSeen) {
            val dt = max(.001, (timestampMs - lastSeen) / 1000.0)
            val vx = (candidate.points[0] - previous[0]) / dt
            val vy = (candidate.points[1] - previous[1]) / dt
            val vz = (candidate.points[2] - previous[2]) / dt
            velocity = clamp(sqrt(
                (vx - track.velocityX) * (vx - track.velocityX) +
                    (vy - track.velocityY) * (vy - track.velocityY) +
                    (vz - track.velocityZ) * (vz - track.velocityZ),
            ) * .25)
        }
        val orientation = orientationDistance(track.orientation, palmOrientation(candidate.points))
        val stated = candidate.side?.lowercase().orEmpty()
        val side = if (stated.isEmpty()) .5 else if (stated == track.side) 0.0 else 1.0
        val confidence = 1.0 - clamp(candidate.confidence)
        return .45 * position + .20 * velocity + .20 * orientation +
            (if (contact) .02 else .10) * side + .05 * confidence
    }

    private fun expectedWrist(track: Track, timestampMs: Long): DoubleArray? {
        val points = track.points ?: return null
        val lastSeen = track.lastSeenMs ?: return null
        val dt = clamp((timestampMs - lastSeen) / 1000.0, 0.0, .3)
        return doubleArrayOf(
            points[0] + track.velocityX * dt,
            points[1] + track.velocityY * dt,
            points[2] + track.velocityZ * dt,
        )
    }

    private fun palmOrientation(points: DoubleArray): DoubleArray? {
        if (points.size < 54) return null
        fun unit(ax: Double, ay: Double, az: Double): DoubleArray? {
            val length = sqrt(ax * ax + ay * ay + az * az)
            return if (length <= 1e-8) null else
                doubleArrayOf(ax / length, ay / length, az / length)
        }
        val across = unit(
            points[5 * 3] - points[17 * 3],
            points[5 * 3 + 1] - points[17 * 3 + 1],
            points[5 * 3 + 2] - points[17 * 3 + 2],
        ) ?: return null
        val forward = unit(
            points[9 * 3] - points[0],
            points[9 * 3 + 1] - points[1],
            points[9 * 3 + 2] - points[2],
        ) ?: return null
        return across + forward
    }

    private fun orientationDistance(a: DoubleArray?, b: DoubleArray?): Double {
        if (a == null || b == null) return .5
        fun aligned(offset: Int): Double = clamp((
            a[offset] * b[offset] + a[offset + 1] * b[offset + 1] +
                a[offset + 2] * b[offset + 2] + 1.0) / 2.0)
        return 1.0 - (aligned(0) + aligned(3)) / 2.0
    }

    private fun isContact(a: DoubleArray, b: DoubleArray, shoulderWidth: Double): Boolean {
        if (pointDistance(a, b, 0) / shoulderWidth < .22) return true
        val boundsA = bounds(a)
        val boundsB = bounds(b)
        val width = max(0.0, min(boundsA[1], boundsB[1]) - max(boundsA[0], boundsB[0]))
        val height = max(0.0, min(boundsA[3], boundsB[3]) - max(boundsA[2], boundsB[2]))
        val intersection = width * height
        val areaA = max(1e-8, (boundsA[1] - boundsA[0]) * (boundsA[3] - boundsA[2]))
        val areaB = max(1e-8, (boundsB[1] - boundsB[0]) * (boundsB[3] - boundsB[2]))
        return intersection / min(areaA, areaB) > .25
    }

    private fun bounds(points: DoubleArray): DoubleArray {
        var minX = Double.POSITIVE_INFINITY
        var maxX = Double.NEGATIVE_INFINITY
        var minY = Double.POSITIVE_INFINITY
        var maxY = Double.NEGATIVE_INFINITY
        for (index in 0 until points.size / 3) {
            minX = min(minX, points[index * 3])
            maxX = max(maxX, points[index * 3])
            minY = min(minY, points[index * 3 + 1])
            maxY = max(maxY, points[index * 3 + 1])
        }
        return doubleArrayOf(minX, maxX, minY, maxY)
    }

    private fun pointDistance(a: DoubleArray, b: DoubleArray, index: Int): Double {
        val offset = index * 3
        val dx = a[offset] - b[offset]
        val dy = a[offset + 1] - b[offset + 1]
        val dz = a[offset + 2] - b[offset + 2]
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    companion object {
        private fun clamp(value: Double, min: Double = 0.0, max: Double = 1.0): Double =
            kotlin.math.max(min, kotlin.math.min(max, value))

        fun sourceSkewMode(skewMs: Long): String = when {
            abs(skewMs) <= 50 -> "direct"
            abs(skewMs) <= 120 -> "project"
            else -> "reject"
        }
    }
}
