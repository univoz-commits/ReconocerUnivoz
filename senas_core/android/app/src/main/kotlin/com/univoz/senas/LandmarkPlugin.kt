package com.univoz.senas
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.Executors
/**
 * Puente entre CameraX + MediaPipe y Flutter.
 *
 * Por el canal viajan SOLO landmarks, nunca frames. Un frame de 720p son
 * megabytes por segundo cruzando el puente; los landmarks son ~2 KB. El
 * preview se muestra con una textura nativa, que Flutter pinta sin copiar
 * nada.
 */
class LandmarkPlugin(
    private val context: Context,
    private val messenger: BinaryMessenger,
    private val textureRegistry: TextureRegistry,
    private val lifecycleOwner: LifecycleOwner,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        const val CANAL_METODOS = "univoz/camara"

        // Fusionado: solo dispara cuando pose y manos estan dentro de una
        // ventana compatible de 120 ms. Usalo para guardar muestras o para
        // el clasificador (DtwClassifier).
        const val CANAL_EVENTOS = "univoz/landmarks"

        // Preview: dispara apenas termina CUALQUIERA de los dos modelos.
        // Es el que usa la UI en vivo (esqueleto en pantalla).
        const val CANAL_EVENTOS_PREVIEW = "univoz/landmarks_preview"

        // Resolucion que le pedimos a CameraX para el analisis (NO para el
        // preview, que se queda a full resolucion para verse bien).
        private val RESOLUCION_ANALISIS = Size(360, 480)

        // Manos intentan cada captura; Pose corre cada ~66 ms. El reparto
        // conserva cadena anatomica fresca y deja CPU para dedos a 30 FPS.
        // Render/preview continua independiente a 60 FPS.
        private const val INTERVALO_MIN_POSE_NS = 66_000_000L
    }
    private val principal = Handler(Looper.getMainLooper())
    private val ejecutor = Executors.newSingleThreadExecutor()
    private var sink: EventChannel.EventSink? = null
    private var sinkPreview: EventChannel.EventSink? = null
    private var engine: LandmarkEngine? = null
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var ultimoTimestamp = 0L
    private var ultimoPoseEnviadoNs = 0L

    // Cache de la matriz de rotacion: los grados no cambian frame a frame.
    private var gradosCacheados: Int? = null
    private var matrizCacheada: Matrix? = null

    fun registrar() {
        MethodChannel(messenger, CANAL_METODOS).setMethodCallHandler(this)
        EventChannel(messenger, CANAL_EVENTOS).setStreamHandler(this)
        EventChannel(messenger, CANAL_EVENTOS_PREVIEW).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sinkPreview = events
                }
                override fun onCancel(arguments: Any?) {
                    sinkPreview = null
                }
            }
        )
    }
    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "iniciar" -> {
                val frontal = call.argument<Boolean>("frontal") ?: true
                iniciar(frontal, result)
            }
            "detener" -> {
                detener()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }
    override fun onCancel(arguments: Any?) {
        sink = null
    }
    @SuppressLint("UnsafeOptInUsageError")
    private fun iniciar(frontal: Boolean, result: MethodChannel.Result) {
        val futuro = ProcessCameraProvider.getInstance(context)
        futuro.addListener({
            try {
                val provider = futuro.get()
                cameraProvider = provider
                provider.unbindAll()
                val texEntry = textureRegistry.createSurfaceTexture()
                entry = texEntry
                val surfaceTexture = texEntry.surfaceTexture()
                val preview = Preview.Builder().build()
                preview.setSurfaceProvider { request ->
                    surfaceTexture.setDefaultBufferSize(
                        request.resolution.width, request.resolution.height
                    )
                    val surface = Surface(surfaceTexture)
                    request.provideSurface(surface, ejecutor) { surface.release() }
                }
                val analysis = ImageAnalysis.Builder()
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    RESOLUCION_ANALISIS,
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER,
                                )
                            )
                            .build()
                    )
                    .build()
                engine = LandmarkEngine(
                    context,
                    onFrame = { emitir(it) },
                    onPreview = { emitirPreview(it) },
                    onError = { msg -> principal.post { sink?.error("mediapipe", msg, null) } },
                )
                analysis.setAnalyzer(ejecutor) { proxy -> procesar(proxy) }
                val selector = if (frontal) CameraSelector.DEFAULT_FRONT_CAMERA
                else CameraSelector.DEFAULT_BACK_CAMERA
                provider.bindToLifecycle(lifecycleOwner, selector, preview, analysis)

                val info = preview.resolutionInfo
                val res = info?.resolution
                val giro = info?.rotationDegrees ?: 0
                val volteado = giro == 90 || giro == 270
                val ancho = if (res == null) 0 else if (volteado) res.height else res.width
                val alto = if (res == null) 0 else if (volteado) res.width else res.height

                result.success(
                    mapOf(
                        "textureId" to texEntry.id(),
                        // Preview sin espejo: el eje horizontal debe coincidir
                        // con landmarks y asociación anatómica.
                        "espejo" to false,
                        "ancho" to ancho,
                        "alto" to alto,
                    )
                )
            } catch (e: Exception) {
                result.error("camara", e.message, null)
            }
        }, ContextCompat.getMainExecutor(context))
    }
    private fun procesar(proxy: ImageProxy) {
        try {
            val ahoraNs = proxy.imageInfo.timestamp
            val manosLibres = engine?.manosOcupadas() == false
            val tocaPose = engine?.poseOcupada() == false &&
                (ahoraNs - ultimoPoseEnviadoNs >= INTERVALO_MIN_POSE_NS)

            // Ninguno de los dos modelos quiere este frame: no gastes CPU
            // convirtiendolo a bitmap.
            if (!manosLibres && !tocaPose) return

            val rotacion = proxy.imageInfo.rotationDegrees
            val bitmap = rotar(proxy.toBitmap(), rotacion)
            var t = proxy.imageInfo.timestamp / 1_000_000
            if (t <= ultimoTimestamp) t = ultimoTimestamp + 1
            ultimoTimestamp = t

            if (manosLibres) engine?.analizarManos(bitmap, t)
            if (tocaPose) {
                engine?.analizarPose(bitmap, t)
                ultimoPoseEnviadoNs = ahoraNs
            }
        } catch (e: Exception) {
            principal.post { sink?.error("analisis", e.message, null) }
        } finally {
            proxy.close()
        }
    }
    private fun rotar(bitmap: Bitmap, grados: Int): Bitmap {
        if (grados == 0) return bitmap
        val m = if (gradosCacheados == grados) {
            matrizCacheada!!
        } else {
            Matrix().apply { postRotate(grados.toFloat()) }.also {
                matrizCacheada = it
                gradosCacheados = grados
            }
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, false)
    }
    private fun emitir(f: LandmarkEngine.FrameResult) {
        principal.post { sink?.success(aMapa(f)) }
    }

    private fun emitirPreview(f: LandmarkEngine.FrameResult) {
        principal.post { sinkPreview?.success(aMapa(f)) }
    }

    private fun aMapa(f: LandmarkEngine.FrameResult): HashMap<String, Any?> {
        val payload = HashMap<String, Any?>(13)
        payload["t"] = f.timestampMs
        payload["pose"] = f.pose
        // Esqueleto metrico en 3D: es el unico con el que se puede
        // reconstruir una postura (ver LandmarkEngine.FrameResult).
        payload["poseMundo"] = f.poseMundo
        payload["left"] = f.left
        payload["right"] = f.right
        payload["renderLeft"] = f.renderLeft
        payload["renderRight"] = f.renderRight
        payload["pose_t"] = f.poseTimestampMs
        payload["hands_t"] = f.handsTimestampMs
        payload["source_skew_ms"] = f.sourceSkewMs
        payload["association"] = f.association
        payload["errors"] = f.errors
        return payload
    }
    private fun detener() {
        cameraProvider?.unbindAll()
        cameraProvider = null
        engine?.cerrar()
        engine = null
        entry?.release()
        entry = null
        ultimoTimestamp = 0L
        ultimoPoseEnviadoNs = 0L
    }
    fun destruir() {
        detener()
        ejecutor.shutdown()
    }
}
