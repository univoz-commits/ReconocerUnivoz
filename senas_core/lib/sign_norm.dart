/// Normalizacion de landmarks para reconocimiento de senas.
///
/// Espejo exacto de python/sign_norm.py. Cualquier cambio aqui tiene que
/// hacerse alla tambien, y el golden test tiene que seguir pasando en ambos.
///
/// Este archivo no depende de Flutter a proposito: asi corre en `dart test`
/// sin levantar un emulador.
///
/// VERSION 2.0.0: el cuerpo pasa de 2D a 3D, y se calcula desde el esqueleto
/// METRICO de MediaPipe (worldLandmarks), no desde las coordenadas de imagen.
///
/// Se intento primero usar la Z que traen los landmarks de imagen, y no
/// sirve: sus valores son incoherentes entre puntos vecinos. Medido en una
/// captura real, un antebrazo de 0.8 anchos de hombro daba 3.5 de recorrido
/// en Z, y las caderas quedaban dos anchos de hombro detras de los hombros.
/// MediaPipe la documenta como profundidad relativa aproximada y no da para
/// reconstruir una postura. Los mismos segmentos medidos con worldLandmarks
/// dieron 0.73, 0.65, 0.67 y 0.83: coherentes entre si y con la anatomia.
///
/// El bloque de cuerpo ya no son coordenadas de imagen rotadas, sino
/// proyecciones sobre una base ortonormal sacada del propio esqueleto:
///   +X  hacia la derecha de la persona (hombro izq -> hombro der)
///   +Y  hacia arriba (caderas -> hombros, ortogonalizado)
///   +Z  hacia el frente de la persona
/// dividido todo por la distancia entre hombros. Eso lo hace invariante a
/// donde este la persona, a que tan lejos, y a hacia donde este girada.
library sign_norm;

import 'dart:math' as math;
import 'dart:typed_data';

const String kNormVersion = '2.0.0';
const int kTFrames = 32;
const int kFrameDim = 152;

const int kLShoulder = 11;
const int kRShoulder = 12;
const int kLHip = 23;
const int kRHip = 24;
const int kLWrist = 15;
const int kRWrist = 16;

/// Hombros, codos, munecas, caderas.
const List<int> kPoseBodyIdx = [11, 12, 13, 14, 15, 16, 23, 24];
const List<List<int>> kBodyMirrorPairs = [
  [0, 1],
  [2, 3],
  [4, 5],
  [6, 7],
];

const int kHandWrist = 0;
const int kHandMiddleMcp = 9;
const int kNHandPts = 20;

const double kMinVisibility = 0.5;
const double kEps = 1e-6;

const int kOffBody = 0; // 24 = 8 puntos x (x, y, z)
const int kOffLocL = 24; // 3
const int kOffLocR = 27; // 3
const int kOffPresL = 30;
const int kOffPresR = 31;
const int kOffShapeL = 32; // 60 = 20 puntos x (x, y, z)
const int kOffShapeR = 92; // 60

/// Dimensiones con profundidad del CUERPO. El clasificador las ignora: aunque
/// worldLandmarks es mucho mejor que la Z de imagen, sigue siendo una
/// estimacion y al comparar dos senas aporta menos que lo que ensucia. La Z
/// de la FORMA de las manos no esta aqui y si se usa.
const List<int> kZBodyDims = [
  2, 5, 8, 11, 14, 17, 20, 23, // los 8 puntos del cuerpo
  kOffLocL + 2, kOffLocR + 2, // las dos munecas
];

/// Base ortonormal del cuerpo, sacada del esqueleto metrico.
class _BaseCuerpo {
  final List<double> der; // hacia la derecha de la persona
  final List<double> arr; // hacia arriba
  final List<double> fre; // hacia el frente
  final List<double> origen; // punto medio entre hombros
  final double escala; // distancia entre hombros, en metros
  const _BaseCuerpo(this.der, this.arr, this.fre, this.origen, this.escala);

