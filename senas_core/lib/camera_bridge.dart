/// Puente de Dart hacia la camara nativa.
///
/// Recibe landmarks crudos por EventChannel y los convierte en frames
/// normalizados de 152 dimensiones, listos para el clasificador.
library camera_bridge;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'sign_norm.dart';

const String kCanalMetodos = 'univoz/camara';

// Fusionado: solo llegan frames donde pose y manos estan dentro de una
// ventana temporal compatible de 120 ms. Usar para normalizar/clasificar
// (DtwClassifier) o guardar muestras; preview queda separado para UI.
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

  /// 33 landmarks de pose en coordenadas de imagen, cada uno
  /// [x, y, z, visibility]. Null si no hubo. Son los que se pintan sobre el
  /// preview de la camara.
  final List<List<double>>? pose;

  /// 33 landmarks de pose en METROS, cada uno [x, y, z], con origen en el
  /// punto medio de las caderas. Es el esqueleto 3D real.
  ///
  /// Existe aparte de [pose] porque la Z de las coordenadas de imagen es
  /// solo una profundidad relativa aproximada: se midio incoherente entre
  /// puntos vecinos (un antebrazo de 0.8 anchos de hombro con 3.5 de
  /// recorrido en Z), asi que no sirve para reconstruir una postura. La
  /// normalizacion usa esta y no aquella.
  final List<List<double>>? poseMundo;

  /// 21 landmarks por mano, cada uno [x, y, z]. Null si esa mano no aparecio.
  final List<List<double>>? left;
  final List<List<double>>? right;
  final List<List<double>>? renderLeft;
  final List<List<double>>? renderRight;

  /// Timestamps reales de cada detector. Permiten medir la fusion en vez de
  /// esconder hasta 120 ms de desfase bajo un único [timestampMs].
  final int? poseTimestampMs;
  final int? handsTimestampMs;
  final int? sourceSkewMs;
  final Map<String, dynamic> association;
  final List<Map<String, dynamic>> errors;

  const LandmarkFrame({
    required this.timestampMs,
    this.pose,
    this.poseMundo,
    this.left,
    this.right,
    this.renderLeft,
    this.renderRight,
    this.poseTimestampMs,
    this.handsTimestampMs,
    this.sourceSkewMs,
    this.association = const {},
    this.errors = const [],
  });

  /// Decodifica desde el mapa que llega por el canal del lado nativo.
  /// [swapHands] cruza izquierda y derecha -- ver CameraBridge.cruzarManos.
  factory LandmarkFrame.fromMap(Map<Object?, Object?> map,
      {bool swapHands = false}) {
    final pose = _desempacar(map['pose'], 4);
    final poseMundo = _desempacar(map['poseMundo'], 3);
    var izq = _desempacar(map['left'], 3);
    var der = _desempacar(map['right'], 3);
    var renderIzq = _desempacar(map['renderLeft'] ?? map['render_left'], 3);
    var renderDer = _desempacar(map['renderRight'] ?? map['render_right'], 3);
    if (swapHands) {
      final tmp = izq;
      izq = der;
      der = tmp;
      final tmpRender = renderIzq;
      renderIzq = renderDer;
      renderDer = tmpRender;
    }
    final poseT = (map['pose_t'] as num?)?.toInt();
    final handsT = (map['hands_t'] as num?)?.toInt();
    final explicitSkew = (map['source_skew_ms'] as num?)?.toInt();
    final association = map['association'] is Map
        ? (map['association'] as Map)
            .map((key, value) => MapEntry(key.toString(), value))
        : const <String, dynamic>{};
    final errors = map['errors'] is List
        ? (map['errors'] as List)
            .whereType<Map>()
            .map((error) =>
                error.map((key, value) => MapEntry(key.toString(), value)))
            .toList(growable: false)
        : const <Map<String, dynamic>>[];
    return LandmarkFrame(
      timestampMs: (map['t'] as num).toInt(),
      pose: pose,
      poseMundo: poseMundo,
      left: izq,
      right: der,
      renderLeft: renderIzq,
      renderRight: renderDer,
      poseTimestampMs: poseT,
      handsTimestampMs: handsT,
      sourceSkewMs: explicitSkew ??
          (poseT != null && handsT != null ? (poseT - handsT).abs() : null),
      association: association,
      errors: errors,
    );
  }

  static List<List<double>>? _desempacar(Object? raw, int ancho) {
    if (raw == null) return null;
    if (raw is List && raw.isNotEmpty && raw.first is List) {
      return raw
          .map((row) => (row as List)
              .map((value) => (value as num).toDouble())
              .toList(growable: false))
          .toList(growable: false);
    }
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

  /// Vector de 152 dimensiones, o null si el frame no sirve.
  ///
  /// Necesita [poseMundo]: sin el esqueleto metrico no hay forma de
  /// reconstruir la postura. Si el nativo no lo manda (version vieja del
  /// plugin), devuelve null.
  List<double>? normalize() =>
      (!fusionAceptada || pose == null || poseMundo == null)
          ? null
          : normalizeFrame(pose!, poseMundo!, left: left, right: right);

  /// Frame efímero para avatar. Puede contener muñeca predicha y última forma
  /// durante oclusión; nunca se usa para grabación ni reconocimiento.
  List<double>? normalizeForRender() =>
      (!fusionAceptada || pose == null || poseMundo == null)
          ? null
          : normalizeFrame(
              pose!,
              poseMundo!,
              left: renderLeft ?? left,
              right: renderRight ?? right,
            );

  bool get fusionAceptada => (sourceSkewMs ?? 0).abs() <= 120;
  bool get requiereProyeccionRender {
    final skew = (sourceSkewMs ?? 0).abs();
    return skew > 50 && skew <= 120;
  }

  bool get tieneAlgunaMano => left != null || right != null;

  /// Visibilidad mínima de hombros. Se guarda como métrica de calidad; no se
  /// inventa visibilidad para worldLandmarks porque MediaPipe no la entrega.
  double? get visibilidadMin {
    final p = pose;
    if (p == null || p.length <= kRShoulder) return null;
    if (p[kLShoulder].length < 4 || p[kRShoulder].length < 4) return null;
    return p[kLShoulder][3] < p[kRShoulder][3]
        ? p[kLShoulder][3]
        : p[kRShoulder][3];
  }

  /// Contrato de persistencia para landmarks crudos sin video.
  Map<String, dynamic> toJson() => {
        'schema': 'LandmarkFrameV1',
        't': timestampMs,
        'pose': pose,
        'poseMundo': poseMundo,
        'left': left,
        'right': right,
        'renderLeft': renderLeft,
        'renderRight': renderRight,
        if (poseTimestampMs != null) 'pose_t': poseTimestampMs,
        if (handsTimestampMs != null) 'hands_t': handsTimestampMs,
        if (sourceSkewMs != null) 'source_skew_ms': sourceSkewMs,
        if (association.isNotEmpty) 'association': association,
        if (errors.isNotEmpty) 'errors': errors,
        if (visibilidadMin != null) 'visibilidad_min': visibilidadMin,
        'valido': esValido,
      };

  bool get esValido => normalize() != null;
}

/// Alias público del contrato de captura versionado.
typedef LandmarkFrameV1 = LandmarkFrame;

/// Resultado de arrancar la camara.
class CamaraIniciada {
  final int textureId;

  /// Conservado por compatibilidad con versiones anteriores. La vista en
  /// vivo ya no se espeja y el valor nuevo siempre es false.
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

  /// Campo legado. La asociación anatómica nativa es la única fuente de lado;
  /// no se permite cruzar manos desde una preferencia persistida.
  @Deprecated('La asociación anatómica determina izquierda y derecha')
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
            swapHands: false))
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
            swapHands: false))
        .asBroadcastStream();
  }

  /// Solo los frames normalizables, ya como vectores de 152 dimensiones.
  Stream<({int t, List<double> vec})> get vectores => frames
      .map((f) => (t: f.timestampMs, vec: f.normalize()))
      .where((e) => e.vec != null)
      .map((e) => (t: e.t, vec: e.vec!));
}
