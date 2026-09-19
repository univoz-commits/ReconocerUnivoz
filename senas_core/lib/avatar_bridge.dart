/// Puente hacia el visor 3D del avatar (assets/avatar_viewer/index.html).
///
/// El visor corre dentro de un WebView con three.js + three-vrm. Esta clase
/// solo se encarga de:
///   1. Cargar esa pagina.
///   2. Mandarle una secuencia de frames normalizados (el mismo formato de
///      dtw.dart / sign_norm.dart) para que la anime.
///   3. Avisar cuando termina de reproducir, via un JavaScriptChannel.
///
/// Nota sobre el formato de los frames: sign_norm.dart guarda 152 valores por
/// frame. El bloque de cuerpo usa worldLandmarks de MediaPipe proyectados en
/// una base ortonormal 3D; el bloque de manos combina posicion metrica y
/// forma relativa. El visor convierte ese espacio a huesos VRM con IK de dos
/// huesos y orientacion de muneca, sin inventar profundidad fija por brazo.
/// La Z sigue siendo calibrable porque su signo depende de la convención del
/// modelo y de la camara.
///
/// Tambien por construccion de sign_norm.dart: el origen (0,0) es el punto
/// medio entre hombros, el eje X va del hombro izquierdo al derecho, y todo
/// esta escalado para que esa distancia entre hombros mida 1 unidad. Eso
/// quiere decir que, en este espacio normalizado, el hombro izquierdo cae
/// siempre cerca de (-0.5, 0) y el derecho cerca de (0.5, 0) -- son los
/// anclas que usa el IK del lado JavaScript, no hace falta mandarlas.
library avatar_bridge;

import 'dart:convert';

import 'package:flutter/material.dart' show Color;
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_flutter/webview_flutter.dart';

import 'motion_contract.dart';
import 'sign_norm.dart' show kNormVersion, kTFrames, kFrameDim;

// Modelo actual: VRM 0.0 exportado de VRoid Studio 1.22.1. Tiene el mapa
// humanoide completo (54 huesos, 15 por mano) y los blendshapes de
// parpadeo y vocales, que es lo minimo que pide LSM.
const String _kRutaAvatar = 'assets/avatar/univozM.vrm';

class AvatarBridge {
  late final WebViewController controller;

  /// Se llama cuando el visor termina de reproducir la ultima secuencia
  /// mandada. Util para encadenar varias palabras (una frase completa).
  void Function()? onTerminado;

  /// Se llama cuando se captura una pose desde el editor del visor. El texto
  /// que llega es el volcado completo de los huesos movidos, listo para
  /// pegar. La pantalla que lo reciba se encarga de copiarlo al portapapeles.
  void Function(String)? onPoseCapturada;
  void Function(String)? onDiagnosticReport;
  void Function(RigCalibration)? onCalibrationChanged;
  RigCalibration _calibracion = const RigCalibration();
  bool _jsListo = false;
  bool _diagnostico = false;
  bool _calibracionPendiente = false;

