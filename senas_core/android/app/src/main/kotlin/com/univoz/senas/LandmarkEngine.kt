package com.univoz.senas

import android.content.Context
import android.graphics.Bitmap
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
 * - [onFrame]: solo dispara cuando pose y manos coincidieron en el mismo
 *   timestamp exacto (osea, cuando ademas se mandaron juntas -- ver
 *   [analizarPose]/[analizarManos]). Usar para guardar muestras o
 *   alimentar el clasificador (DtwClassifier).
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

    /** pose: 33 x (x, y, z, visibility). manos: 21 x (x, y, z) o null. */
    class FrameResult(
        val timestampMs: Long,
        val pose: DoubleArray?,
        val left: DoubleArray?,
        val right: DoubleArray?,
    )

    private class Pendiente {
        var pose: DoubleArray? = null
        var left: DoubleArray? = null
        var right: DoubleArray? = null
        var tienePose = false
        var tieneManos = false
    }

    private val pendientes = LinkedHashMap<Long, Pendiente>()
    private val maxPendientes = 8

    // Ultimo dato conocido de cada mitad, para armar el preview sin esperar
    // a que coincidan. Con lock propio porque pose y manos llegan de hilos
    // distintos (cada modelo tiene su propio callback interno).
    private val ultimoLock = Any()
    private var ultimaPose: DoubleArray? = null
    private var ultimaIzq: DoubleArray? = null
    private var ultimaDer: DoubleArray? = null

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

    private fun pendienteDe(t: Long): Pendiente = synchronized(pendientes) {
        val p = pendientes.getOrPut(t) { Pendiente() }
        while (pendientes.size > maxPendientes) {
            val vieja = pendientes.keys.first()
            pendientes.remove(vieja)
        }
        p
    }

    /** [timestampMs] estrictamente creciente. Devuelve false si ya hay manos en vuelo. */
    fun analizarManos(bitmap: Bitmap, timestampMs: Long): Boolean {
        synchronized(manosLock) {
            val ahora = System.nanoTime()
            if (manosEnVuelo && ahora - manosDesdeNs < timeoutNs) return false
            manosEnVuelo = true
            manosDesdeNs = ahora
        }
        pendienteDe(timestampMs)
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
        pendienteDe(timestampMs)
        val mpImage = BitmapImageBuilder(bitmap).build()
        poseLandmarker.detectAsync(mpImage, timestampMs)
        return true
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
        completar(t) { it.pose = arr; it.tienePose = true }

        val (izq, der) = synchronized(ultimoLock) {
            ultimaPose = arr
            ultimaIzq to ultimaDer
        }
        onPreview(FrameResult(t, arr, izq, der))
    }

    private fun onManos(result: HandLandmarkerResult) {
        synchronized(manosLock) { manosEnVuelo = false }

        val t = result.timestampMs()
        var izq: DoubleArray? = null
        var der: DoubleArray? = null

        val manos = result.landmarks()
        val lados = result.handednesses()
        for (i in manos.indices) {
            val lm = manos[i]
            if (lm.size < 21) continue
            val arr = DoubleArray(21 * 3)
            for (j in 0 until 21) {
                val p = lm[j]
                arr[j * 3] = p.x().toDouble()
                arr[j * 3 + 1] = p.y().toDouble()
                arr[j * 3 + 2] = p.z().toDouble()
            }
            // MediaPipe etiqueta la mano asumiendo imagen sin espejear. Con la
            // camara frontal el preview se ve espejeado pero el frame que
            // analizamos no lo esta, asi que la etiqueta es la correcta.
            val etiqueta = lados.getOrNull(i)?.firstOrNull()?.categoryName()
            if (etiqueta == "Left") izq = arr else der = arr
        }

        completar(t) { it.left = izq; it.right = der; it.tieneManos = true }

        val pose = synchronized(ultimoLock) {
            ultimaIzq = izq
            ultimaDer = der
            ultimaPose
        }
        onPreview(FrameResult(t, pose, izq, der))
    }

    private inline fun completar(t: Long, bloque: (Pendiente) -> Unit) {
        var listo: FrameResult? = null
        synchronized(pendientes) {
            val p = pendientes[t] ?: return
            bloque(p)
            if (p.tienePose && p.tieneManos) {
                pendientes.remove(t)
                listo = FrameResult(t, p.pose, p.left, p.right)
            }
        }
        listo?.let(onFrame)
    }

    fun cerrar() {
        handLandmarker.close()
        poseLandmarker.close()
        synchronized(pendientes) { pendientes.clear() }
        synchronized(ultimoLock) {
            ultimaPose = null
            ultimaIzq = null
            ultimaDer = null
        }
        synchronized(manosLock) { manosEnVuelo = false }
        synchronized(poseLock) { poseEnVuelo = false }
    }
}