  /// Proyecta un punto del mundo sobre la base, en unidades de ancho de
  /// hombros.
  List<double> proyectar(List<double> p) {
    final q = [p[0] - origen[0], p[1] - origen[1], p[2] - origen[2]];
    return [
      _pto(q, der) / escala,
      _pto(q, arr) / escala,
      _pto(q, fre) / escala
    ];
  }
}

double _pto(List<double> a, List<double> b) =>
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

List<double> _resta(List<double> a, List<double> b) =>
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]];

List<double> _cruz(List<double> a, List<double> b) => [
      a[1] * b[2] - a[2] * b[1],
      a[2] * b[0] - a[0] * b[2],
      a[0] * b[1] - a[1] * b[0],
    ];

double _largo(List<double> a) => math.sqrt(_pto(a, a));

List<double>? _unitario(List<double> a) {
  final m = _largo(a);
  if (m < kEps) return null;
  return [a[0] / m, a[1] / m, a[2] / m];
}

/// Arma la base del cuerpo. Null si el esqueleto esta degenerado.
_BaseCuerpo? _baseDe(List<Landmark> w) {
  final hi = w[kLShoulder], hd = w[kRShoulder];
  final ci = w[kLHip], cd = w[kRHip];

  final der = _unitario(_resta(hd, hi));
  if (der == null) return null;
  final escala = _largo(_resta(hd, hi));

  final origen = [
    (hi[0] + hd[0]) * 0.5,
    (hi[1] + hd[1]) * 0.5,
    (hi[2] + hd[2]) * 0.5,
  ];
  final centroCaderas = [
    (ci[0] + cd[0]) * 0.5,
    (ci[1] + cd[1]) * 0.5,
    (ci[2] + cd[2]) * 0.5,
  ];

  // Arriba = caderas -> hombros, ortogonalizado contra la linea de hombros
  // (Gram-Schmidt) para que la base sea realmente ortonormal aunque la
  // persona este inclinada de lado.
  final tronco = _resta(origen, centroCaderas);
  final proy = _pto(tronco, der);
  final arr = _unitario([
    tronco[0] - der[0] * proy,
    tronco[1] - der[1] * proy,
    tronco[2] - der[2] * proy,
  ]);
  if (arr == null) return null;

  // Frente = arriba x derecha. Con los ejes de MediaPipe (X a la derecha de
  // la imagen, Y hacia abajo, Z creciendo al alejarse de la camara) este
  // producto apunta hacia el pecho de la persona.
  final fre = _unitario(_cruz(arr, der));
  if (fre == null) return null;

  return _BaseCuerpo(der, arr, fre, origen, escala);
}

/// Un landmark: [x, y, z] y opcionalmente visibility en la posicion 3.
typedef Landmark = List<double>;

