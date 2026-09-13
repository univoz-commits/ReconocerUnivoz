/// Ciclo de vida de la camara + grabacion de una sena.
///
/// Lo comparten la pantalla de reconocimiento y la de captura de muestras:
/// las dos necesitan exactamente lo mismo (preview en vivo, esqueleto, y un
/// buffer de frames ya normalizados) y solo se diferencian en que hacen con
/// la secuencia al final. Tenerlo en un solo lugar evita que las dos
/// pantallas se desincronicen cuando cambie el pipeline.
library controlador_captura;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';

import 'camera_bridge.dart';
import 'motion_contract.dart';
import 'sign_norm.dart' show fillGaps, kTFrames, resample;

/// Resultado completo de una captura. La secuencia normalizada alimenta DTW
/// y el modelo; los landmarks crudos permiten auditar o re-normalizar sin
/// guardar video.
class CapturaMovimiento {
  final MotionSequenceV2 secuencia;
  final List<LandmarkFrame> framesCrudos;
  final int framesInvalidos;
  final double? fps;
  final int? duracionMs;
  final double? visibilidadMin;
  final double qualityScore;
  final String checksumSha256;

  CapturaMovimiento({
    required this.secuencia,
    required List<LandmarkFrame> framesCrudos,
    required this.framesInvalidos,
    required this.fps,
    required this.duracionMs,
    required this.visibilidadMin,
    required this.qualityScore,
    required this.checksumSha256,
  }) : framesCrudos = List<LandmarkFrame>.unmodifiable(framesCrudos);

  Map<String, dynamic> toJson() => {
        'schema': 'MotionCaptureV1',
        'sequence': secuencia.toJson(),
        'frames': framesCrudos.map((frame) => frame.toJson()).toList(),
        'frames_invalidos': framesInvalidos,
        if (fps != null) 'fps': fps,
        if (duracionMs != null) 'duracion_ms': duracionMs,
        if (visibilidadMin != null) 'visibilidad_min': visibilidadMin,
        'quality_score': qualityScore,
        'checksum_sha256': checksumSha256,
      };
}

class ControladorCaptura extends ChangeNotifier {
  final CameraBridge camara = CameraBridge();

  /// Ultimo frame para pintar el esqueleto. Va aparte del ChangeNotifier
  /// para que el preview se repinte a 30 fps sin reconstruir la pantalla
  /// entera en cada frame.
  final ValueNotifier<LandmarkFrame?> frame =
      ValueNotifier<LandmarkFrame?>(null);

  CamaraIniciada? iniciada;
  String? error;
  bool grabando = false;
  bool _apagado = false;

  StreamSubscription? _subPreview;
  StreamSubscription? _subGrabacion;
  final List<List<double>> _buffer = [];
  final List<List<double>?> _bufferConHuecos = [];
  final List<LandmarkFrame> _framesCrudos = [];
  int _framesInvalidos = 0;

  /// Cuantos frames utilizables lleva la grabacion en curso.
  int get framesGrabados => _buffer.length;
  int get framesRecibidos => _framesCrudos.length;
  int get framesInvalidos => _framesInvalidos;
  bool get lista => iniciada != null;

  Future<void> iniciar({bool frontal = true, bool cruzarManos = false}) async {
    // Parámetro legado para no romper llamadas existentes. El motor resuelve
    // lado anatómico por cadena hombro-codo-muñeca y nunca cruza frames.
    camara.cruzarManos = false;
    iniciada = null;
    error = null;
    _notificar();
    try {
      final c = await camara.iniciar(frontal: frontal);
      _subPreview = camara.framesPreview.listen(
        (f) {
          if (_apagado) return;
          frame.value = f;
        },
        onError: (e) {
          error = e.toString();
          _notificar();
        },
      );
      iniciada = c;
    } catch (e) {
      error = e.toString();
    }
    _notificar();
  }

