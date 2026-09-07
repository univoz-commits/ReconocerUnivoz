/// Modo espejo: la camara te sigue y el avatar copia tus movimientos en
/// vivo, sin grabar ni reconocer nada.
///
/// Sirve para dos cosas. La primera es demostrativa: es la forma mas directa
/// de ver que el pipeline completo funciona de punta a punta. La segunda es
/// de desarrollo, y es la razon por la que existe: calibrar el visor contra
/// plantillas grabadas es lento y a ciegas, porque si la sena no se ve bien
/// no se sabe si la culpa es del dato o del render. Aca moves la mano y ves
/// el resultado al instante, con la referencia delante.
///
/// El camino del dato es el mismo de siempre, solo que sin buffer:
///   camara nativa -> LandmarkFrame -> sign_norm (138 dims) -> avatar
library pantalla_espejo;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'avatar_bridge.dart';
import 'camera_bridge.dart';
import 'controlador_captura.dart';
import 'skeleton_painter.dart' show SkeletonPainter;

/// Cada cuanto se le manda un frame al WebView. La camara entrega a ~30 fps,
/// pero cada envio cruza el puente de JavaScript y ademas obliga a redibujar
/// la escena 3D. A 30 fps el telefono se satura y el avatar se siente MAS
/// lento, no mas rapido, porque los mensajes se encolan. 20 fps se ve fluido
/// y deja aire para que MediaPipe siga corriendo.
const Duration kIntervaloEnvio = Duration(milliseconds: 50);

class PantallaEspejo extends StatefulWidget {
  const PantallaEspejo({super.key});

  @override
  State<PantallaEspejo> createState() => _PantallaEspejoState();
}

class _PantallaEspejoState extends State<PantallaEspejo> {
  final _ctrl = ControladorCaptura();
  final _bridge = AvatarBridge();

  StreamSubscription<LandmarkFrame>? _sub;
  DateTime _ultimoEnvio = DateTime.fromMillisecondsSinceEpoch(0);

  /// True mientras hay un frame viajando al WebView. Sin esto los envios se
  /// encolan y el avatar termina arrastrando varios segundos de retraso.
  bool _enVuelo = false;

  bool _espejando = false;
  bool _mostrarCamara = true;
  String? _aviso;
  int _framesEnviados = 0;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_alCambiar);
    _bridge.onPoseCapturada = _copiarPose;
    _arrancar();
  }

  /// Llega desde el boton "Copiar pose" del editor del visor. Se copia al
  /// portapapeles para poder pegarlo donde sea -- transcribir angulos a mano
  /// desde la pantalla del telefono no es realista.
  Future<void> _copiarPose(String texto) async {
    await Clipboard.setData(ClipboardData(text: texto));
    if (!mounted) return;
    final lineas = texto.split('\n').length;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Pose copiada al portapapeles ($lineas líneas)'),
      duration: const Duration(seconds: 2),
    ));
  }

  void _alCambiar() {
    if (mounted) setState(() {});
  }

  Future<void> _arrancar() async {
    final permiso = await Permission.camera.request();
    if (!permiso.isGranted) {
      if (mounted) {
        setState(() => _aviso = 'Sin permiso de camara no puedo hacer espejo.');
      }
      return;
    }
    await _ctrl.iniciar(frontal: true);
    if (!mounted) return;
    _empezarEspejo();
  }

  void _empezarEspejo() {
    _sub?.cancel();
    _sub = _ctrl.camara.framesPreview.listen(_alFrame);
    setState(() => _espejando = true);
  }

  void _pararEspejo() {
    _sub?.cancel();
    _sub = null;
    setState(() => _espejando = false);
  }

  Future<void> _alFrame(LandmarkFrame f) async {
    if (!_espejando || _enVuelo) return;

    final ahora = DateTime.now();
    if (ahora.difference(_ultimoEnvio) < kIntervaloEnvio) return;

    // normalize() devuelve null si no hay pose usable (persona fuera de
    // cuadro, hombros no visibles). En ese caso simplemente no se manda
    // nada y el avatar se queda en la ultima pose, que se ve mejor que un
    // salto a reposo cada vez que el tracking parpadea.
    final v = f.normalize();
    if (v == null) return;

    _ultimoEnvio = ahora;
    _enVuelo = true;
    try {
      await _bridge.mostrarFrame(v);
      if (mounted) _framesEnviados++;
    } catch (_) {
      // El WebView puede no estar listo todavia (el VRM tarda en cargar).
      // No es un error que valga la pena mostrar: el siguiente frame llega
      // en 50 ms.
    } finally {
      _enVuelo = false;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ctrl.removeListener(_alCambiar);
    _ctrl.dispose();
    _bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Espejo'),
        actions: [
          IconButton(
            icon: Icon(_mostrarCamara
                ? Icons.videocam_outlined
                : Icons.videocam_off_outlined),
            tooltip: _mostrarCamara ? 'Ocultar camara' : 'Mostrar camara',
            onPressed: () => setState(() => _mostrarCamara = !_mostrarCamara),
          ),
        ],
      ),
      // El avatar y el preview van APILADOS EN COLUMNA, no superpuestos.
      // En Android el WebView es una platform view que dibuja el sistema, no
      // Flutter, y un Texture (el preview de la camara) puesto encima dentro
      // de un Stack queda tapado por la superficie del WebView. Separandolos
      // en filas el problema no existe.
      body: Column(
        children: [
          if (_aviso != null || _ctrl.error != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.shade800,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_aviso ?? 'La camara no arranco: ${_ctrl.error}',
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          Expanded(
            child: WebViewWidget(controller: _bridge.controller),
          ),
          _barra(),
        ],
      ),
    );
  }

  Widget _preview() {
    final camara = _ctrl.iniciada;
    if (camara == null) {
      return const AspectRatio(
        aspectRatio: 3 / 4,
        child: ColoredBox(
          color: Colors.black26,
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: camara.relacionAspecto,
        child: Stack(
          children: [
            Positioned.fill(child: Texture(textureId: camara.textureId)),
            ValueListenableBuilder<LandmarkFrame?>(
              valueListenable: _ctrl.frame,
              builder: (_, frame, __) => CustomPaint(
                painter: SkeletonPainter(frame: frame, espejo: camara.espejo),
                size: Size.infinite,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _barra() {
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.black87,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_mostrarCamara)
              SizedBox(width: 96, child: _preview()),
            if (_mostrarCamara) const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder<LandmarkFrame?>(
                    valueListenable: _ctrl.frame,
                    builder: (_, frame, __) => _estado(frame),
                  ),
                  const SizedBox(height: 6),
                  Text('$_framesEnviados frames enviados',
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11)),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _ctrl.lista
                          ? (_espejando ? _pararEspejo : _empezarEspejo)
                          : null,
                      icon: Icon(_espejando ? Icons.pause : Icons.play_arrow),
                      label: Text(_espejando ? 'Pausar' : 'Reanudar'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Mismo criterio que el chip de pantalla_captura: si el cuerpo no se ve,
  /// normalize() devuelve null y el avatar no se mueve por mas que las manos
  /// esten perfectas. Conviene que eso sea visible de un vistazo.
  Widget _estado(LandmarkFrame? frame) {
    Widget punto(String texto, bool ok) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text(
            '${ok ? "✓" : "✗"} $texto',
            style: TextStyle(
              fontSize: 12,
              color: ok ? Colors.greenAccent.shade400 : Colors.white54,
            ),
          ),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      punto('Cuerpo', frame?.pose != null),
      punto('Izq', frame?.left != null),
      punto('Der', frame?.right != null),
    ]);
  }
}
