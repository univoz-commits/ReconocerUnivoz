package com.univoz.senas

import android.content.Context
import android.graphics.Bitmap
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarkerResult

/**
 * Envuelve HandLandmarker y PoseLandmarker corriendo en LIVE_STREAM.
 *
 * Los dos tasks son independientes y devuelven resultados por callbacks
 * asincronos que llegan en orden impredecible. Hay DOS salidas distintas
 * a proposito:
 *
 * - [onFrame]: solo dispara cuando pose y manos disponibles pertenecen a
 *   instantes compatibles (ventana maxima de 120 ms). Las tareas pueden
 *   terminar con latencias distintas; exigir timestamp exacto dejaria el
 *   canal de grabacion vacio en dispositivos lentos. Usar para guardar
 *   muestras o alimentar el clasificador (DtwClassifier).
 *
 * - [onPreview]: dispara cada vez que CUALQUIERA de los dos modelos
 *   termina, combinando con el ultimo dato conocido del otro. Es para
 *   pintar el esqueleto en pantalla en vivo.
 *
 * [analizarManos] y [analizarPose] son independientes: cada una tiene su
 * propia compuerta de backpresion (no aceptan un frame nuevo mientras el
 * anterior sigue en vuelo) y quien llama (LandmarkPlugin) decide con que
 * frecuencia llama a cada una. La idea: las manos cambian de forma rapido
 * al senar y necesitan actualizarse seguido; el torso/hombros se mueven
 * mucho mas despacio, asi que correr pose con menos frecuencia libera
 * computo real para el modelo de manos sin perder nada perceptible.
 */
