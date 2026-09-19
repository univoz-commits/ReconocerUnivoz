/// Muestras grabadas desde el telefono + ajustes del reconocedor.
///
/// Por que local y no directo a Supabase: para escribir en la base hace
/// falta la clave secreta del proyecto, y esa clave NUNCA puede ir dentro de
/// un APK -- cualquiera que descargue la app la puede extraer y borrar todo
/// el diccionario. Asi que el telefono guarda las muestras en su propio
/// archivo, las usa para reconocer al instante, y cuando quieras subirlas a
/// la base exportas el archivo y lo importas desde la PC con
/// tools/importar_muestras.py (que si tiene la clave, en tu .env).
library muestras_locales;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'camera_bridge.dart';
import 'controlador_captura.dart' show CapturaMovimiento;
import 'motion_contract.dart';
import 'sign_norm.dart' show kNormVersion, kTFrames, kFrameDim;
import 'supabase_api.dart' show PlantillaRemota;

const int kVersionArchivo = 2;
const String kNombreArchivo = 'muestras_locales.json';
const String kDirectorioRaw = 'motion_raw';

/// Cache del diccionario aprobado bajado de Supabase. Va en un archivo
/// aparte del de muestras propias: son dos cosas con ciclos de vida
/// distintos y asi una no se pierde si se corrompe la otra.
const String kNombreArchivoSync = 'plantillas_sync.json';

/// Umbrales y correcciones del reconocedor, que el usuario puede calibrar
/// sin recompilar. Los valores por defecto son los del README, calibrados
/// contra datos sinteticos -- se esperan cambios cuando haya grabaciones
/// reales.
class Ajustes {
  double maxDistance;
  double minMargin;

  /// Override manual de lado. El valor normal es false: CameraX ya entrega
  /// landmarks con izquierda/derecha fisicas corregidas por LandmarkEngine.
  bool cruzarManos;

  /// Camara frontal (selfie) o trasera. La trasera evita la ambiguedad del
  /// espejo, pero obliga a que alguien mas sostenga el telefono.
  bool camaraFrontal;

  /// Agrega al reconocedor la version espejada de cada muestra local. Cubre
  /// a quien sena con la otra mano sin tener que grabar de nuevo.
  bool espejoAutomatico;

  /// Decir en voz alta (TTS) la seña reconocida apenas se acepta. Se puede
  /// apagar para quien prefiere leerla en pantalla en silencio.
  bool hablarResultado;
  RigCalibration rigCalibration;
  bool rigDiagnosticMode;

  Ajustes({
    this.maxDistance = 0.55,
    this.minMargin = 0.12,
    this.cruzarManos = false,
    this.camaraFrontal = true,
    this.espejoAutomatico = true,
    this.hablarResultado = true,
    this.rigCalibration = const RigCalibration(),
    this.rigDiagnosticMode = false,
  });

  Ajustes copiar() => Ajustes(
        maxDistance: maxDistance,
        minMargin: minMargin,
        cruzarManos: cruzarManos,
        camaraFrontal: camaraFrontal,
        espejoAutomatico: espejoAutomatico,
        hablarResultado: hablarResultado,
        rigCalibration: rigCalibration,
        rigDiagnosticMode: rigDiagnosticMode,
      );

  Map<String, dynamic> toJson() => {
        'max_distance': maxDistance,
        'min_margin': minMargin,
        'cruzar_manos': cruzarManos,
        'camara_frontal': camaraFrontal,
        'espejo_automatico': espejoAutomatico,
        'hablar_resultado': hablarResultado,
        'rig_calibration': rigCalibration.toJson(),
        'rig_diagnostic_mode': rigDiagnosticMode,
      };

  factory Ajustes.fromJson(Map<String, dynamic> j) => Ajustes(
        maxDistance: (j['max_distance'] as num?)?.toDouble() ?? 0.55,
        minMargin: (j['min_margin'] as num?)?.toDouble() ?? 0.12,
        cruzarManos: j['cruzar_manos'] as bool? ?? false,
        camaraFrontal: j['camara_frontal'] as bool? ?? true,
        espejoAutomatico: j['espejo_automatico'] as bool? ?? true,
        hablarResultado: j['hablar_resultado'] as bool? ?? true,
        rigCalibration: RigCalibration.fromJson(
            (j['rig_calibration'] as Map?)?.cast<String, dynamic>() ??
                const {}),
        rigDiagnosticMode: j['rig_diagnostic_mode'] as bool? ?? false,
      );
}