  AvatarBridge() {
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        'SenasChannel',
        onMessageReceived: (msg) {
          if (msg.message == 'fin') {
            onTerminado?.call();
          } else if (msg.message.startsWith('pose:')) {
            onPoseCapturada?.call(msg.message.substring(5));
          } else if (msg.message.startsWith('diagnostic_report:')) {
            onDiagnosticReport?.call(msg.message.substring(18));
          } else if (msg.message.startsWith('thumb_calibration:')) {
            try {
              final thumbs = jsonDecode(msg.message.substring(18));
              if (thumbs is Map) {
                final left = (thumbs['left'] as Map?)?.cast<String, dynamic>();
                final right =
                    (thumbs['right'] as Map?)?.cast<String, dynamic>();
                if (left != null && right != null) {
                  _calibracion = _calibracion.copyWith(
                    leftThumb: ThumbCalibration.fromJson(left),
                    rightThumb: ThumbCalibration.fromJson(right),
                  );
                  onCalibrationChanged?.call(_calibracion);
                }
              }
            } catch (_) {
              // Mensaje de diagnóstico corrupto no debe detener avatar.
            }
          } else if (msg.message == 'js_listo') {
            // La pagina ya importo three.js/three-vrm y esta lista para
            // recibir el modelo. Se lo mandamos nosotros en vez de que lo
            // pida por fetch(): mas confiable dentro de un WebView cargado
            // con loadFlutterAsset (ver la nota grande en index.html).
            _jsListo = true;
            _cargarAvatar();
          }
        },
      )
      ..loadFlutterAsset('assets/avatar_viewer/index.html');
  }

  Future<void> _cargarAvatar() async {
    final datos = await rootBundle.load(_kRutaAvatar);
    final b64 = base64Encode(
        datos.buffer.asUint8List(datos.offsetInBytes, datos.lengthInBytes));
    await controller.runJavaScript("window.cargarAvatarBase64('$b64')");
    await controller.runJavaScript(
        "window.configurarRig('${_escapar(jsonEncode(_calibracion.toJson()))}')");
    await controller
        .runJavaScript('window.configurarDiagnostico($_diagnostico)');
    if (_calibracionPendiente) {
      _calibracionPendiente = false;
      await controller.runJavaScript('window.iniciarCalibracionPulgares()');
    }
  }

  /// Configura adaptación del espacio normalizado al esqueleto VRM.
  Future<void> configurarRig(RigCalibration calibracion) async {
    _calibracion = calibracion;
    if (!_jsListo) return;
    await controller.runJavaScript(
        "window.configurarRig('${_escapar(jsonEncode(calibracion.toJson()))}')");
  }

  Future<void> configurarDiagnostico(bool activo) async {
    _diagnostico = activo;
    if (!_jsListo) return;
    await controller.runJavaScript('window.configurarDiagnostico($activo)');
  }

  Future<void> iniciarCalibracionPulgares() async {
    _calibracionPendiente = true;
    _diagnostico = true;
    if (!_jsListo) return;
    _calibracionPendiente = false;
    await controller.runJavaScript('window.configurarDiagnostico(true)');
    await controller.runJavaScript('window.iniciarCalibracionPulgares()');
  }

  /// Elige que brazos anima el avatar. Muchas senas de LSM son de una sola
  /// mano, y forzar la otra a seguir landmarks que no estan presentes la hace
  /// temblar sin sentido. El brazo desactivado se queda en reposo.
  ///
  /// Izquierda y derecha son las del AVATAR, no las de quien mira.
  Future<void> configurarManos(
      {bool izquierda = true, bool derecha = true}) async {
    await controller
        .runJavaScript('window.configurarManos($izquierda, $derecha)');
  }

  /// Reproduce una secuencia completa (lista de frames de 152 dimensiones
  /// cada uno, tal cual Template.seq en dtw.dart / plantillas.dart).
  Future<void> reproducir(List<List<double>> seq, {int fps = 30}) async {
    final contrato = MotionSequenceV2.fromFrames(seq, fps: fps);
    final json = jsonEncode(seq);
    await controller.runJavaScript(
        "window.reproducirSecuencia('${_escapar(json)}',$fps,'$kNormVersion')");
    // Validación ocurre antes de cruzar WebView; evita mezclar formatos legacy.
    assert(contrato.tFrames == kTFrames &&
        contrato.frames.first.length == kFrameDim);
  }

  /// Aplica UN frame al instante, sin cola ni interpolacion. Es lo que usa
  /// el modo espejo (pantalla_espejo.dart) para que el avatar siga a la
  /// camara en vivo. Corta cualquier reproduccion en curso.
  ///
  /// Devuelve cuando el WebView termino de procesarlo, para poder saltar
  /// frames en vez de encolarlos si el telefono no da abasto.
  Future<void> mostrarFrame(
    List<double> v, {
    List<double>? renderFrame,
    int? timestampMs,
    double quality = 1.0,
    Map<String, dynamic>? sourceMeta,
  }) async {
    MotionFrameV2(v);
    if (renderFrame != null) MotionFrameV2(renderFrame);
    final timestamp = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final calidad = quality.clamp(0.0, 1.0);
    final renderJson = jsonEncode(renderFrame ?? v);
    final metaJson = jsonEncode(sourceMeta ?? const <String, dynamic>{});
    await controller.runJavaScript(
        "window.aplicarFrameVivo('${jsonEncode(v)}',$timestamp,$calidad,"
        "'${_escapar(renderJson)}','${_escapar(metaJson)}')");
  }

  // Los frames son puramente numericos (nunca llevan comillas ni barras),
  // asi que esto es mas una red de seguridad que algo que vaya a activarse
  // en la practica.
  String _escapar(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll("'", "\\'");

  void dispose() {
    onTerminado = null;
    onPoseCapturada = null;
    onDiagnosticReport = null;
    onCalibrationChanged = null;
  }
}
