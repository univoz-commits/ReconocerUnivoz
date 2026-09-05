/// Puente de Dart hacia la camara nativa.
///
/// Recibe landmarks crudos por EventChannel y los convierte en frames
/// normalizados de 138 dimensiones, listos para el clasificador.
library camera_bridge;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'sign_norm.dart';

const String kCanalMetodos = 'univoz/camara';

// Fusionado: solo llegan frames donde pose y manos coinciden en el mismo
// timestamp exacto. Usar para normalizar/clasificar (DtwClassifier) o
// guardar muestras: ahi la ubicacion de la mano respecto al cuerpo tiene
// que ser exacta.
const String kCanalEventos = 'univoz/landmarks';

// Preview: llega un frame apenas termina CUALQUIERA de los dos modelos del
// lado nativo, sin esperar al otro (puede traer pose y manos de instantes
// ligeramente distintos). Es el que hay que usar para pintar el esqueleto
// en pantalla: se siente a tiempo real. No usar para guardar datos.
const String kCanalEventosPreview = 'univoz/landmarks_preview';

/// Un frame crudo tal como llega del lado nativo.
class LandmarkFrame {
  /// Milisegundos, estrictamente creciente.
  final int timestampMs;

  /// 33 landmarks de pose, cada uno [x, y, z, visibility]. Null si no hubo.
  final List<List<double>>? pose;

  /// 21 landmarks por mano, cada uno [x, y, z]. Null si esa mano no aparecio.
  final List<List<double>>? left;
  final List<List<double>>? right;

  const LandmarkFrame({
    required this.timestampMs,
    this.pose,
    this.left,
    this.right,
  });

  /// Decodifica desde el mapa que llega por el canal del lado nativo.
  /// [swapHands] cruza izquierda y derecha -- ver CameraBridge.cruzarManos.
  factory LandmarkFrame.fromMap(Map<Object?, Object?> map,
      {bool swapHands = false}) {
    final pose = _desempacar(map['pose'], 4);
    var izq = _desempacar(map['left'], 3);
    var der = _desempacar(map['right'], 3);
    if (swapHands) {
      final tmp = izq;
      izq = der;
      der = tmp;
    }
    return LandmarkFrame(
      timestampMs: (map['t'] as num).toInt(),
      pose: pose,
      left: izq,
      right: der,
    );
  }

  static List<List<double>>? _desempacar(Object? raw, int ancho) {
    if (raw == null) return null;
    final flat = raw is Float64List
        ? raw
        : Float64List.fromList(
            (raw as List).map((v) => (v as num).toDouble()).toList());
    final n = flat.length ~/ ancho;
    return List<List<double>>.generate(
      n,
      (i) => List<double>.generate(ancho, (j) => flat[i * ancho + j],
          growable: false),
      growable: false,
    );
  }

  /// Vector de 138 dimensiones, o null si el frame no sirve.
  List<double>? normalize() =>
      pose == null ? null : normalizeFrame(pose!, left: left, right: right);

  bool get tieneAlgunaMano => left != null || right != null;
}

/// Resultado de arrancar la camara.
class CamaraIniciada {
  final int textureId;

  /// True con camara frontal: el preview se pinta espejeado para que la
  /// persona se vea como en un espejo.
  final bool espejo;

  /// Resolucion real del preview, ya corregida por rotacion. 0 si el lado
  /// nativo todavia no la informa (versiones viejas de LandmarkPlugin.kt).
  final int ancho;
  final int alto;

  const CamaraIniciada(
    this.textureId,
    this.espejo, {
    this.ancho = 0,
    this.alto = 0,
  });

  /// Relacion de aspecto (ancho/alto) para usar en un widget AspectRatio.
  /// Si el nativo no informo dimensiones, cae al 3:4 tipico de CameraX.
  double get relacionAspecto => (ancho > 0 && alto > 0) ? ancho / alto : 3 / 4;
}

/// Puente hacia la camara nativa.
class CameraBridge {
  static const MethodChannel _metodos = MethodChannel(kCanalMetodos);
  static const EventChannel _eventos = EventChannel(kCanalEventos);
  static const EventChannel _eventosPreview =
      EventChannel(kCanalEventosPreview);

  /// Si esta activo, cruza mano izquierda y derecha en cada frame que llega
  /// por [frames] y [framesPreview]. Es el ajuste "Cruzar mano izquierda /
  /// derecha" de PantallaAjustes: el equivalente en vivo del --espejo de la
  /// ingesta por video, para cuando las señas de una sola mano salen
  /// sistematicamente confundidas. Se lee en cada frame, asi que cambiarlo
  /// aplica de inmediato sin reiniciar la camara.
  bool cruzarManos = false;

  Stream<LandmarkFrame>? _stream;
  Stream<LandmarkFrame>? _streamPreview;

  /// Pide permiso de camara antes de llamar esto (por ejemplo con
  /// permission_handler). El lado nativo no lo solicita.
  Future<CamaraIniciada> iniciar({bool frontal = true}) async {
    final r = await _metodos.invokeMapMethod<String, Object?>(
      'iniciar',
      {'frontal': frontal},
    );
    if (r == null) throw StateError('la camara no devolvio textura');
    return CamaraIniciada(
      (r['textureId'] as num).toInt(),
      r['espejo'] == true,
      ancho: (r['ancho'] as num?)?.toInt() ?? 0,
      alto: (r['alto'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> detener() async {
    await _metodos.invokeMethod<void>('detener');
    _stream = null;
    _streamPreview = null;
  }

  /// Stream de frames FUSIONADOS: pose y manos garantizadas del mismo
  /// instante. Es broadcast: se puede escuchar desde el reconocedor y para
  /// guardar muestras a la vez. Para pintar el esqueleto en vivo usa
  /// [framesPreview], que responde mucho mas rapido.
  Stream<LandmarkFrame> get frames {
    return _stream ??= _eventos
        .receiveBroadcastStream()
        .map((e) => LandmarkFrame.fromMap(e as Map<Object?, Object?>,
            swapHands: cruzarManos))
        .asBroadcastStream();
  }

  /// Stream de frames en vivo para UI: se actualiza apenas termina
  /// cualquiera de los dos modelos nativos, sin esperar a que coincidan.
  /// Puede traer pose y manos de instantes ligeramente distintos entre si
  /// -- para el ojo humano no se nota, y es lo que hace que el esqueleto en
  /// pantalla se sienta a tiempo real. No usar esto para normalizar ni
  /// guardar muestras (usa [frames] para eso).
  Stream<LandmarkFrame> get framesPreview {
    return _streamPreview ??= _eventosPreview
        .receiveBroadcastStream()
        .map((e) => LandmarkFrame.fromMap(e as Map<Object?, Object?>,
            swapHands: cruzarManos))
        .asBroadcastStream();
  }

  /// Solo los frames normalizables, ya como vectores de 138 dimensiones.
  Stream<({int t, List<double> vec})> get vectores => frames
      .map((f) => (t: f.timestampMs, vec: f.normalize()))
      .where((e) => e.vec != null)
      .map((e) => (t: e.t, vec: e.vec!));
}