class MuestraLocal {
  final String id;

  /// Glosa en mayusculas, sin espacios ni acentos: CASA, COMO_ESTAS.
  final String gloss;

  /// La palabra tal como la escribio la persona: "como estás".
  final String espanol;
  final String? categoria;
  final String? signer;

  /// Frames utilizables leidos antes de remuestrear a 32. Sirve como senal
  /// de calidad: una grabacion de 4 frames casi seguro salio mal.
  final int nFramesOrig;
  final String creada;

  /// 32 x 152, ya normalizada.
  final List<List<double>> seq;

  /// Ruta relativa al sidecar comprimido de landmarks, nunca video.
  final String? rawFramesPath;
  final double? fps;
  final int? duracionMs;
  final int framesInvalidos;
  final double? visibilidadMin;
  final double? qualityScore;
  final String? checksumSha256;

  /// Cuando se subio a Supabase, o null si todavia no. Sirve para no subir
  /// dos veces la misma muestra si se aprieta "Subir" de nuevo.
  final String? subidaEn;
  final String? rawSubidaEn;

  const MuestraLocal({
    required this.id,
    required this.gloss,
    required this.espanol,
    required this.seq,
    required this.nFramesOrig,
    required this.creada,
    this.categoria,
    this.signer,
    this.subidaEn,
    this.rawSubidaEn,
    this.rawFramesPath,
    this.fps,
    this.duracionMs,
    this.framesInvalidos = 0,
    this.visibilidadMin,
    this.qualityScore,
    this.checksumSha256,
  });

  bool get subida => subidaEn != null;

  MuestraLocal conSubida(String cuando) => MuestraLocal(
        id: id,
        gloss: gloss,
        espanol: espanol,
        seq: seq,
        nFramesOrig: nFramesOrig,
        creada: creada,
        categoria: categoria,
        signer: signer,
        subidaEn: cuando,
        rawSubidaEn: rawSubidaEn,
        rawFramesPath: rawFramesPath,
        fps: fps,
        duracionMs: duracionMs,
        framesInvalidos: framesInvalidos,
        visibilidadMin: visibilidadMin,
        qualityScore: qualityScore,
        checksumSha256: checksumSha256,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'gloss': gloss,
        'espanol': espanol,
        if (categoria != null) 'categoria': categoria,
        if (signer != null) 'signer': signer,
        if (subidaEn != null) 'subida_en': subidaEn,
        if (rawSubidaEn != null) 'raw_subida_en': rawSubidaEn,
        'n_frames_orig': nFramesOrig,
        'norm_version': kNormVersion,
        if (rawFramesPath != null) 'raw_frames_path': rawFramesPath,
        if (fps != null) 'fps': fps,
        if (duracionMs != null) 'duracion_ms': duracionMs,
        'frames_invalidos': framesInvalidos,
        if (visibilidadMin != null) 'visibilidad_min': visibilidadMin,
        if (qualityScore != null) 'quality_score': qualityScore,
        if (checksumSha256 != null) 'checksum_sha256': checksumSha256,
        'creada': creada,
        // 5 decimales: el dato termina guardado en float16 del lado de la
        // base igual, asi que mas precision solo infla el archivo.
        'seq': seq
            .map((f) =>
                f.map((v) => double.parse(v.toStringAsFixed(5))).toList())
            .toList(),
      };

  factory MuestraLocal.fromJson(Map<String, dynamic> j) {
    final normVersion = j['norm_version'] as String?;
    if (normVersion != null && normVersion != kNormVersion) {
      throw FormatException('muestra ${j['id']} usa norm_version incompatible');
    }
    final seq = (j['seq'] as List<dynamic>)
        .map((f) =>
            (f as List<dynamic>).map((v) => (v as num).toDouble()).toList())
        .toList();
    MotionSequenceV2.fromFrames(seq);
    return MuestraLocal(
      id: j['id'] as String,
      gloss: j['gloss'] as String,
      espanol: j['espanol'] as String,
      categoria: j['categoria'] as String?,
      signer: j['signer'] as String?,
      nFramesOrig: (j['n_frames_orig'] as num?)?.toInt() ?? 0,
      creada: j['creada'] as String? ?? '',
      subidaEn: j['subida_en'] as String?,
      rawSubidaEn: j['raw_subida_en'] as String?,
      rawFramesPath: j['raw_frames_path'] as String?,
      fps: (j['fps'] as num?)?.toDouble(),
      duracionMs: (j['duracion_ms'] as num?)?.toInt(),
      framesInvalidos: (j['frames_invalidos'] as num?)?.toInt() ?? 0,
      visibilidadMin: (j['visibilidad_min'] as num?)?.toDouble(),
      qualityScore: (j['quality_score'] as num?)?.toDouble(),
      checksumSha256: j['checksum_sha256'] as String?,
      seq: seq,
    );
  }
}