class LandmarkEngine(
    context: Context,
    private val onFrame: (FrameResult) -> Unit,
    private val onPreview: (FrameResult) -> Unit,
    private val onError: (String) -> Unit,
) {

    /**
     * pose: 33 x (x, y, z, visibility) en coordenadas de imagen [0,1].
     * poseMundo: 33 x (x, y, z) en METROS, con origen en el punto medio de
     *   las caderas. Es el esqueleto 3D real, no la profundidad aproximada
     *   que trae `pose`.
     * manos: 21 x (x, y, z) o null.
     *
     * Las dos versiones de pose viajan juntas porque sirven para cosas
     * distintas: las de imagen son las que se pintan sobre el preview de la
     * camara, y las metricas son las unicas con las que se puede reconstruir
     * una postura. La Z de `pose` se midio incoherente entre puntos vecinos
     * (recorridos de 3.5 anchos de hombro en un antebrazo de 0.8), asi que
     * no sirve para orientar huesos.
     */
    class FrameResult(
        val timestampMs: Long,
        val pose: DoubleArray?,
        val poseMundo: DoubleArray?,
        val left: DoubleArray?,
        val right: DoubleArray?,
        val renderLeft: DoubleArray?,
        val renderRight: DoubleArray?,
        val poseTimestampMs: Long?,
        val handsTimestampMs: Long?,
        val sourceSkewMs: Long?,
        val association: Map<String, Any?>,
        val errors: List<Map<String, String>>,
    )

    // Ultimo dato conocido de cada mitad, para armar el preview sin esperar
    // a que coincidan. Con lock propio porque pose y manos llegan de hilos
    // distintos (cada modelo tiene su propio callback interno).
    private val ultimoLock = Any()
    private var ultimaPose: DoubleArray? = null
    private var ultimaPoseMundo: DoubleArray? = null
    private var ultimoTimestampPose = Long.MIN_VALUE
    private var ultimaIzq: DoubleArray? = null
    private var ultimaDer: DoubleArray? = null
    private var ultimoTimestampManos = Long.MIN_VALUE
    private var manosConocidas = false
    private val handTracker = HandTrackCoordinator()
    private var ultimoTracking: HandTrackCoordinator.Result? = null

    private data class ManoCandidata(
        val puntos: DoubleArray,
        val etiqueta: String?,
        val confianza: Double,
        val muñecaX: Double,
        val muñecaY: Double,
    )

    // A 30 FPS permite un desfase de hasta 3-4 capturas entre tasks, pero no
    // mezcla posturas separadas por una pausa real del tracking.
    private val ventanaFusionMs = 120L
    private companion object {
        const val MIN_POSE_WRIST_VISIBILITY = 0.35
    }

    // Compuertas de backpresion INDEPENDIENTES: cada modelo se libera con
    // su propio resultado, no con el del otro. Asi las manos no esperan al
    // torso ni viceversa.
    private val manosLock = Any()
    private var manosEnVuelo = false
    private var manosDesdeNs = 0L

    private val poseLock = Any()
    private var poseEnVuelo = false
    private var poseDesdeNs = 0L

    private val timeoutNs = 2_000_000_000L // 2s de seguridad por si un resultado nunca llega

    private val handLandmarker: HandLandmarker
    private val poseLandmarker: PoseLandmarker

    init {
        val handOptions = HandLandmarker.HandLandmarkerOptions.builder()
            .setBaseOptions(
                BaseOptions.builder()
                    .setModelAssetPath("hand_landmarker.task")
                    .setDelegate(Delegate.GPU)
                    .build()
            )
            .setRunningMode(RunningMode.LIVE_STREAM)
            .setNumHands(2)
            .setMinHandDetectionConfidence(0.4f)
            .setMinTrackingConfidence(0.3f)
            .setMinHandPresenceConfidence(0.4f)
            .setResultListener { result, _ -> onManos(result) }
            .setErrorListener { e -> onError("manos: ${e.message}") }
            .build()

        val poseOptions = PoseLandmarker.PoseLandmarkerOptions.builder()
            .setBaseOptions(
                BaseOptions.builder()
                    .setModelAssetPath("pose_landmarker_lite.task")
                    .setDelegate(Delegate.GPU)
                    .build()
            )
            .setRunningMode(RunningMode.LIVE_STREAM)
            .setNumPoses(1)
            .setMinPoseDetectionConfidence(0.4f)
            .setMinTrackingConfidence(0.3f)
            .setMinPosePresenceConfidence(0.4f)
            .setResultListener { result, _ -> onPose(result) }
            .setErrorListener { e -> onError("pose: ${e.message}") }
            .build()

        handLandmarker = HandLandmarker.createFromOptions(context, handOptions)
        poseLandmarker = PoseLandmarker.createFromOptions(context, poseOptions)
    }

    fun manosOcupadas(): Boolean = synchronized(manosLock) {
        manosEnVuelo && (System.nanoTime() - manosDesdeNs < timeoutNs)
    }

    fun poseOcupada(): Boolean = synchronized(poseLock) {
        poseEnVuelo && (System.nanoTime() - poseDesdeNs < timeoutNs)
    }

    /** [timestampMs] estrictamente creciente. Devuelve false si ya hay manos en vuelo. */
    fun analizarManos(bitmap: Bitmap, timestampMs: Long): Boolean {
        synchronized(manosLock) {
            val ahora = System.nanoTime()
            if (manosEnVuelo && ahora - manosDesdeNs < timeoutNs) return false
            manosEnVuelo = true
            manosDesdeNs = ahora
        }
        val mpImage = BitmapImageBuilder(bitmap).build()
        handLandmarker.detectAsync(mpImage, timestampMs)
        return true
    }

    /** [timestampMs] estrictamente creciente. Devuelve false si ya hay pose en vuelo. */
    fun analizarPose(bitmap: Bitmap, timestampMs: Long): Boolean {
        synchronized(poseLock) {
            val ahora = System.nanoTime()
            if (poseEnVuelo && ahora - poseDesdeNs < timeoutNs) return false
            poseEnVuelo = true
            poseDesdeNs = ahora
        }
        val mpImage = BitmapImageBuilder(bitmap).build()
        poseLandmarker.detectAsync(mpImage, timestampMs)
        return true
    }

    private fun crearFrame(
        timestampMs: Long,
        pose: DoubleArray?,
        poseMundo: DoubleArray?,
        left: DoubleArray?,
        right: DoubleArray?,
        renderLeft: DoubleArray?,
        renderRight: DoubleArray?,
        poseTimestampMs: Long?,
        handsTimestampMs: Long?,
        tracking: HandTrackCoordinator.Result?,
        extraErrors: List<Map<String, String>> = emptyList(),
    ): FrameResult {
        val skew = if (poseTimestampMs != null && handsTimestampMs != null)
            abs(poseTimestampMs - handsTimestampMs) else null
        val errors = mutableListOf<Map<String, String>>()
        tracking?.errors?.let(errors::addAll)
        errors.addAll(extraErrors)
        if (skew != null && skew > 50) {
            errors += mapOf("stage" to "fusion", "code" to "source_skew")
        }
        if (pose != null && pose.size >= 33 * 4) {
            val shoulderWidth = max(.05, distanciaPose(pose, 11, 12))
            listOf("left" to (left to 15), "right" to (right to 16)).forEach {
                (side, handAndIndex) ->
                val hand = handAndIndex.first
                val poseIndex = handAndIndex.second
                if (hand != null && hand.size >= 3) {
                    val residual = hypot(
                        hand[0] - pose[poseIndex * 4],
                        hand[1] - pose[poseIndex * 4 + 1],
                    ) / shoulderWidth
                    if (residual > .25) errors += mapOf(
                        "stage" to "fusion",
                        "code" to "wrist_disagreement",
                        "side" to side,
                    )
                }
            }
        }
        val association = if (tracking == null) emptyMap() else mapOf(
            "left_state" to tracking.left.state,
            "right_state" to tracking.right.state,
            "left_cost" to tracking.costs["left"],
            "right_cost" to tracking.costs["right"],
            "contact" to tracking.contact,
            "contact_wrist_distance" to tracking.contactWristDistance,
        )
        return FrameResult(
            timestampMs,
            pose,
            poseMundo,
            left,
            right,
            renderLeft,
            renderRight,
            poseTimestampMs,
            handsTimestampMs,
            skew,
            association,
            errors,
        )
    }

    private fun onPose(result: PoseLandmarkerResult) {
        synchronized(poseLock) { poseEnVuelo = false }

        val t = result.timestampMs()
        val lm = result.landmarks().firstOrNull()
        val arr = if (lm == null || lm.size < 33) null else DoubleArray(33 * 4).also {
            for (i in 0 until 33) {
                val p = lm[i]
                it[i * 4] = p.x().toDouble()
                it[i * 4 + 1] = p.y().toDouble()
                it[i * 4 + 2] = p.z().toDouble()
                it[i * 4 + 3] = (p.visibility().orElse(0f)).toDouble()
            }
        }

        // Esqueleto metrico. Sin visibility: worldLandmarks no la trae, y de
        // todos modos el filtro por visibilidad se hace con `pose`.
        val wlm = result.worldLandmarks().firstOrNull()
        val arrMundo = if (wlm == null || wlm.size < 33) null else DoubleArray(33 * 3).also {
            for (i in 0 until 33) {
                val p = wlm[i]
                it[i * 3] = p.x().toDouble()
                it[i * 3 + 1] = p.y().toDouble()
                it[i * 3 + 2] = p.z().toDouble()
            }
        }

        var fusionado: FrameResult? = null
        val preview = synchronized(ultimoLock) {
            ultimaPose = arr
            ultimaPoseMundo = arrMundo
            ultimoTimestampPose = t
            val shoulderWidth = if (arr != null && arr.size >= 33 * 4)
                max(.05, distanciaPose(arr, 11, 12)) else .4
            val render = if (manosConocidas) {
                handTracker.renderAt(t, shoulderWidth)
            } else null
            if (manosConocidas && abs(t - ultimoTimestampManos) <= ventanaFusionMs) {
                fusionado = crearFrame(
                    maxOf(t, ultimoTimestampManos),
                    arr,
                    arrMundo,
                    ultimaIzq,
                    ultimaDer,
                    render?.left?.render,
                    render?.right?.render,
                    t,
                    ultimoTimestampManos,
                    render ?: ultimoTracking,
                )
            }
            crearFrame(
                t,
                arr,
                arrMundo,
                ultimaIzq,
                ultimaDer,
                render?.left?.render,
                render?.right?.render,
                t,
                ultimoTimestampManos.takeIf { manosConocidas },
                render ?: ultimoTracking,
            )
        }
        onPreview(preview)
        fusionado?.let(onFrame)
    }

    private fun onManos(result: HandLandmarkerResult) {
        synchronized(manosLock) { manosEnVuelo = false }

        val t = result.timestampMs()
        val poseParaLados = synchronized(ultimoLock) {
            if (ultimoTimestampPose != Long.MIN_VALUE &&
                abs(t - ultimoTimestampPose) <= ventanaFusionMs
            ) {
                ultimaPose
            } else {
                null
            }
        }

        val manos = result.landmarks()
        val lados = result.handednesses()
        val candidatas = mutableListOf<ManoCandidata>()
        val erroresEntrada = mutableListOf<Map<String, String>>()
        for (i in manos.indices) {
            val lm = manos[i]
            if (lm.size != 21) {
                erroresEntrada += mapOf(
                    "stage" to "capture",
                    "code" to "hand_landmarks_incomplete",
                    "index" to i.toString(),
                )
                continue
            }
            val arr = DoubleArray(21 * 3)
            for (j in 0 until 21) {
                val p = lm[j]
                arr[j * 3] = p.x().toDouble()
                arr[j * 3 + 1] = p.y().toDouble()
                arr[j * 3 + 2] = p.z().toDouble()
            }
            if (arr.any { !it.isFinite() }) {
                erroresEntrada += mapOf(
                    "stage" to "capture",
                    "code" to "point_non_finite",
                    "index" to i.toString(),
                )
                continue
            }
            candidatas += ManoCandidata(
                puntos = arr,
                etiqueta = lados.getOrNull(i)?.firstOrNull()?.categoryName(),
                confianza = lados.getOrNull(i)?.firstOrNull()?.score()?.toDouble() ?: .5,
                muñecaX = lm[0].x().toDouble(),
                muñecaY = lm[0].y().toDouble(),
            )
        }
        val poseCadenaDisponible = poseParaLados != null &&
            poseParaLados.size >= 33 * 4 && poseTieneCadenaBrazo(poseParaLados)
        val poseMunecasDisponibles = poseParaLados != null &&
            poseParaLados.size >= 33 * 4 && poseTieneMunecas(poseParaLados)
        val ladosCadena = if (poseCadenaDisponible) {
            asignarLadosCadena(candidatas, poseParaLados!!)
        } else emptyList()
        val cadenaAmbigua = poseCadenaDisponible &&
            candidatas.isNotEmpty() &&
            ladosCadena.size == candidatas.size &&
            ladosCadena.all { it == null }
        val trackCandidates = candidatas.mapIndexed { index, candidata ->
            val ladoCadena = ladosCadena.getOrNull(index)
            val side = if (cadenaAmbigua) null else ladoCadena ?: if (poseMunecasDisponibles) {
                ladoPorMunecaPose(candidata, poseParaLados!!)
                    ?: ladoFisicoMano(candidata.etiqueta, candidata.muñecaX)
            } else {
                ladoFisicoMano(candidata.etiqueta, candidata.muñecaX)
            }
            HandTrackCoordinator.Candidate(
                candidata.puntos,
                side,
                candidata.confianza,
                sideLocked = ladoCadena != null,
                sideAmbiguous = cadenaAmbigua,
            )
        }

        var fusionado: FrameResult? = null
        val preview = synchronized(ultimoLock) {
            val poseHint = poseParaLados?.takeIf {
                it.size >= 33 * 4 && poseTieneMunecas(it)
            }?.let {
                HandTrackCoordinator.PoseHint(
                    it[15 * 4], it[15 * 4 + 1],
                    it[16 * 4], it[16 * 4 + 1],
                    max(.05, distanciaPose(it, 11, 12)),
                )
            }
            val tracked = handTracker.update(trackCandidates, poseHint, t)
            val izq = tracked.left.detected
            val der = tracked.right.detected
            ultimoTracking = tracked
            ultimaIzq = izq
            ultimaDer = der
            ultimoTimestampManos = t
            manosConocidas = true
            if (ultimoTimestampPose != Long.MIN_VALUE &&
                abs(t - ultimoTimestampPose) <= ventanaFusionMs
            ) {
                fusionado = crearFrame(
                    maxOf(t, ultimoTimestampPose),
                    ultimaPose,
                    ultimaPoseMundo,
                    izq,
                    der,
                    tracked.left.render,
                    tracked.right.render,
                    ultimoTimestampPose,
                    t,
                    tracked,
                    erroresEntrada,
                )
            }
            crearFrame(
                t,
                ultimaPose,
                ultimaPoseMundo,
                izq,
                der,
                tracked.left.render,
                tracked.right.render,
                ultimoTimestampPose.takeIf { it != Long.MIN_VALUE },
                t,
                tracked,
                erroresEntrada,
            )
        }
        onPreview(preview)
        fusionado?.let(onFrame)
    }

    /** Devuelve lado fisico; null evita inventar lado con mano en el centro. */
    private fun ladoFisicoMano(etiqueta: String?, muñecaX: Double): String? {
        val raw = etiqueta.orEmpty()
        // Fallback solamente. La geometria pose-muneca tiene prioridad porque
        // la etiqueta de Hand Landmarker asume selfie espejado y puede quedar
        // invertida cuando ImageAnalysis entrega el bitmap crudo.
        if (raw.contains("left", ignoreCase = true)) return "right"
        if (raw.contains("right", ignoreCase = true)) return "left"
        return when {
            muñecaX > 0.52 -> "left"
            muñecaX < 0.48 -> "right"
            else -> null
        }
    }

    private fun poseTieneMunecas(pose: DoubleArray): Boolean {
        return (15..16).all { i ->
            pose[i * 4].isFinite() &&
                pose[i * 4 + 1].isFinite() &&
                pose[i * 4 + 3].isFinite() &&
                pose[i * 4 + 3] >= MIN_POSE_WRIST_VISIBILITY
        }
    }

    private fun poseTieneCadenaBrazo(pose: DoubleArray): Boolean {
        return listOf(11, 13, 15, 12, 14, 16).all { i ->
            pose[i * 4].isFinite() && pose[i * 4 + 1].isFinite() &&
                pose[i * 4 + 3].isFinite() &&
                pose[i * 4 + 3] >= MIN_POSE_WRIST_VISIBILITY
        }
    }

    /** Coste anatomico: hombro -> codo -> muñeca, no imagen izquierda/derecha. */
    private fun asignarLadosCadena(
        candidatas: List<ManoCandidata>,
        pose: DoubleArray,
    ): List<String?> {
        if (candidatas.isEmpty()) return emptyList()
        val ancho = max(.05, distanciaPose(pose, 11, 12))
        val margen = max(.06, ancho * .16)
        val costos = candidatas.map { mano ->
            costoCadenaBrazo(mano, pose, 11, 13, 15) to
                costoCadenaBrazo(mano, pose, 12, 14, 16)
        }
        if (candidatas.size >= 2) {
            val normal = costos[0].first + costos[1].second
            val cruzada = costos[0].second + costos[1].first
            if (normal.isFinite() && cruzada.isFinite() &&
                abs(normal - cruzada) >= margen
            ) {
                return if (normal < cruzada) listOf("left", "right")
                else listOf("right", "left")
            }
            // Ambiguous pair: do not guess side. Temporal tracker preserves
            // existing identity; new detections remain unassigned.
            return List(candidatas.size) { null }
        }
        return costos.map { (left, right) ->
            if (left.isFinite() && right.isFinite() &&
                abs(left - right) >= margen
            ) if (left < right) "left" else "right" else null
        }
    }

    private fun costoCadenaBrazo(
        mano: ManoCandidata,
        pose: DoubleArray,
        hombro: Int,
        codo: Int,
        muneca: Int,
    ): Double {
        val sx = pose[hombro * 4]
        val sy = pose[hombro * 4 + 1]
        val ex = pose[codo * 4]
        val ey = pose[codo * 4 + 1]
        val wx = pose[muneca * 4]
        val wy = pose[muneca * 4 + 1]
        if (!listOf(sx, sy, ex, ey, wx, wy, mano.muñecaX, mano.muñecaY)
                .all { it.isFinite() }
        ) return Double.POSITIVE_INFINITY

        val ancho = max(.05, distanciaPose(pose, 11, 12))
        val endpoint = hypot(mano.muñecaX - wx, mano.muñecaY - wy) / ancho
        val expectedX = wx - sx
        val expectedY = wy - sy
        val observedX = mano.muñecaX - sx
        val observedY = mano.muñecaY - sy
        val expectedLength = hypot(expectedX, expectedY)
        val observedLength = hypot(observedX, observedY)
        val direction = if (expectedLength <= 1e-8 || observedLength <= 1e-8) {
            .5
        } else {
            val aligned = (expectedX * observedX + expectedY * observedY) /
                (expectedLength * observedLength)
            1.0 - ((aligned + 1.0) / 2.0).coerceIn(0.0, 1.0)
        }
        val expectedLower = hypot(wx - ex, wy - ey)
        val observedLower = hypot(mano.muñecaX - ex, mano.muñecaY - ey)
        val chain = abs(observedLower - expectedLower) / ancho
        return endpoint + direction * .35 + chain * .20
    }

    private fun ladoPorMunecaPose(
        mano: ManoCandidata,
        pose: DoubleArray,
    ): String? {
        val izquierda = distanciaPoseMano(mano, pose, 15)
        val derecha = distanciaPoseMano(mano, pose, 16)
        val hombros = distanciaPose(pose, 11, 12)
        val margen = max(0.035, hombros * 0.12)
        if (abs(izquierda - derecha) <= margen) return null
        return if (izquierda < derecha) "left" else "right"
    }

    private fun distanciaPoseMano(
        mano: ManoCandidata,
        pose: DoubleArray,
        indicePose: Int,
    ): Double {
        val dx = mano.muñecaX - pose[indicePose * 4]
        val dy = mano.muñecaY - pose[indicePose * 4 + 1]
        return hypot(dx, dy)
    }

    private fun distanciaPose(pose: DoubleArray, a: Int, b: Int): Double {
        val dx = pose[a * 4] - pose[b * 4]
        val dy = pose[a * 4 + 1] - pose[b * 4 + 1]
        return hypot(dx, dy)
    }

    fun cerrar() {
        handLandmarker.close()
        poseLandmarker.close()
        synchronized(ultimoLock) {
            ultimaPose = null
            ultimaPoseMundo = null
            ultimoTimestampPose = Long.MIN_VALUE
            ultimaIzq = null
            ultimaDer = null
            ultimoTimestampManos = Long.MIN_VALUE
            manosConocidas = false
            ultimoTracking = null
            handTracker.reset()
        }
        synchronized(manosLock) { manosEnVuelo = false }
        synchronized(poseLock) { poseEnVuelo = false }
    }
}
