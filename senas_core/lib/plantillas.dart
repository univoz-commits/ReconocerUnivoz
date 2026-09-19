/// Arma el diccionario que usa el reconocedor, combinando dos fuentes:
///
///  1. assets/plantillas.json -- las muestras aprobadas en Supabase,
///     exportadas desde la PC con tools/exportar_paquete.py. Es el
///     diccionario "oficial" del equipo y viaja dentro del APK.
///  2. Las muestras grabadas en este telefono (muestras_locales.dart), que
///     cuentan al instante, sin esperar a que alguien las apruebe.
///
/// Las dos van al mismo DtwClassifier: para reconocer no hay diferencia
/// entre una plantilla que vino de la base y una que grabaste hace un
/// minuto.
library plantillas;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'dtw.dart';
import 'motion_contract.dart';
import 'muestras_locales.dart';
import 'sign_norm.dart' show kNormVersion, kFrameDim, kTFrames, mirrorFrame;

const String kRutaPaquete = 'assets/plantillas.json';

/// Cuantas plantillas aporto cada fuente, para poder mostrarlo en pantalla.
class ResumenDiccionario {
  final int delPaquete;
  final int sincronizadas;
  final int locales;
  final int espejadas;
  final int senasDistintas;

  const ResumenDiccionario({
    required this.delPaquete,
    required this.sincronizadas,
    required this.locales,
    required this.espejadas,
    required this.senasDistintas,
  });

  int get total => delPaquete + sincronizadas + locales + espejadas;
  bool get vacio => total == 0;
}

class Diccionario {
  final DtwClassifier clasificador;
  final ResumenDiccionario resumen;

  const Diccionario(this.clasificador, this.resumen);
}

/// Lee el asset del paquete. Devuelve lista vacia si no existe o esta vacio
/// -- no es un error: se puede reconocer solo con muestras locales.
Future<List<_Plantilla>> _leerPaquete(String ruta) async {
  String texto;
  try {
    texto = await rootBundle.loadString(ruta);
  } catch (_) {
    return const [];
  }

  final Map<String, dynamic> json;
  try {
    json = jsonDecode(texto) as Map<String, dynamic>;
  } catch (_) {
    return const [];
  }

  final normVersion = json['norm_version'] as String?;
  if (normVersion != null && normVersion != kNormVersion) {
    // Un paquete viejo no es comparable con lo que ve la camara: los
    // vectores se calcularon con otra formula. Mejor ignorarlo que dar
    // resultados sin sentido.
    return const [];
  }
  if ((json['frame_dim'] as num?)?.toInt() != kFrameDim ||
      (json['t_frames'] as num?)?.toInt() != kTFrames) {
    return const [];
  }

  final crudas = (json['plantillas'] as List<dynamic>?) ?? const [];
  final out = <_Plantilla>[];
  for (final p in crudas) {
    try {
      final m = p as Map<String, dynamic>;
      final seq = (m['seq'] as List<dynamic>)
          .map((f) =>
              (f as List<dynamic>).map((v) => (v as num).toDouble()).toList())
          .toList();
      MotionSequenceV2.fromFrames(seq);
      out.add(_Plantilla(
        m['sign_id'] as String,
        m['gloss'] as String,
        (m['espanol'] as String?) ?? '',
        seq,
      ));
    } catch (_) {
      // Una plantilla corrupta no debe tumbar diccionario completo.
    }
  }
  return out;
}

class _Plantilla {
  final String signId;
  final String gloss;
  final String espanol;
  final List<List<double>> seq;
  const _Plantilla(this.signId, this.gloss, this.espanol, this.seq);
}

/// Construye el clasificador con todo lo disponible. Llamalo de nuevo
/// despues de grabar muestras nuevas para que entren al reconocimiento.
Future<Diccionario> cargarDiccionario({String ruta = kRutaPaquete}) async {
  final almacen = AlmacenMuestras.instancia;
  await almacen.cargar();
  final ajustes = almacen.ajustes;

  final clasificador = DtwClassifier(
    maxDistance: ajustes.maxDistance,
    minMargin: ajustes.minMargin,
  );

  final glosas = <String>{};
  var delPaquete = 0;
  var sincronizadas = 0;
  var locales = 0;
  var espejadas = 0;

  // El paquete del APK solo se usa si todavia no se sincronizo nunca: una
  // vez que hay diccionario bajado de la base, ese es el bueno, y sumar los
  // dos duplicaria cada plantilla.
  if (almacen.sincronizadas.isEmpty) {
    for (final p in await _leerPaquete(ruta)) {
      clasificador.add(p.signId, p.gloss, p.seq, espanol: p.espanol);
      glosas.add(p.gloss);
      delPaquete++;
    }
  } else {
    for (final p in almacen.sincronizadas) {
      clasificador.add(p.signId, p.gloss, p.seq, espanol: p.espanol);
      glosas.add(p.gloss);
      sincronizadas++;
    }
  }

  for (final m in almacen.muestras) {
    clasificador.add('local:${m.gloss}', m.gloss, m.seq, espanol: m.espanol);
    glosas.add(m.gloss);
    locales++;
    if (ajustes.espejoAutomatico) {
      // El espejo se calcula al vuelo en vez de guardarse: es barato y evita
      // duplicar el archivo de muestras en disco.
      clasificador.add(
          'local-espejo:${m.gloss}', m.gloss, m.seq.map(mirrorFrame).toList(),
          espanol: m.espanol);
      espejadas++;
    }
  }

  return Diccionario(
    clasificador,
    ResumenDiccionario(
      delPaquete: delPaquete,
      sincronizadas: sincronizadas,
      locales: locales,
      espejadas: espejadas,
      senasDistintas: glosas.length,
    ),
  );
}
