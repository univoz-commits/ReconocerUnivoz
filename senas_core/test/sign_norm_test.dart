/// Golden test: valida que la normalizacion de Dart coincida con la de Python.
///
/// Si este test falla, los prototipos guardados en la base dejaron de ser
/// comparables con lo que captura la camara. Es la falla mas cara del sistema
/// y la mas dificil de diagnosticar sin este test, asi que corre en CI.
///
///   dart pub get
///   dart test
///
/// Dentro de un proyecto de Flutter: cambia el import de package:test por
/// package:flutter_test/flutter_test.dart y corre `flutter test`.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:senas_core/sign_norm.dart';

const String kGoldenPath = 'test/golden/golden_cases.json';

List<List<double>> _parseLandmarks(dynamic raw) {
  return (raw as List)
      .map<List<double>>((p) => (p as List).map((v) => (v as num).toDouble()).toList())
      .toList();
}

List<double> _parseVector(dynamic raw) {
  return (raw as List).map<double>((v) => (v as num).toDouble()).toList();
}

double _maxDiff(List<double> a, List<double> b) {
  expect(a.length, b.length, reason: 'longitudes distintas');
  var m = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > m) m = d;
  }
  return m;
}

void main() {
  final file = File(kGoldenPath);
  if (!file.existsSync()) {
    throw StateError('no encuentro $kGoldenPath — corre python3 gen_golden.py');
  }
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final tol = (data['tolerance'] as num).toDouble();

  test('la version de normalizacion coincide', () {
    expect(data['norm_version'], kNormVersion);
    expect(data['frame_dim'], kFrameDim);
  });

  for (final rawCase in data['cases'] as List) {
    final c = rawCase as Map<String, dynamic>;
    final name = c['name'] as String;
    final frames = c['frames'] as List;

    List<List<double>> normalizados() {
      final out = <List<double>>[];
      for (final rawFrame in frames) {
        final f = rawFrame as Map<String, dynamic>;
        final v = normalizeFrame(
          _parseLandmarks(f['pose']),
          left: f['left'] == null ? null : _parseLandmarks(f['left']),
          right: f['right'] == null ? null : _parseLandmarks(f['right']),
        );
        expect(v, isNotNull, reason: '$name: frame no normalizable');
        out.add(v!);
      }
      return out;
    }

    test('$name: frames normalizados', () {
      final got = normalizados();
      final esperado = (c['expected_frames'] as List).map(_parseVector).toList();
      for (var i = 0; i < got.length; i++) {
        expect(_maxDiff(got[i], esperado[i]), lessThan(tol),
            reason: '$name frame $i');
      }
    });

    test('$name: espejo del primer frame', () {
      final got = mirrorFrame(normalizados()[0]);
      final esperado = _parseVector(c['expected_mirror_frame0']);
      expect(_maxDiff(got, esperado), lessThan(tol));
    });

    test('$name: remuestreo a 5 frames', () {
      final got = resample(normalizados(), 5)!;
      final esperado = (c['expected_resample_5'] as List).map(_parseVector).toList();
      for (var i = 0; i < got.length; i++) {
        expect(_maxDiff(got[i], esperado[i]), lessThan(tol),
            reason: '$name resample $i');
      }
    });
  }

  test('doble espejo devuelve el original', () {
    final f = (data['cases'] as List).first as Map<String, dynamic>;
    final v = _parseVector((f['expected_frames'] as List).first);
    expect(_maxDiff(mirrorFrame(mirrorFrame(v)), v), lessThan(1e-12));
  });

  test('el empaquetado float16 pesa lo esperado', () {
    final f = (data['cases'] as List).first as Map<String, dynamic>;
    final v = _parseVector((f['expected_frames'] as List).first);
    final seq = List<List<double>>.generate(kTFrames, (_) => v);
    expect(packF16(seq).length, kTFrames * kFrameDim * 2);
  });
}
