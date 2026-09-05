/// Ciclo de vida de la camara + grabacion de una sena.
///
/// Lo comparten la pantalla de reconocimiento y la de captura de muestras:
/// las dos necesitan exactamente lo mismo (preview en vivo, esqueleto, y un
/// buffer de frames ya normalizados) y solo se diferencian en que hacen con
/// la secuencia al final. Tenerlo en un solo lugar evita que las dos
/// pantallas se desincronicen cuando cambie el pipeline.
library controlador_captura;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'camera_bridge.dart';
import 'sign_norm.dart' show kTFrames, resample;

class ControladorCaptura extends ChangeNotifier {
  final CameraBridge camara = CameraBridge();

  /// Ultimo frame para pintar el esqueleto. Va aparte del ChangeNotifier
  /// para que el preview se repinte a 30 fps sin reconstruir la pantalla
  /// entera en cada frame.
  final ValueNotifier<LandmarkFrame?> frame = ValueNotifier<LandmarkFrame?>(null);

  CamaraIniciada? iniciada;
  String? error;
  bool grabando = false;
  bool _apagado = false;

  StreamSubscription? _subPreview;
  StreamSubscription? _subGrabacion;
  final List<List<double>> _buffer = [];

  /// Cuantos frames utilizables lleva la grabacion en curso.
  int get framesGrabados => _buffer.length;
  bool get lista => iniciada != null;

  Future<void> iniciar({bool frontal = true, bool cruzarManos = false}) async {
    camara.cruzarManos = cruzarManos;
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
    grabando = true;
    _notificar();
    _subGrabacion = camara.vectores.listen((e) {
      if (_apagado) return;
      _buffer.add(e.vec);
      if (_buffer.length % 5 == 0) _notificar();
    });
  }

  Future<List<List<double>>?> terminar() async {
    await _subGrabacion?.cancel();
    _subGrabacion = null;
    grabando = false;
    _notificar();
    if (_buffer.isEmpty) return null;
    return resample(List.of(_buffer), kTFrames);
  }

  Future<void> reiniciar({required bool frontal, required bool cruzarManos}) async {
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
