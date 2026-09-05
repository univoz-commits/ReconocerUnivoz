/// Normalizacion de landmarks para reconocimiento de senas.
///
/// Espejo exacto de python/sign_norm.py. Cualquier cambio aqui tiene que
/// hacerse alla tambien, y el golden test tiene que seguir pasando en ambos.
///
/// Este archivo no depende de Flutter a proposito: asi corre en `dart test`
/// sin levantar un emulador.
library sign_norm;

import 'dart:math' as math;
import 'dart:typed_data';

const String kNormVersion = '1.0.0';
const int kTFrames = 32;
const int kFrameDim = 138;

const int kLShoulder = 11;
const int kRShoulder = 12;
const List<int> kPoseBodyIdx = [13, 14, 15, 16, 23, 24];
const List<List<int>> kBodyMirrorPairs = [
  [0, 1],
  [2, 3],
  [4, 5],
];

const int kHandWrist = 0;
const int kHandMiddleMcp = 9;
const int kNHandPts = 20;

const double kMinVisibility = 0.5;
const double kEps = 1e-6;

const int kOffBody = 0;
const int kOffLocL = 12;
const int kOffLocR = 14;
const int kOffPresL = 16;
const int kOffPresR = 17;
const int kOffShapeL = 18;
const int kOffShapeR = 78;

/// Un landmark: [x, y, z] y opcionalmente visibility en la posicion 3.
typedef Landmark = List<double>;

/// Normaliza un frame. Devuelve null si el frame no sirve.
List<double>? normalizeFrame(
  List<Landmark>? pose, {
  List<Landmark>? left,
  List<Landmark>? right,
  double minVisibility = kMinVisibility,
}) {
  if (pose == null || pose.length < 33) return null;

  final ls = pose[kLShoulder];
  final rs = pose[kRShoulder];
  if (ls.length > 3 &&
      (ls[3] < minVisibility || rs[3] < minVisibility)) {
    return null;
  }

  final ox = (ls[0] + rs[0]) * 0.5;
  final oy = (ls[1] + rs[1]) * 0.5;

  final dx = rs[0] - ls[0];
  final dy = rs[1] - ls[1];
  final scale = math.sqrt(dx * dx + dy * dy);
  if (scale < kEps) return null;
  final cosT = dx / scale;
  final sinT = dy / scale;

  final out = List<double>.filled(kFrameDim, 0.0);

  for (var i = 0; i < kPoseBodyIdx.length; i++) {
    final p = pose[kPoseBodyIdx[i]];
    final x = p[0] - ox;
    final y = p[1] - oy;
    out[kOffBody + i * 2] = (x * cosT + y * sinT) / scale;
    out[kOffBody + i * 2 + 1] = (-x * sinT + y * cosT) / scale;
  }

  final hands = [
    [left, kOffLocL, kOffPresL, kOffShapeL],
    [right, kOffLocR, kOffPresR, kOffShapeR],
  ];

  for (final h in hands) {
    final hand = h[0] as List<Landmark>?;
    if (hand == null || hand.length < 21) continue;
    final offLoc = h[1] as int;
    final offPres = h[2] as int;
    final offShape = h[3] as int;

    final w = hand[kHandWrist];
    final wx = w[0] - ox;
    final wy = w[1] - oy;
    out[offLoc] = (wx * cosT + wy * sinT) / scale;
    out[offLoc + 1] = (-wx * sinT + wy * cosT) / scale;
    out[offPres] = 1.0;

    final m = hand[kHandMiddleMcp];
    final hdx = m[0] - w[0];
    final hdy = m[1] - w[1];
    var handScale = math.sqrt(hdx * hdx + hdy * hdy);
    if (handScale < kEps) handScale = scale * 0.25;

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
List<double> mirrorFrame(List<double> v) {
  final out = List<double>.filled(kFrameDim, 0.0);

  for (final pair in kBodyMirrorPairs) {
    final a = pair[0];
    final b = pair[1];
    out[kOffBody + a * 2] = -v[kOffBody + b * 2];
    out[kOffBody + a * 2 + 1] = v[kOffBody + b * 2 + 1];
    out[kOffBody + b * 2] = -v[kOffBody + a * 2];
    out[kOffBody + b * 2 + 1] = v[kOffBody + a * 2 + 1];
  }

  out[kOffLocL] = -v[kOffLocR];
  out[kOffLocL + 1] = v[kOffLocR + 1];
  out[kOffLocR] = -v[kOffLocL];
  out[kOffLocR + 1] = v[kOffLocL + 1];

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
