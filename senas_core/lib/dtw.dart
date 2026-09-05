/// Reconocimiento de senas por Dynamic Time Warping sobre plantillas.
///
/// Espejo exacto de tools/dtw.py. Corre en el dispositivo: las plantillas
/// llegan en el paquete que sincroniza PostgreSQL.
library dtw;

import 'dart:math' as math;

import 'sign_norm.dart';

const int kNBody = 12;
const int kNShape = 60;

const double kWBody = 0.5;
const double kWLoc = 1.5;
const double kWPres = 2.0;
const double kWShape = 1.0;
const double kShapePenalty = 1.0;

const int kBand = 4;

const List<List<int>> _handBlocks = [
  [kOffLocL, kOffPresL, kOffShapeL],
  [kOffLocR, kOffPresR, kOffShapeR],
];

/// Distancia ponderada por bloques entre dos frames normalizados.
///
/// Cada bloque se promedia por su numero de dimensiones antes de ponderarse,
/// para que la forma de la mano (120 dims) no aplaste a la ubicacion (4 dims).
double frameDistance(List<double> a, List<double> b) {
  var acc = 0.0;

  var s = 0.0;
  for (var i = kOffBody; i < kOffBody + kNBody; i++) {
    final d = a[i] - b[i];
    s += d * d;
  }
  acc += kWBody * s / kNBody;

  for (final blk in _handBlocks) {
    final offLoc = blk[0];
    final offPres = blk[1];
    final offShape = blk[2];

    final pa = a[offPres];
    final pb = b[offPres];
    final dp = pa - pb;
    acc += kWPres * dp * dp;

    final ha = pa >= 0.5;
    final hb = pb >= 0.5;
    if (ha && hb) {
      final d0 = a[offLoc] - b[offLoc];
      final d1 = a[offLoc + 1] - b[offLoc + 1];
      acc += kWLoc * (d0 * d0 + d1 * d1) / 2.0;
      var t = 0.0;
      for (var i = offShape; i < offShape + kNShape; i++) {
        final d = a[i] - b[i];
        t += d * d;
      }
      acc += kWShape * t / kNShape;
    } else if (ha != hb) {
      acc += kWShape * kShapePenalty;
    }
  }

  return math.sqrt(acc);
}

/// DTW con banda de Sakoe-Chiba, normalizado por la secuencia mas larga.
///
/// [ceiling] permite abandonar temprano una plantilla que ya no puede ganar.
double dtwDistance(
  List<List<double>> a,
  List<List<double>> b, {
  int band = kBand,
  double? ceiling,
}) {
  final n = a.length;
  final m = b.length;
  if (n == 0 || m == 0) return double.infinity;

  const inf = double.infinity;
  final ratio = m / n;
  var prev = List<double>.filled(m + 1, inf);
  prev[0] = 0.0;

  final norm = math.max(n, m);

  for (var i = 1; i <= n; i++) {
    final center = (i - 1) * ratio;
    final lo = math.max(1, (center - band).floor() + 1);
    final hi = math.min(m, (center + band).ceil() + 1);

    final cur = List<double>.filled(m + 1, inf);
    var filaMin = inf;
    for (var j = lo; j <= hi; j++) {
      var best = prev[j - 1];
      if (prev[j] < best) best = prev[j];
      if (cur[j - 1] < best) best = cur[j - 1];
      if (best == inf) continue;
      cur[j] = best + frameDistance(a[i - 1], b[j - 1]);
      if (cur[j] < filaMin) filaMin = cur[j];
    }

    if (ceiling != null && filaMin / norm > ceiling) return inf;
    prev = cur;
  }

  final d = prev[m];
  return d == inf ? inf : d / norm;
}

/// Vector promedio de la secuencia, usado como prefiltro barato.
List<double> signature(List<List<double>> seq) {
  final sig = List<double>.filled(kFrameDim, 0.0);
  for (final f in seq) {
    for (var i = 0; i < kFrameDim; i++) {
      sig[i] += f[i];
    }
  }
  final n = seq.length;
  for (var i = 0; i < kFrameDim; i++) {
    sig[i] /= n;
  }
  return sig;
}

class Template {
  final String signId;
  final String gloss;
  final String espanol;
  final List<List<double>> seq;
  final List<double> sig;

  Template(this.signId, this.gloss, this.seq, {this.espanol = ''})
      : sig = signature(seq);
}

class Prediction {
  final String? gloss;
  final String? signId;
  final String? espanol;
  final double distance;
  final double margin;
  final bool aceptada;

  const Prediction(this.gloss, this.signId, this.espanol, this.distance,
      this.margin, this.aceptada);

  /// Lo que hay que decir en voz alta: el español guardado si lo hay, o si
  /// no la glosa vuelta pronunciable (COMO_ESTAS -> como estas). Un solo
  /// lugar para esta decision evita que TTS y la UI se desincronicen.
  String get textoHablado {
    final e = espanol;
    if (e != null && e.trim().isNotEmpty) return e;
    final g = gloss;
    if (g == null || g.isEmpty) return '';
    return g.toLowerCase().replaceAll('_', ' ');
  }

  @override
  String toString() => 'Prediction($gloss, d=${distance.toStringAsFixed(4)}, '
      'margen=${margin.toStringAsFixed(3)}, '
      '${aceptada ? "aceptada" : "rechazada"})';
}

class DtwClassifier {
  final List<Template> templates = [];
  final double maxDistance;
  final double minMargin;
  final int prefilter;
  final int band;

  DtwClassifier({
    this.maxDistance = 0.55,
    this.minMargin = 0.12,
    this.prefilter = 40,
    this.band = kBand,
  });

  void add(String signId, String gloss, List<List<double>> seq,
      {String espanol = ''}) {
    templates.add(Template(signId, gloss, seq, espanol: espanol));
  }

  List<Template> _candidatos(List<double> sig) {
    if (prefilter <= 0 || templates.length <= prefilter) return templates;
    final puntuadas = templates
        .map((t) => MapEntry(frameDistance(sig, t.sig), t))
        .toList()
      ..sort((x, y) => x.key.compareTo(y.key));
    return puntuadas.take(prefilter).map((e) => e.value).toList();
  }

  /// Todas las distancias, de menor a mayor.
  List<MapEntry<double, Template>> rank(List<List<double>> seq) {
    final cands = _candidatos(signature(seq));
    final out = <MapEntry<double, Template>>[];
    double? mejor;
    for (final t in cands) {
      final d = dtwDistance(seq, t.seq,
          band: band, ceiling: mejor == null ? null : mejor * 1.5);
      if (d == double.infinity) continue;
      if (mejor == null || d < mejor) mejor = d;
      out.add(MapEntry(d, t));
    }
    out.sort((x, y) => x.key.compareTo(y.key));
    return out;
  }

  Prediction classify(List<List<double>> seq) {
    final r = rank(seq);
    if (r.isEmpty) {
      return const Prediction(null, null, null, double.infinity, 0.0, false);
    }

    final d1 = r.first.key;
    final t1 = r.first.value;

    double? d2;
    for (final e in r) {
      if (e.value.gloss != t1.gloss) {
        d2 = e.key;
        break;
      }
    }

    final margin = (d2 == null || d2 == 0) ? 1.0 : (d2 - d1) / d2;
    final aceptada = d1 <= maxDistance && margin >= minMargin;
    return Prediction(t1.gloss, t1.signId, t1.espanol, d1, margin, aceptada);
  }
}