/// Convierte una palabra escrita por la persona en glosa canonica.
/// "como estás" -> "COMO_ESTAS". Sin acentos, para que la misma palabra
/// escrita de dos formas no cree dos senas distintas en la base.
String aGlosa(String palabra) {
  const acentos = {
    'á': 'a',
    'é': 'e',
    'í': 'i',
    'ó': 'o',
    'ú': 'u',
    'ü': 'u',
    'Á': 'a',
    'É': 'e',
    'Í': 'i',
    'Ó': 'o',
    'Ú': 'u',
    'Ü': 'u',
    'ñ': 'n',
    'Ñ': 'n',
  };
  final buf = StringBuffer();
  for (final c in palabra.trim().toLowerCase().split('')) {
    buf.write(acentos[c] ?? c);
  }
  return buf
      .toString()
      .replaceAll(RegExp(r'[^a-z0-9\s_]'), '')
      .trim()
      .replaceAll(RegExp(r'[\s_]+'), '_')
      .toUpperCase();
}

class AlmacenMuestras extends ChangeNotifier {
  static final AlmacenMuestras instancia = AlmacenMuestras._();
  AlmacenMuestras._();

  final List<MuestraLocal> _muestras = [];
  Ajustes ajustes = Ajustes();
  bool _cargado = false;
  File? _archivo;
  int _contador = 0;

  List<MuestraLocal> get muestras => List.unmodifiable(_muestras);
  bool get cargado => _cargado;
  int get total => _muestras.length;

  /// Las que todavia no viajaron a Supabase.
  List<MuestraLocal> get sinSubir => _muestras.where((m) => !m.subida).toList();

  /// Plantillas aprobadas bajadas de Supabase la ultima vez que se
  /// sincronizo. Se guardan en disco para que la app siga reconociendo sin
  /// red, que es el punto de todo el diseño.
  final List<PlantillaRemota> sincronizadas = [];
  String? sincronizadoEn;

