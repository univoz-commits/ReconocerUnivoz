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

import 'sign_norm.dart' show kNormVersion, kTFrames, kFrameDim;
import 'supabase_api.dart' show PlantillaRemota;

const int kVersionArchivo = 1;
const String kNombreArchivo = 'muestras_locales.json';

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

  /// Ver CameraBridge.cruzarManos.
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

  Ajustes({
    this.maxDistance = 0.55,
    this.minMargin = 0.12,
    this.cruzarManos = false,
    this.camaraFrontal = true,
    this.espejoAutomatico = true,
    this.hablarResultado = true,
  });

  Ajustes copiar() => Ajustes(
        maxDistance: maxDistance,
        minMargin: minMargin,
        cruzarManos: cruzarManos,
        camaraFrontal: camaraFrontal,
        espejoAutomatico: espejoAutomatico,
        hablarResultado: hablarResultado,
      );

  Map<String, dynamic> toJson() => {
        'max_distance': maxDistance,
        'min_margin': minMargin,
        'cruzar_manos': cruzarManos,
        'camara_frontal': camaraFrontal,
        'espejo_automatico': espejoAutomatico,
        'hablar_resultado': hablarResultado,
      };

  factory Ajustes.fromJson(Map<String, dynamic> j) => Ajustes(
        maxDistance: (j['max_distance'] as num?)?.toDouble() ?? 0.55,
        minMargin: (j['min_margin'] as num?)?.toDouble() ?? 0.12,
        cruzarManos: j['cruzar_manos'] as bool? ?? false,
        camaraFrontal: j['camara_frontal'] as bool? ?? true,
        espejoAutomatico: j['espejo_automatico'] as bool? ?? true,
        hablarResultado: j['hablar_resultado'] as bool? ?? true,
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

  /// 32 x 138, ya normalizada.
  final List<List<double>> seq;

  /// Cuando se subio a Supabase, o null si todavia no. Sirve para no subir
  /// dos veces la misma muestra si se aprieta "Subir" de nuevo.
  final String? subidaEn;

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
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'gloss': gloss,
        'espanol': espanol,
        if (categoria != null) 'categoria': categoria,
        if (signer != null) 'signer': signer,
        if (subidaEn != null) 'subida_en': subidaEn,
        'n_frames_orig': nFramesOrig,
        'creada': creada,
        // 5 decimales: el dato termina guardado en float16 del lado de la
        // base igual, asi que mas precision solo infla el archivo.
        'seq': seq
            .map((f) => f.map((v) => double.parse(v.toStringAsFixed(5))).toList())
            .toList(),
      };

  factory MuestraLocal.fromJson(Map<String, dynamic> j) => MuestraLocal(
        id: j['id'] as String,
        gloss: j['gloss'] as String,
        espanol: j['espanol'] as String,
        categoria: j['categoria'] as String?,
        signer: j['signer'] as String?,
        nFramesOrig: (j['n_frames_orig'] as num?)?.toInt() ?? 0,
        creada: j['creada'] as String? ?? '',
        subidaEn: j['subida_en'] as String?,
        seq: (j['seq'] as List<dynamic>)
            .map((f) => (f as List<dynamic>).map((v) => (v as num).toDouble()).toList())
            .toList(),
      );
}

/// Convierte una palabra escrita por la persona en glosa canonica.
/// "como estás" -> "COMO_ESTAS". Sin acentos, para que la misma palabra
/// escrita de dos formas no cree dos senas distintas en la base.
String aGlosa(String palabra) {
  const acentos = {
    'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ü': 'u',
    'Á': 'a', 'É': 'e', 'Í': 'i', 'Ó': 'o', 'Ú': 'u', 'Ü': 'u',
    'ñ': 'n', 'Ñ': 'n',
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

  int cuantasDe(String gloss) => _muestras.where((m) => m.gloss == gloss).length;

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
          ..addAll(((j['muestras'] as List?) ?? const [])
              .map((m) => MuestraLocal.fromJson((m as Map).cast<String, dynamic>())));
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
      if (j['norm_version'] != kNormVersion) return; // cache vieja: se ignora
      sincronizadoEn = j['sincronizado_en'] as String?;
      sincronizadas
        ..clear()
        ..addAll(((j['plantillas'] as List?) ?? const [])
            .map((p) => PlantillaRemota.fromJson((p as Map).cast<String, dynamic>())));
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
  }) async {
    final m = MuestraLocal(
      id: '${DateTime.now().microsecondsSinceEpoch}_${_contador++}',
      gloss: gloss,
      espanol: espanol,
      categoria: categoria,
      signer: signer,
      nFramesOrig: nFramesOrig,
      creada: DateTime.now().toIso8601String(),
      seq: seq,
    );
    _muestras.add(m);
    await _guardar();
    notifyListeners();
    return m;
  }

  Future<void> borrar(String id) async {
    _muestras.removeWhere((m) => m.id == id);
    await _guardar();
    notifyListeners();
  }

  Future<void> borrarGlosa(String gloss) async {
    _muestras.removeWhere((m) => m.gloss == gloss);
    await _guardar();
    notifyListeners();
  }

  Future<void> guardarAjustes(Ajustes nuevos) async {
    ajustes = nuevos;
    await _guardar();
    notifyListeners();
  }

  /// Escribe un archivo en la carpeta temporal listo para compartir e
  /// importar con tools/importar_muestras.py. Devuelve la ruta.
  Future<File> exportar() async {
    final dir = await getTemporaryDirectory();
    final sello = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
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