  void empezar() {
    _buffer.clear();
    _bufferConHuecos.clear();
    _framesCrudos.clear();
    _framesInvalidos = 0;
    grabando = true;
    _notificar();
    _subGrabacion = camara.frames.listen((f) {
      if (_apagado) return;
      _framesCrudos.add(f);
      final vec = f.normalize();
      _bufferConHuecos.add(vec);
      if (vec == null) {
        _framesInvalidos++;
      } else {
        _buffer.add(vec);
      }
      if (_framesCrudos.length % 5 == 0) _notificar();
    });
  }

  /// Finaliza y devuelve secuencia, landmarks crudos y métricas.
  Future<CapturaMovimiento?> terminarCaptura() async {
    await _subGrabacion?.cancel();
    _subGrabacion = null;
    grabando = false;
    _notificar();
    if (_buffer.isEmpty) return null;

    final rellenada = fillGaps(List.of(_bufferConHuecos));
    final remuestreada =
        rellenada == null ? null : resample(rellenada, kTFrames);
    if (remuestreada == null) return null;

    final timestamps = _framesCrudos.map((frame) => frame.timestampMs).toList();
    final primero = timestamps.isEmpty ? null : timestamps.first;
    final ultimo = timestamps.isEmpty ? null : timestamps.last;
    final duracion = primero != null && ultimo != null && ultimo >= primero
        ? ultimo - primero
        : null;
    final fps = duracion != null && duracion > 0 && timestamps.length > 1
        ? (timestamps.length - 1) * 1000 / duracion
        : null;
    final visibilidades = _framesCrudos
        .map((frame) => frame.visibilidadMin)
        .whereType<double>()
        .toList();
    final visibilidadMin = visibilidades.isEmpty
        ? null
        : visibilidades.reduce((a, b) => a < b ? a : b);
    final qualityScore =
        _framesCrudos.isEmpty ? 0.0 : _buffer.length / _framesCrudos.length;
    final secuencia = MotionSequenceV2.fromFrames(
      remuestreada,
      fps: fps?.round().clamp(1, 120) ?? 30,
      timestampsMs: List.generate(kTFrames, (i) {
        if (duracion == null) return i * 33;
        return primero! + (duracion * i / (kTFrames - 1)).round();
      }),
    );
    final rawJson =
        jsonEncode(_framesCrudos.map((frame) => frame.toJson()).toList());
    final checksum = sha256.convert(utf8.encode(rawJson)).toString();
    return CapturaMovimiento(
      secuencia: secuencia,
      framesCrudos: _framesCrudos,
      framesInvalidos: _framesInvalidos,
      fps: fps,
      duracionMs: duracion,
      visibilidadMin: visibilidadMin,
      qualityScore: qualityScore,
      checksumSha256: checksum,
    );
  }

  /// Compatibilidad para reconocimiento: devuelve solo secuencia.
  Future<List<List<double>>?> terminar() async {
    return (await terminarCaptura())
        ?.secuencia
        .frames
        .map((frame) => List<double>.from(frame))
        .toList();
  }

  Future<void> reiniciar(
      {required bool frontal, required bool cruzarManos}) async {
    await _subGrabacion?.cancel();
    _subGrabacion = null;
    grabando = false;
    await _subPreview?.cancel();
    _subPreview = null;
    await camara.detener();
    await iniciar(frontal: frontal, cruzarManos: cruzarManos);
  }

  Future<void> apagar() async {
    _apagado = true;
    await _subPreview?.cancel();
    await _subGrabacion?.cancel();
    _subPreview = null;
    _subGrabacion = null;
    await camara.detener();
  }

  void _notificar() {
    if (!_apagado) notifyListeners();
  }