  /// Glosas distintas, con cuantas muestras tiene cada una, ordenadas de
  /// menos a mas (las que faltan reforzar primero).
  List<MapEntry<String, int>> get porGlosa {
    final mapa = <String, int>{};
    for (final m in _muestras) {
      mapa[m.gloss] = (mapa[m.gloss] ?? 0) + 1;
    }
    final lista = mapa.entries.toList()
      ..sort((a, b) {
        final c = a.value.compareTo(b.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return lista;
  }

  int cuantasDe(String gloss) =>
      _muestras.where((m) => m.gloss == gloss).length;

  /// La ultima palabra en español usada para esa glosa (para no perder los
  /// acentos que escribio la persona).
  String? espanolDe(String gloss) {
    for (var i = _muestras.length - 1; i >= 0; i--) {
      if (_muestras[i].gloss == gloss) return _muestras[i].espanol;
    }
    return null;
  }

  /// La ultima categoria usada para esa glosa, o null si nunca se le puso
  /// ninguna. Sirve para sugerir la misma categoria si se vuelve a grabar
  /// una palabra ya conocida.
  String? categoriaDe(String gloss) {
    for (var i = _muestras.length - 1; i >= 0; i--) {
      if (_muestras[i].gloss == gloss) {
        final c = _muestras[i].categoria;
        if (c != null && c.isNotEmpty) return c;
      }
    }
    return null;
  }

  /// Categorias que ya se usaron en alguna muestra de este telefono, para
  /// sugerir en el desplegable de "Agregar muestras" ademas de la lista base
  /// (kCategoriasBase en pantalla_captura.dart).
  Set<String> get categoriasUsadas => _muestras
      .map((m) => m.categoria)
      .whereType<String>()
      .where((c) => c.isNotEmpty)
      .toSet();

  /// Igual que porGlosa, pero agrupado por categoria (la ultima que se uso
  /// para cada glosa). Las glosas sin categoria quedan bajo "Sin categoría".
  Map<String, List<MapEntry<String, int>>> get porCategoriaYGlosa {
    final agrupado = <String, List<MapEntry<String, int>>>{};
    for (final g in porGlosa) {
      final cat = categoriaDe(g.key);
      final clave = (cat == null || cat.isEmpty) ? 'Sin categoría' : cat;
      agrupado.putIfAbsent(clave, () => []).add(g);
    }
    return agrupado;
  }

  Future<File> _rutaArchivo() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$kNombreArchivo');
  }

  Future<void> cargar() async {
    if (_cargado) return;
    final f = _archivo ??= await _rutaArchivo();
    if (await f.exists()) {
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        ajustes = Ajustes.fromJson(
            (j['ajustes'] as Map?)?.cast<String, dynamic>() ?? const {});
        _muestras
          ..clear()
          ..addAll(((j['muestras'] as List?) ?? const []).map((m) {
            try {
              return MuestraLocal.fromJson((m as Map).cast<String, dynamic>());
            } catch (_) {
              return null;
            }
          }).whereType<MuestraLocal>());
      } catch (_) {
        // Archivo corrupto o de una version incompatible: se ignora y se
        // arranca limpio. Perder muestras locales es malo, pero dejar la
        // app inutilizable por un JSON roto es peor -- y el original sigue
        // en disco por si hay que recuperarlo a mano.
      }
    }
    await _cargarSincronizadas();
    _cargado = true;
    notifyListeners();
  }

  Future<void> _cargarSincronizadas() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$kNombreArchivoSync');
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (j['norm_version'] != kNormVersion ||
          (j['t_frames'] as num?)?.toInt() != kTFrames ||
          (j['frame_dim'] as num?)?.toInt() != kFrameDim) return;
      sincronizadoEn = j['sincronizado_en'] as String?;
      sincronizadas
        ..clear()
        ..addAll(((j['plantillas'] as List?) ?? const []).map((p) =>
            PlantillaRemota.fromJson((p as Map).cast<String, dynamic>())));
    } catch (_) {
      // Sin cache se sigue reconociendo con el paquete del APK y las
      // muestras propias; la proxima sincronizacion la reconstruye.
    }
  }

  /// Reemplaza la cache del diccionario con lo que se acaba de bajar.
  Future<void> guardarSincronizadas(List<PlantillaRemota> plantillas) async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/$kNombreArchivoSync');
    sincronizadoEn = DateTime.now().toIso8601String();
    sincronizadas
      ..clear()
      ..addAll(plantillas);
    await f.writeAsString(jsonEncode({
      'norm_version': kNormVersion,
      'sincronizado_en': sincronizadoEn,
      'plantillas': plantillas.map((p) => p.toJson()).toList(),
    }));
    notifyListeners();
  }

  Future<void> marcarSubida(String id) async {
    final i = _muestras.indexWhere((m) => m.id == id);
    if (i < 0) return;
    _muestras[i] = _muestras[i].conSubida(DateTime.now().toIso8601String());
    await _guardar();
    notifyListeners();
  }

  Future<void> marcarRawSubida(String id, String uri) async {
    final i = _muestras.indexWhere((m) => m.id == id);
    if (i < 0) return;
    final m = _muestras[i];
    _muestras[i] = MuestraLocal(
      id: m.id,
      gloss: m.gloss,
      espanol: m.espanol,
      seq: m.seq,
      nFramesOrig: m.nFramesOrig,
      creada: m.creada,
      categoria: m.categoria,
      signer: m.signer,
      subidaEn: m.subidaEn,
      rawFramesPath: m.rawFramesPath,
      rawSubidaEn: uri,
      fps: m.fps,
      duracionMs: m.duracionMs,
      framesInvalidos: m.framesInvalidos,
      visibilidadMin: m.visibilidadMin,
      qualityScore: m.qualityScore,
      checksumSha256: m.checksumSha256,
    );
    await _guardar();
    notifyListeners();
  }

  Future<void> _guardar() async {
    final f = _archivo ??= await _rutaArchivo();
    await f.writeAsString(jsonEncode({
      'version': kVersionArchivo,
      'norm_version': kNormVersion,
      't_frames': kTFrames,
      'frame_dim': kFrameDim,
      'ajustes': ajustes.toJson(),
      'muestras': _muestras.map((m) => m.toJson()).toList(),
    }));
  }

  Future<MuestraLocal> agregar({
    required String gloss,
    required String espanol,
    required List<List<double>> seq,
    required int nFramesOrig,
    String? categoria,
    String? signer,
    CapturaMovimiento? captura,
  }) async {
    if (seq.length != kTFrames ||
        seq.any((frame) => frame.length != kFrameDim)) {
      throw const FormatException('muestra debe ser una secuencia 32x152');
    }
    final id = '${DateTime.now().microsecondsSinceEpoch}_${_contador++}';
    String? rawFramesPath;
    if (captura != null && captura.framesCrudos.isNotEmpty) {
      final dir = await _directorioRaw();
      rawFramesPath = '$kDirectorioRaw/$id.json.gz';
      final raw = jsonEncode(
          captura.framesCrudos.map((frame) => frame.toJson()).toList());
      await File('${dir.path}/$id.json.gz')
          .writeAsBytes(gzip.encode(utf8.encode(raw)), flush: true);
    }
    final m = MuestraLocal(
      id: id,
      gloss: gloss,
      espanol: espanol,
      categoria: categoria,
      signer: signer,
      nFramesOrig: nFramesOrig,
      creada: DateTime.now().toIso8601String(),
      seq: seq,
      rawFramesPath: rawFramesPath,
      fps: captura?.fps,
      duracionMs: captura?.duracionMs,
      framesInvalidos: captura?.framesInvalidos ?? 0,
      visibilidadMin: captura?.visibilidadMin,
      qualityScore: captura?.qualityScore,
      checksumSha256: captura?.checksumSha256,
    );
    _muestras.add(m);
    await _guardar();
    notifyListeners();
    return m;
  }

  Future<void> borrar(String id) async {
    final coincidentes = _muestras.where((m) => m.id == id).toList();
    final existente = coincidentes.isEmpty ? null : coincidentes.first;
    _muestras.removeWhere((m) => m.id == id);
    if (existente != null) await _borrarRaw(existente);
    await _guardar();
    notifyListeners();
  }

  Future<void> borrarGlosa(String gloss) async {
    final eliminadas = _muestras.where((m) => m.gloss == gloss).toList();
    _muestras.removeWhere((m) => m.gloss == gloss);
    for (final muestra in eliminadas) {
      await _borrarRaw(muestra);
    }
    await _guardar();
    notifyListeners();
  }

  Future<void> guardarAjustes(Ajustes nuevos) async {
    ajustes = nuevos;
    await _guardar();
    notifyListeners();
  }

  Future<Directory> _directorioRaw() async {
    final dir = await getApplicationDocumentsDirectory();
    final raw = Directory('${dir.path}/$kDirectorioRaw');
    await raw.create(recursive: true);
    return raw;
  }

  Future<void> _borrarRaw(MuestraLocal muestra) async {
    final path = muestra.rawFramesPath;
    if (path == null || path.contains('..')) return;
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$path');
    if (await file.exists()) await file.delete();
  }

  /// Devuelve bytes gzip del sidecar para una subida explícita a Storage.
  Future<Uint8List?> cargarRawComprimido(MuestraLocal muestra) async {
    final path = muestra.rawFramesPath;
    if (path == null || path.contains('..')) return null;
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$path');
    if (!await file.exists()) return null;
    return Uint8List.fromList(await file.readAsBytes());
  }

  /// Lee sidecar de landmarks sin video para auditoría o re-normalización.
  Future<List<LandmarkFrame>> cargarFramesCrudos(MuestraLocal muestra) async {
    final path = muestra.rawFramesPath;
    if (path == null || path.contains('..')) return const [];
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$path');
    if (!await file.exists()) return const [];
    final json = utf8.decode(gzip.decode(await file.readAsBytes()));
    final rows = jsonDecode(json) as List<dynamic>;
    return rows
        .map((row) => LandmarkFrame.fromMap((row as Map)
            .map((key, value) => MapEntry<Object?, Object?>(key, value))))
        .toList();
  }

  /// Escribe un archivo en la carpeta temporal listo para compartir e
  /// importar con tools/importar_muestras.py. Devuelve la ruta.
  Future<File> exportar() async {
    final dir = await getTemporaryDirectory();
    final sello =
        DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final f = File('${dir.path}/muestras_univoz_$sello.json');
    await f.writeAsString(jsonEncode({
      'version': kVersionArchivo,
      'norm_version': kNormVersion,
      't_frames': kTFrames,
      'frame_dim': kFrameDim,
      'exportado': DateTime.now().toIso8601String(),
      'muestras': _muestras.map((m) => m.toJson()).toList(),
    }));
    return f;
  }
}
