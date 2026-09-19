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
        var detectedAtMs: Long? = null,
        var pendingOrientation: DoubleArray? = null,
        var pendingOrientationCount: Int = 0,
        var lastRejectCode: String? = null,
    )

    private data class OrientationDecision(
        val accepted: Boolean,
        val pendingOrientation: DoubleArray?,
        val pendingCount: Int,
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
        val tooManyCandidates = rawCandidates.size > 2
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
        var assignmentHysteresis = false
        left.detectedAtMs = null
        right.detectedAtMs = null
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
                // Pose arm-chain labels are authoritative only when they agree
                // with temporal continuity. Hold one bad frame during fast
                // crossings instead of exchanging physical hands.
                val neutralMatrix = candidates.map { candidate ->
                    mapOf(
                        "left" to cost(left, candidate, pose, timestampMs,
                            contactBefore, ignoreSide = true),
                        "right" to cost(right, candidate, pose, timestampMs,
                            contactBefore, ignoreSide = true),
                    )
                }
                val temporalNormal = neutralMatrix[0].getValue("left") +
                    neutralMatrix[1].getValue("right")
                val temporalCrossed = neutralMatrix[0].getValue("right") +
                    neutralMatrix[1].getValue("left")
                val labelMode: String? = when {
                    normal.isFinite() && (!crossed.isFinite() || normal <= crossed) -> "normal"
                    crossed.isFinite() -> "crossed"
                    else -> null
                }
                val temporalMode: String? = when {
                    temporalNormal.isFinite() && temporalCrossed.isFinite() &&
                        abs(temporalNormal - temporalCrossed) >= margin &&
                        temporalNormal <= temporalCrossed -> "normal"
                    temporalNormal.isFinite() && temporalCrossed.isFinite() &&
                        abs(temporalNormal - temporalCrossed) >= margin -> "crossed"
                    else -> null
                }
                var selectedMode = labelMode
                // One paired frame already establishes identity; waiting for
                // TRACKING state leaves first fast crossing exposed.
                val established = left.hits >= 1 && right.hits >= 1
                if (established && labelMode != null && temporalMode != null &&
                    labelMode != temporalMode) {
                    selectedMode = temporalMode
                    assignmentHysteresis = true
                }
                val selectedMatrix = if (selectedMode == labelMode) matrix else neutralMatrix
                val pairs = if (selectedMode == "normal") {
                    listOf("left" to 0, "right" to 1)
                } else if (selectedMode == "crossed") {
                    listOf("left" to 1, "right" to 0)
                } else emptyList()
                pairs.forEach { (side, index) ->
                    val value = selectedMatrix[index].getValue(side)
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
            assignmentHysteresis,
            tooManyCandidates,
        )
    }

    /** Reprojects last valid wrists for render. Does not create raw detections. */
    fun renderAt(timestampMs: Long, shoulderWidth: Double = .4): Result =
        result(
            timestampMs,
            max(.05, shoulderWidth),
            mapOf("left" to null, "right" to null),
            includeDetected = false,
        )

    private fun result(
        timestampMs: Long,
        shoulderWidth: Double,
        costs: Map<String, Double?>,
        sideAmbiguous: Boolean = false,
        assignmentHysteresis: Boolean = false,
        tooManyCandidates: Boolean = false,
        includeDetected: Boolean = true,
    ): Result {
        val leftView = view(left, timestampMs, includeDetected)
        val rightView = view(right, timestampMs, includeDetected)
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
        if (!assignmentHysteresis && left.statedSide != null && left.statedSide != "left") errors += mapOf(
            "stage" to "association", "code" to "hand_identity_swap", "side" to "left")
        if (!assignmentHysteresis && right.statedSide != null && right.statedSide != "right") errors += mapOf(
            "stage" to "association", "code" to "hand_identity_swap", "side" to "right")
        if (left.lastRejectCode != null) errors += mapOf(
            "stage" to "association", "code" to left.lastRejectCode!!,
            "side" to "left", "action" to "hold_previous")
        if (right.lastRejectCode != null) errors += mapOf(
            "stage" to "association", "code" to right.lastRejectCode!!,
            "side" to "right", "action" to "hold_previous")
        if (sideAmbiguous) errors += mapOf(
            "stage" to "association", "code" to "hand_side_ambiguous")
        if (assignmentHysteresis) errors += mapOf(
            "stage" to "association", "code" to "hand_assignment_hysteresis",
            "action" to "hold_temporal_identity")
        if (tooManyCandidates) errors += mapOf(
            "stage" to "capture", "code" to "too_many_hand_candidates",
            "action" to "reject_excess_candidates")
        return Result(leftView, rightView, contact, wristDistance, costs, errors)
    }

    private fun updateTrack(track: Track, candidate: Candidate?, timestampMs: Long) {
        track.lastRejectCode = null
        if (candidate == null) return
        val previous = track.points
        val lastSeen = track.lastSeenMs
        if (lastSeen != null && timestampMs <= lastSeen) {
            track.lastRejectCode = "stale_frame"
            return
        }
        val currentOrientation = palmOrientation(candidate.points)
        if (currentOrientation == null) {
            track.lastRejectCode = "hand_geometry_degenerate"
            return
        }
        val wristDisplacement = if (previous == null) 0.0 else pointDistance(
            candidate.points, previous, 0)
        val orientationDecision = handSurfaceTransition(
            track.orientation,
            currentOrientation,
            wristDisplacement,
            .4,
            track.pendingOrientation,
            track.pendingOrientationCount,
        )
        track.pendingOrientation = orientationDecision.pendingOrientation
        track.pendingOrientationCount = orientationDecision.pendingCount
        if (!orientationDecision.accepted) {
            track.lastRejectCode = "hand_surface_flip"
            return
        }
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
        track.orientation = currentOrientation
        track.confidence = clamp(candidate.confidence)
        track.lastSeenMs = timestampMs
        track.detectedAtMs = timestampMs
        track.hits++
        track.statedSide = candidate.side?.lowercase()
        track.state = if (track.hits >= 2) "TRACKING" else "TENTATIVE"
    }

    private fun handSurfaceTransition(
        previous: DoubleArray?,
        current: DoubleArray?,
        wristDisplacement: Double,
        shoulderWidth: Double,
        pendingOrientation: DoubleArray?,
        pendingCount: Int,
    ): OrientationDecision {
        val orientation = orientationDistance(previous, current)
        val width = max(.05, shoulderWidth)
        val suspicious = previous != null && current != null &&
            orientation >= .60 && wristDisplacement / width <= .40
        if (!suspicious) return OrientationDecision(true, null, 0)
        val repeats = pendingOrientation != null &&
            orientationDistance(pendingOrientation, current) < .25
        val nextCount = if (repeats) max(0, pendingCount) + 1 else 1
        return if (nextCount >= 2) {
            OrientationDecision(true, null, 0)
        } else {
            OrientationDecision(false, current, nextCount)
        }
    }

    private fun view(track: Track, timestampMs: Long, includeDetected: Boolean): TrackView {
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
        val visible = includeDetected && track.detectedAtMs == timestampMs
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
        ignoreSide: Boolean = false,
    ): Double {
        if (!ignoreSide && candidate.sideLocked && candidate.side?.lowercase() != track.side) {
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
        // Ambiguous/pending candidates must not influence association with
        // HandLandmarker handedness; pose arm-chain or temporal continuity
        // remain authoritative.
        val stated = if (ignoreSide || candidate.sideAmbiguous) "" else
            candidate.side?.lowercase().orEmpty()
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

    internal fun palmOrientation(points: DoubleArray): DoubleArray? {
        if (points.size < 63) return null
        fun unit(ax: Double, ay: Double, az: Double): DoubleArray? {
            val length = sqrt(ax * ax + ay * ay + az * az)
            return if (length <= 1e-8) null else
                doubleArrayOf(ax / length, ay / length, az / length)
        }
        val wrist = doubleArrayOf(points[0], points[1], points[2])
        val cmc = doubleArrayOf(points[3], points[4], points[5])
        val forward = unit(
            points[9 * 3] - wrist[0],
            points[9 * 3 + 1] - wrist[1],
            points[9 * 3 + 2] - wrist[2],
        ) ?: return null
        val index = doubleArrayOf(points[5 * 3], points[5 * 3 + 1], points[5 * 3 + 2])
        val little = doubleArrayOf(points[17 * 3], points[17 * 3 + 1], points[17 * 3 + 2])
        val indexFromWrist = doubleArrayOf(
            index[0] - wrist[0], index[1] - wrist[1], index[2] - wrist[2],
        )
        val littleFromWrist = doubleArrayOf(
            little[0] - wrist[0], little[1] - wrist[1], little[2] - wrist[2],
        )
        val normal = unit(
            indexFromWrist[1] * littleFromWrist[2] -
                indexFromWrist[2] * littleFromWrist[1],
            indexFromWrist[2] * littleFromWrist[0] -
                indexFromWrist[0] * littleFromWrist[2],
            indexFromWrist[0] * littleFromWrist[1] -
                indexFromWrist[1] * littleFromWrist[0],
        ) ?: return null
        var radial = unit(
            normal[1] * forward[2] - normal[2] * forward[1],
            normal[2] * forward[0] - normal[0] * forward[2],
            normal[0] * forward[1] - normal[1] * forward[0],
        ) ?: return null
        val cmcFromWrist = doubleArrayOf(
            cmc[0] - wrist[0], cmc[1] - wrist[1], cmc[2] - wrist[2],
        )
        val radialDot = cmcFromWrist[0] * radial[0] +
            cmcFromWrist[1] * radial[1] + cmcFromWrist[2] * radial[2]
        if (!radialDot.isFinite() || abs(radialDot) <= 1e-8) return null
        var correctedNormal = normal
        if (radialDot < 0) {
            radial = radial.map { -it }.toDoubleArray()
            correctedNormal = normal.map { -it }.toDoubleArray()
        }
        return radial + forward + correctedNormal
    }

    private fun orientationDistance(a: DoubleArray?, b: DoubleArray?): Double {
        if (a == null || b == null) return .5
        fun aligned(offset: Int): Double = clamp((
            a[offset] * b[offset] + a[offset + 1] * b[offset + 1] +
                a[offset + 2] * b[offset + 2] + 1.0) / 2.0)
        var sum = aligned(0) + aligned(3)
        var count = 2
        if (a.size >= 9 && b.size >= 9) {
            sum += aligned(6)
            count++
        }
        return 1.0 - sum / count
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