  @override
  void dispose() {
    apagar();
    frame.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Reconocimiento automatico
// ---------------------------------------------------------------------------

/// Estados posibles del reconocedor automatico de senas.
enum EstadoAuto { quieto, grabando, reconociendo, pausa }

/// Detecta inicio y fin de una sena mirando el movimiento de las manos
/// en el stream de preview de la camara, sin necesidad de un boton.
class DetectorAutomatico {
  /// Promedio de cambio por coordenada (x, y) de los landmarks de la mano
  /// entre frames consecutivos (coordenadas normalizadas 0-1).
  /// 0.015 aprox 1.5% del ancho de pantalla por frame.
  final double umbralMovimiento;

  /// Frames consecutivos quietos antes de declarar que la sena termino.
  /// A ~30 fps: 20 aprox 0.67 segundos.
  final int framesQuietosParaCortar;

  /// Frames minimos grabados para que valga la pena reconocer.
  final int minFramesParaReconocer;

  DetectorAutomatico({
    this.umbralMovimiento = 0.015,
    this.framesQuietosParaCortar = 20,
    this.minFramesParaReconocer = 8,
  });

  EstadoAuto _estado = EstadoAuto.quieto;
  EstadoAuto get estado => _estado;

  LandmarkFrame? _frameAnterior;
  int _framesQuietos = 0;
  StreamSubscription<LandmarkFrame>? _sub;

  void Function()? onInicioDetectado;
  void Function()? onFinDetectado;
  void Function(EstadoAuto)? onCambioEstado;

  void iniciar(Stream<LandmarkFrame> preview) {
    _sub?.cancel();
    _resetContadores();
    _sub = preview.listen(_procesarFrame);
  }

  double _calcularMovimiento(LandmarkFrame ant, LandmarkFrame act) {
    double suma = 0;
    int n = 0;

    void agregarMano(List<List<double>>? a, List<List<double>>? b) {
      if (a == null || b == null) return;
      final len = a.length < b.length ? a.length : b.length;
      for (int i = 0; i < len; i++) {
        suma += (b[i][0] - a[i][0]).abs();
        suma += (b[i][1] - a[i][1]).abs();
        n += 2;
      }
    }

    agregarMano(ant.left, act.left);
    agregarMano(ant.right, act.right);
    return n > 0 ? suma / n : 0.0;
  }

  void _procesarFrame(LandmarkFrame frame) {
    if (_estado == EstadoAuto.reconociendo || _estado == EstadoAuto.pausa) {
      _frameAnterior = null;
      return;
    }

    final anterior = _frameAnterior;
    _frameAnterior = frame;
    if (anterior == null) return;

    final tieneManos = frame.left != null || frame.right != null;
    final mov = tieneManos ? _calcularMovimiento(anterior, frame) : 0.0;
    final hayMovimiento = mov > umbralMovimiento;

    if (_estado == EstadoAuto.quieto) {
      if (hayMovimiento) {
        _framesQuietos = 0;
        _cambiarEstado(EstadoAuto.grabando);
        onInicioDetectado?.call();
      }
    } else if (_estado == EstadoAuto.grabando) {
      if (!hayMovimiento) {
        _framesQuietos++;
        if (_framesQuietos >= framesQuietosParaCortar) {
          _cambiarEstado(EstadoAuto.reconociendo);
          onFinDetectado?.call();
        }
      } else {
        _framesQuietos = 0;
      }
    }
  }

  void _cambiarEstado(EstadoAuto nuevo) {
    if (_estado == nuevo) return;
    _estado = nuevo;
    onCambioEstado?.call(nuevo);
  }

  void entrarPausa(Duration duracion, VoidCallback alVolver) {
    _cambiarEstado(EstadoAuto.pausa);
    Future.delayed(duracion, () {
      _resetContadores();
      _cambiarEstado(EstadoAuto.quieto);
      alVolver();
    });
  }

  Future<void> detener() async {
    await _sub?.cancel();
    _sub = null;
    _resetContadores();
    _estado = EstadoAuto.quieto;
  }

  void _resetContadores() {
    _frameAnterior = null;
    _framesQuietos = 0;
  }
}