/// Normaliza un frame. Devuelve null si el frame no sirve.
///
/// [pose] son las coordenadas de imagen (para el filtro de visibilidad y la
/// rotacion de las manos) y [poseMundo] el esqueleto metrico (para todo el
/// bloque de cuerpo).
List<double>? normalizeFrame(
  List<Landmark>? pose,
  List<Landmark>? poseMundo, {
  List<Landmark>? left,
  List<Landmark>? right,
  double minVisibility = kMinVisibility,
}) {
  if (pose == null || pose.length < 33) return null;
  if (poseMundo == null || poseMundo.length < 33) return null;

  final ls = pose[kLShoulder];
  final rs = pose[kRShoulder];
  if (ls.length < 4 || rs.length < 4) return null;
  if (ls[3] < minVisibility || rs[3] < minVisibility) {
    return null;
  }

  for (final index in kPoseBodyIdx) {
    if (poseMundo[index].length < 3 ||
        poseMundo[index].any((value) => !value.isFinite)) return null;
  }

  final base = _baseDe(poseMundo);
  if (base == null) return null;

  // Marco 2D de imagen: se sigue usando para la FORMA de las manos, que solo
  // existe en coordenadas de imagen. Alinea la linea de hombros con la
  // horizontal para que inclinar la cabeza no cambie la forma detectada.
  final dx = rs[0] - ls[0];
  final dy = rs[1] - ls[1];
  final escalaImg = math.sqrt(dx * dx + dy * dy);
  if (escalaImg < kEps) return null;
  final cosT = dx / escalaImg;
  final sinT = dy / escalaImg;

  final out = List<double>.filled(kFrameDim, 0.0);

  for (var i = 0; i < kPoseBodyIdx.length; i++) {
    final q = base.proyectar(poseMundo[kPoseBodyIdx[i]]);
    out[kOffBody + i * 3] = q[0];
    out[kOffBody + i * 3 + 1] = q[1];
    out[kOffBody + i * 3 + 2] = q[2];
  }

  final hands = [
    [left, kOffLocL, kOffPresL, kOffShapeL, kLWrist],
    [right, kOffLocR, kOffPresR, kOffShapeR, kRWrist],
  ];

  for (final h in hands) {
    final hand = h[0] as List<Landmark>?;
    if (hand == null || hand.length < 21) continue;
    final offLoc = h[1] as int;
    final offPres = h[2] as int;
    final offShape = h[3] as int;
    final idxMuneca = h[4] as int;

    // Ubicacion de la mano: se toma la muneca del modelo de POSE, no la del
    // detector de manos, para que quede en el mismo espacio metrico que el
    // resto del cuerpo. Son practicamente el mismo punto anatomico.
    final q = base.proyectar(poseMundo[idxMuneca]);
    out[offLoc] = q[0];
    out[offLoc + 1] = q[1];
    out[offLoc + 2] = q[2];
    out[offPres] = 1.0;

    // La FORMA si viene del detector de manos: es relativa a su propia
    // muneca y escalada por el tamano de la mano, asi que no depende de
    // donde este el brazo.
    final w = hand[kHandWrist];
    final m = hand[kHandMiddleMcp];
    final hdx = m[0] - w[0];
    final hdy = m[1] - w[1];
    var handScale = math.sqrt(hdx * hdx + hdy * hdy);
    if (handScale < kEps) handScale = escalaImg * 0.25;

    for (var j = 1; j < 21; j++) {
      final p = hand[j];
      final qx = p[0] - w[0];
      final qy = p[1] - w[1];
      final k = offShape + (j - 1) * 3;
      out[k] = (qx * cosT + qy * sinT) / handScale;
      out[k + 1] = (-qx * sinT + qy * cosT) / handScale;
      out[k + 2] = (p[2] - w[2]) / handScale;
    }
  }

  return out;
}

/// Sustituye frames nulos por el ultimo valido.
List<List<double>>? fillGaps(List<List<double>?> frames) {
  List<double>? last;
  for (final f in frames) {
    if (f != null) {
      last = f;
      break;
    }
  }
  if (last == null) return null;

  final out = <List<double>>[];
  for (final f in frames) {
    if (f != null) last = f;
    out.add(last!);
  }
  return out;
}

/// Remuestrea linealmente a [t] frames.
List<List<double>>? resample(List<List<double>> frames, [int t = kTFrames]) {
  final n = frames.length;
  if (n == 0) return null;
  if (n == 1) {
    return List.generate(t, (_) => List<double>.from(frames[0]));
  }

  final out = <List<double>>[];
  for (var i = 0; i < t; i++) {
    final pos = i * (n - 1) / (t - 1);
    final lo = pos.floor();
    final hi = math.min(lo + 1, n - 1);
    final w = pos - lo;
    final a = frames[lo];
    final b = frames[hi];
    out.add(List<double>.generate(kFrameDim, (d) => a[d] + (b[d] - a[d]) * w));
  }
  return out;
}

