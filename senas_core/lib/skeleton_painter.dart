/// Pintor del esqueleto y pantalla de reconocimiento en vivo.
///
/// El pintor se usa con un ValueNotifier<LandmarkFrame> para que solo se
/// repinte cuando cambian los landmarks, no en cada setState.

import 'dart:async';

import 'package:flutter/material.dart';

import 'backend_api.dart';
import 'camera_bridge.dart';
import 'controlador_captura.dart';
import 'dtw.dart';
import 'muestras_locales.dart';
import 'plantillas.dart';
import 'voz.dart';

class SkeletonPainter extends CustomPainter {
  final LandmarkFrame? frame;

  static const double _minVisibility = 0.5;

  static const _colorCuerpo = Color(0xFF4A90E2);
  static const _colorMano = Color(0xFFFF6B6B);

  SkeletonPainter({this.frame});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || frame!.pose == null) return;

    final pose = frame!.pose!;

    // Pinta el cuerpo: cabeza, hombros, brazos, cadera
    _paintCuerpo(canvas, pose, size);

    // Pinta las manos
    if (frame!.left != null) {
      _paintMano(canvas, frame!.left!, size, esIzq: true);
    }
    if (frame!.right != null) {
      _paintMano(canvas, frame!.right!, size, esIzq: false);
    }
  }

  void _paintCuerpo(Canvas canvas, List<List<double>> pose, Size size) {
    final paint = Paint()
      ..color = _colorCuerpo
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    final puntoPaint = Paint()
      ..color = _colorCuerpo
      ..style = PaintingStyle.fill;

    // Indices reales de MediaPipe Pose (33 puntos, orden estandar de
    // BlazePose). LandmarkEngine.kt manda el arreglo crudo sin remapear.
    // Solo se dibuja la mitad superior (relevante para senas): cara,
    // hombros y brazos. Sin caderas/piernas a proposito.
    //
    // 0 nariz, 2/5 ojo izq/der, 7/8 oreja izq/der, 9/10 comisura boca
    // izq/der (MediaPipe no tiene un punto de menton propiamente; las
    // comisuras de la boca son la aproximacion mas cercana que existe),
    // 11/12 hombro izq/der, 13/14 codo izq/der, 15/16 muneca izq/der.
    const ramas = [
      (0, 2), // nariz - ojo izq
      (2, 7), // ojo izq - oreja izq
      (0, 5), // nariz - ojo der
      (5, 8), // ojo der - oreja der
      (0, 9), // nariz - comisura boca izq (zona menton)
      (0, 10), // nariz - comisura boca der (zona menton)
      (11, 12), // hombro izq - der
      (11, 13), // hombro izq - codo izq
      (13, 15), // codo izq - muneca izq
      (12, 14), // hombro der - codo der
      (14, 16), // codo der - muneca der
    ];

    for (final (a, b) in ramas) {
      if (a >= pose.length || b >= pose.length) continue;
      final pa = pose[a];
      final pb = pose[b];
      if (pa.length < 4 || pb.length < 4) continue;
      if (pa[3] < _minVisibility || pb[3] < _minVisibility) continue;
      if (!_puntoEnCuadro(pa) || !_puntoEnCuadro(pb)) continue;

      canvas.drawLine(
        _punto(pa, size),
        _punto(pb, size),
        paint,
      );
    }

    // Mismo criterio que ramas: solo los puntos de la mitad superior que
    // realmente usamos, no los 33 (si no, quedaban puntos sueltos de
    // cadera/pierna sin ninguna linea conectandolos).
    const puntosUsados = {0, 2, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
    for (final i in puntosUsados) {
      if (i >= pose.length) continue;
      final p = pose[i];
      if (p.length < 4 || p[3] < _minVisibility) continue;
      if (!_puntoEnCuadro(p)) continue;
      canvas.drawCircle(_punto(p, size), 3, puntoPaint);
    }
  }

  void _paintMano(
    Canvas canvas,
    List<List<double>> mano,
    Size size, {
    required bool esIzq,
  }) {
    final paint = Paint()
      ..color = _colorMano
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    final puntoPaint = Paint()
      ..color = _colorMano
      ..style = PaintingStyle.fill;

    // MediaPipe Hand: conexiones entre dedos (ver el modelo oficial)
    // Palma: 0-5, 5-9, 9-13, 13-17, 17-0
    // Dedos: 1-2-3-4, 5-6-7-8, 9-10-11-12, 13-14-15-16, 17-18-19-20
    const conexiones = [
      (0, 1),
      (1, 2),
      (2, 3),
      (3, 4),
      (0, 5),
      (5, 6),
      (6, 7),
      (7, 8),
      (5, 9),
      (9, 10),
      (10, 11),
      (11, 12),
      (9, 13),
      (13, 14),
      (14, 15),
      (15, 16),
      (13, 17),
      (17, 18),
      (18, 19),
      (19, 20),
      (0, 17),
    ];

    for (final (a, b) in conexiones) {
      if (a >= mano.length || b >= mano.length) continue;
      final pa = mano[a];
      final pb = mano[b];
      if (pa.length < 3 || pb.length < 3) continue;
      if (!_puntoEnCuadro(pa) || !_puntoEnCuadro(pb)) continue;

      canvas.drawLine(
        _punto3d(pa, size),
        _punto3d(pb, size),
        paint,
      );
    }

    for (final p in mano) {
      if (p.length < 3) continue;
      if (!_puntoEnCuadro(p)) continue;
      canvas.drawCircle(_punto3d(p, size), 2, puntoPaint);
    }
  }

  bool _puntoEnCuadro(List<double> p) =>
      p.length >= 3 &&
      p[0].isFinite && p[1].isFinite && p[2].isFinite &&
      p[0] >= 0 && p[0] <= 1 && p[1] >= 0 && p[1] <= 1;

  Offset _punto(List<double> p, Size size) {
    return Offset(p[0] * size.width, p[1] * size.height);
  }

  Offset _punto3d(List<double> p, Size size) => _punto(p, size);

  @override
  bool shouldRepaint(SkeletonPainter old) =>
      old.frame?.timestampMs != frame?.timestampMs;
}