/// Espejea un frame ya normalizado (augmentation para personas zurdas).
///
/// La Z no se toca: espejear a alguien de lado a lado no cambia que tan cerca
/// esta de la camara.
List<double> mirrorFrame(List<double> v) {
  final out = List<double>.filled(kFrameDim, 0.0);

  for (final pair in kBodyMirrorPairs) {
    final a = pair[0];
    final b = pair[1];
    out[kOffBody + a * 3] = -v[kOffBody + b * 3];
    out[kOffBody + a * 3 + 1] = v[kOffBody + b * 3 + 1];
    out[kOffBody + a * 3 + 2] = v[kOffBody + b * 3 + 2];
    out[kOffBody + b * 3] = -v[kOffBody + a * 3];
    out[kOffBody + b * 3 + 1] = v[kOffBody + a * 3 + 1];
    out[kOffBody + b * 3 + 2] = v[kOffBody + a * 3 + 2];
  }

  out[kOffLocL] = -v[kOffLocR];
  out[kOffLocL + 1] = v[kOffLocR + 1];
  out[kOffLocL + 2] = v[kOffLocR + 2];
  out[kOffLocR] = -v[kOffLocL];
  out[kOffLocR + 1] = v[kOffLocL + 1];
  out[kOffLocR + 2] = v[kOffLocL + 2];

  out[kOffPresL] = v[kOffPresR];
  out[kOffPresR] = v[kOffPresL];

  for (var j = 0; j < kNHandPts; j++) {
    final sl = kOffShapeL + j * 3;
    final sr = kOffShapeR + j * 3;
    out[sl] = -v[sr];
    out[sl + 1] = v[sr + 1];
    out[sl + 2] = v[sr + 2];
    out[sr] = -v[sl];
    out[sr + 1] = v[sl + 1];
    out[sr + 2] = v[sl + 2];
  }

  return out;
}

/// Empaqueta la secuencia a float16 para mandarla al servidor / BYTEA.
Uint8List packF16(List<List<double>> seq) {
  final flat = <double>[];
  for (final row in seq) {
    flat.addAll(row);
  }
  final bytes = ByteData(flat.length * 2);
  for (var i = 0; i < flat.length; i++) {
    bytes.setUint16(i * 2, _toF16(flat[i]), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// Inverso de [packF16]: bytes float16 little endian -> matriz de frames.
/// Espejo de sign_norm.unpack_f16 en Python. Lo usa la sincronizacion con
/// Supabase, que baja las plantillas en el mismo formato en que se guardan
/// en la columna BYTEA.
List<List<double>> unpackF16(Uint8List bytes, {int dim = kFrameDim}) {
  final n = bytes.length ~/ 2;
  final vista = ByteData.sublistView(bytes);
  final plano = List<double>.generate(
      n, (i) => _fromF16(vista.getUint16(i * 2, Endian.little)),
      growable: false);

  final filas = <List<double>>[];
  for (var i = 0; i + dim <= n; i += dim) {
    filas.add(plano.sublist(i, i + dim));
  }
  return filas;
}

/// bits de float16 -> double.
double _fromF16(int bits) {
  final signo = (bits & 0x8000) != 0 ? -1.0 : 1.0;
  final exp = (bits >> 10) & 0x1F;
  final mant = bits & 0x3FF;

  if (exp == 0) {
    // Subnormal: mant * 2^-24. Sin bit implicito.
    return signo * mant * 5.960464477539063e-8;
  }
  if (exp == 0x1F) {
    return mant == 0 ? signo * double.infinity : double.nan;
  }
  // Normal: (1024 + mant) * 2^(exp - 25)
  return signo * (1024 + mant) * _pot2(exp - 25);
}

double _pot2(int e) => math.pow(2.0, e).toDouble();

/// float64 -> bits de float16, con redondeo al par mas cercano.
int _toF16(double value) {
  final f = ByteData(4)..setFloat32(0, value, Endian.little);
  final bits = f.getUint32(0, Endian.little);
  final sign = (bits >> 16) & 0x8000;
  var exp = ((bits >> 23) & 0xFF) - 127 + 15;
  var mant = bits & 0x7FFFFF;

  if (exp >= 0x1F) return sign | 0x7C00; // inf / overflow
  if (exp <= 0) {
    if (exp < -10) return sign;
    mant |= 0x800000;
    final shift = 14 - exp;
    var sub = mant >> shift;
    if (((mant >> (shift - 1)) & 1) == 1) sub += 1;
    return sign | sub;
  }

  var half = sign | (exp << 10) | (mant >> 13);
  if ((mant & 0x1000) != 0) half += 1;
  return half & 0xFFFF;
}