/// Camara en vivo + reconocimiento contra el diccionario local.
class PantallaDeTranslacion extends StatefulWidget {
  const PantallaDeTranslacion({Key? key}) : super(key: key);

  @override
  State<PantallaDeTranslacion> createState() => _PantallaDeTranslacionState();
}

class _PantallaDeTranslacionState extends State<PantallaDeTranslacion>
    with WidgetsBindingObserver {
  final _ctrl = ControladorCaptura();
  final _almacen = AlmacenMuestras.instancia;
  final _voz = LectorVoz.instancia;
  final _backend = BackendApi();
  final _detector = DetectorAutomatico(
    // Menos frames quietos para cortar = reconoce mas rapido despues de
    // terminar la sena, a costa de ser un poco mas sensible a una micro
    // pausa en medio de un movimiento largo. 10 frames a ~30fps son ~0.33s.
    framesQuietosParaCortar: 10,
  );

  Diccionario? _dicc;
  String? _errorDiccionario;
  Prediction? _prediccion;
  List<MapEntry<double, Template>> _candidatas = const [];
  String? _aviso;
  BackendPrediction? _prediccionBackend;
  int _consultaBackend = 0;

  // ── Modo automático ──────────────────────────────────────────────────────
  bool _modoAuto = false;
  EstadoAuto _estadoAuto = EstadoAuto.quieto;

  // ── Volteo de cámara ─────────────────────────────────────────────────────
  bool _volteando = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ctrl.addListener(_alCambiar);
    _detector.onCambioEstado = (e) {
      if (mounted) setState(() => _estadoAuto = e);
    };
    _detector.onInicioDetectado = _autoIniciar;
    _detector.onFinDetectado = _autoFinalizar;
    _arrancar();
  }

  Future<void> _arrancar() async {
    await _almacen.cargar();
    if (!mounted) return;
    await _ctrl.iniciar(
      frontal: _almacen.ajustes.camaraFrontal,
      cruzarManos: _almacen.ajustes.cruzarManos,
    );
    if (!mounted) return;
    // Si ya estábamos en modo auto antes de que la cámara terminara de iniciar,
    // arrancamos el detector ahora que el stream está disponible.
    if (_modoAuto) _detector.iniciar(_ctrl.camara.framesPreview);
    try {
      final d = await cargarDiccionario();
      if (!mounted) return;
      setState(() {
        _dicc = d;
        _errorDiccionario = d.resumen.vacio
            ? 'El diccionario está vacío. Grabá muestras en "Agregar muestras", '
                'o exportá el paquete desde la PC con tools/exportar_paquete.py.'
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorDiccionario = e.toString());
    }
  }

  void _alCambiar() {
    if (mounted) setState(() {});
  }

  /// Cambia entre camara frontal y trasera sin salir de la pantalla, y deja
  /// el nuevo lado guardado en Ajustes para la proxima vez. No se permite en
  /// modo automatico ni mientras se esta grabando una seña: cortaria la
  /// captura a mitad de camino.
  Future<void> _voltearCamara() async {
    if (_volteando || _modoAuto || _ctrl.grabando || !_ctrl.lista) return;
    setState(() => _volteando = true);
    final nuevos = _almacen.ajustes.copiar()
      ..camaraFrontal = !_almacen.ajustes.camaraFrontal;
    try {
      await _ctrl.reiniciar(
        frontal: nuevos.camaraFrontal,
        cruzarManos: nuevos.cruzarManos,
      );
      await _almacen.guardarAjustes(nuevos);
    } finally {
      if (mounted) setState(() => _volteando = false);
    }
  }

  // ── Modo automático: activar/desactivar ───────────────────────────────────

  Future<void> _toggleModoAuto() async {
    if (_modoAuto) {
      // Desactivar: si estaba grabando, cancelar sin reconocer.
      if (_ctrl.grabando) await _ctrl.terminar();
      await _detector.detener();
      setState(() {
        _modoAuto = false;
        _estadoAuto = EstadoAuto.quieto;
      });
    } else {
      setState(() {
        _modoAuto = true;
        _prediccion = null;
        _candidatas = const [];
        _aviso = null;
      });
      // Solo arrancamos el detector si la cámara ya está lista.
      if (_ctrl.lista) _detector.iniciar(_ctrl.camara.framesPreview);
    }
  }

  /// Callback: el detector detectó inicio de movimiento.
  void _autoIniciar() {
    if (!mounted || !_ctrl.lista || _ctrl.grabando) return;
    _ctrl.empezar();
  }

  /// Callback: el detector detectó fin de movimiento → reconocer.
  void _autoFinalizar() {
    // Lanzamos el proceso asíncrono sin await porque este callback es síncrono.
    _procesarFinAuto();
  }

  Future<void> _procesarFinAuto() async {
    final nFrames = _ctrl.framesGrabados;
    final seq = await _ctrl.terminar();
    if (!mounted) return;

    // Secuencia demasiado corta o vacía: ignorar silenciosamente.
    if (seq == null || nFrames < _detector.minFramesParaReconocer) {
      _detector.entrarPausa(const Duration(milliseconds: 300), () {
        if (mounted) setState(() {});
      });
      return;
    }

    final dicc = _dicc;
    if (dicc == null) {
      _detector.entrarPausa(const Duration(milliseconds: 300), () {
        if (mounted) setState(() {});
      });
      return;
    }

    final ranking = dicc.clasificador.rank(seq);
    final pred = dicc.clasificador.classify(seq);

    final vistas = <String>{};
    final unicas = <MapEntry<double, Template>>[];
    for (final e in ranking) {
      if (vistas.add(e.value.gloss)) unicas.add(e);
      if (unicas.length >= 4) break;
    }

    setState(() {
      _prediccion = pred;
      _prediccionBackend = null;
      _candidatas = unicas;
      _aviso = null;
    });
    _consultarBackend(seq);

    if (pred.aceptada && _almacen.ajustes.hablarResultado) {
      _hablar(pred.textoHablado);
    }

    // Pausa corta para encadenar senas seguidas en una conversacion, sin
    // dejar de darle un instante al usuario para ver/escuchar el resultado.
    _detector.entrarPausa(const Duration(milliseconds: 900), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrl.removeListener(_alCambiar);
    _detector.detener();
    _ctrl.dispose();
    _backend.cerrar();
    _voz.detener();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _ctrl.error != null) {
      _arrancar();
    }
  }

  // ── Modo manual: alternar grabación ──────────────────────────────────────

  Future<void> _alternar() async {
    if (!_ctrl.grabando) {
      setState(() {
        _prediccion = null;
        _prediccionBackend = null;
        _candidatas = const [];
        _aviso = null;
      });
      _ctrl.empezar();
      return;
    }

    final seq = await _ctrl.terminar();
    if (!mounted) return;

    final dicc = _dicc;
    if (dicc == null) {
      setState(() => _aviso = 'El diccionario todavía no cargó.');
      return;
    }
    if (seq == null) {
      setState(() => _aviso =
          'No se capturó nada. Revisá que se vean los hombros y las manos en cámara.');
      return;
    }

    final ranking = dicc.clasificador.rank(seq);
    final pred = dicc.clasificador.classify(seq);

    final vistas = <String>{};
    final unicas = <MapEntry<double, Template>>[];
    for (final e in ranking) {
      if (vistas.add(e.value.gloss)) unicas.add(e);
      if (unicas.length >= 4) break;
    }

    setState(() {
      _prediccion = pred;
      _prediccionBackend = null;
      _candidatas = unicas;
      _aviso = null;
    });
    _consultarBackend(seq);

    if (pred.aceptada && _almacen.ajustes.hablarResultado) {
      _hablar(pred.textoHablado);
    }
  }

  void _hablar(String texto) {
    _voz.decir(texto).then((error) {
      if (error == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo hablar el resultado: $error')),
      );
    });
  }

  Future<void> _consultarBackend(List<List<double>> seq) async {
    if (!_backend.configurado) return;
    final revision = ++_consultaBackend;
    try {
      final resultado = await _backend.clasificar(seq);
      if (!mounted || revision != _consultaBackend) return;
      setState(() => _prediccionBackend = resultado);
    } catch (_) {
      // DTW local ya entregó resultado; caída de red nunca bloquea voz ni UI.
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final resumen = _dicc?.resumen;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reconocer seña'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // ── Franja de controles (fuera del AppBar para que Honor no la tape) ──
          Container(
            color: Colors.grey.shade100,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                // Stats a la izquierda
                Expanded(
                  child: resumen == null
                      ? const SizedBox.shrink()
                      : Text(
                          '${resumen.senasDistintas} señas · ${resumen.total} plantillas '
                          '(${resumen.sincronizadas + resumen.delPaquete} base, '
                          '${resumen.locales} local)',
                          style: const TextStyle(fontSize: 11),
                        ),
                ),
                // Botón voltear cámara
                IconButton(
                  iconSize: 26,
                  icon: _volteando
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.cameraswitch_outlined,
                          color: (_modoAuto || _ctrl.grabando || !_ctrl.lista)
                              ? Colors.grey
                              : Colors.blue.shade800),
                  tooltip: _almacen.ajustes.camaraFrontal
                      ? 'Cambiar a cámara trasera'
                      : 'Cambiar a cámara frontal',
                  onPressed: (_modoAuto || _ctrl.grabando || !_ctrl.lista)
                      ? null
                      : _voltearCamara,
                ),
                // Botón modo auto/manual
                IconButton(
                  iconSize: 26,
                  icon: Icon(
                    _modoAuto ? Icons.touch_app : Icons.auto_fix_high,
                    color: _modoAuto
                        ? Colors.orange.shade700
                        : Colors.blue.shade800,
                  ),
                  tooltip: _modoAuto
                      ? 'Cambiar a modo manual'
                      : 'Activar modo automático',
                  onPressed: _toggleModoAuto,
                ),
              ],
            ),
          ),
          Expanded(child: _preview()),
          _panelInferior(),
        ],
      ),
    );
  }

  Widget _preview() {
    if (_ctrl.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_ctrl.error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                  onPressed: _arrancar, child: const Text('Reintentar')),
            ],
          ),
        ),
      );
    }

    final camara = _ctrl.iniciada;
    if (camara == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: camara.relacionAspecto,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Texture(textureId: camara.textureId),
                ),
                ValueListenableBuilder<LandmarkFrame?>(
                  valueListenable: _ctrl.frame,
                  builder: (_, frame, __) => CustomPaint(
                    painter: SkeletonPainter(frame: frame),
                    size: Size.infinite,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_ctrl.grabando)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('● ${_ctrl.framesGrabados} frames',
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ),
        // Indicador de estado en modo automático
        if (_modoAuto)
          Positioned(
            top: 8,
            left: 8,
            child: _chipEstadoAuto(),
          ),
      ],
    );
  }

  Widget _chipEstadoAuto() {
    final (texto, color) = switch (_estadoAuto) {
      EstadoAuto.quieto => ('👁 Esperando seña...', Colors.black54),
      EstadoAuto.grabando => ('⏺ Grabando...', Colors.red.shade700),
      EstadoAuto.reconociendo => ('🔍 Reconociendo...', Colors.blue.shade700),
      EstadoAuto.pausa => ('✓ Listo', Colors.green.shade700),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(texto,
          style: const TextStyle(
              color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
    );
  }

  Widget _panelInferior() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_prediccion != null) _tarjetaResultado(_prediccion!),
            if (_prediccionBackend?.label != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Backend: ${_prediccionBackend!.label} · '
                  '${(_prediccionBackend!.confidence * 100).round()}% · '
                  '${_prediccionBackend!.classifier}',
                  style:
                      TextStyle(fontSize: 11, color: Colors.blueGrey.shade600),
                ),
              ),
            if (_candidatas.length > 1) _listaCandidatas(),
            if (_aviso != null) _cinta(_aviso!, Colors.orange.shade800),
            if (_errorDiccionario != null)
              _cinta(_errorDiccionario!, Colors.blueGrey.shade700, chico: true),
            if (_modoAuto)
              // Modo automático: solo un botón para volver al modo manual
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _toggleModoAuto,
                  icon: const Icon(Icons.touch_app),
                  label: const Text('Desactivar modo automático'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              )
            else
              // Modo manual: botón grabar/detener de siempre
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _ctrl.lista ? _alternar : null,
                  icon: Icon(
                      _ctrl.grabando ? Icons.stop : Icons.fiber_manual_record),
                  label: Text(
                      _ctrl.grabando ? 'Detener y reconocer' : 'Grabar seña'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _ctrl.grabando ? Colors.red : null,
                    foregroundColor: _ctrl.grabando ? Colors.white : null,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _cinta(String texto, Color color, {bool chico = false}) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration:
            BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
        child: Text(texto,
            style: TextStyle(color: Colors.white, fontSize: chico ? 12 : 13)),
      );

  Widget _tarjetaResultado(Prediction pred) {
    final ok = pred.aceptada;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ok ? Colors.green.shade700 : Colors.orange.shade800,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  ok ? pred.textoHablado : 'No reconocida con confianza',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 22),
                ),
              ),
              if (ok)
                IconButton(
                  icon: const Icon(Icons.volume_up, color: Colors.white),
                  tooltip: 'Repetir en voz alta',
                  onPressed: () => _hablar(pred.textoHablado),
                ),
            ],
          ),
          if (!ok && pred.gloss != null)
            Text('la más parecida fue ${pred.textoHablado}',
                style: const TextStyle(color: Colors.white70)),
          Text(
            'distancia ${pred.distance.toStringAsFixed(3)} '
            '(máx ${_almacen.ajustes.maxDistance.toStringAsFixed(2)})  ·  '
            'margen ${pred.margin.toStringAsFixed(3)} '
            '(mín ${_almacen.ajustes.minMargin.toStringAsFixed(2)})',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _listaCandidatas() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('otras candidatas',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
          const SizedBox(height: 4),
          for (final e in _candidatas.skip(1))
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(e.value.gloss, style: const TextStyle(fontSize: 13)),
                  Text(e.key.toStringAsFixed(3),
                      style:
                          TextStyle(fontSize: 13, color: Colors.grey.shade700)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
