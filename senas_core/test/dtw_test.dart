/// Golden test del clasificador DTW: valida que Dart calcule las mismas
/// distancias que Python sobre los mismos frames.
///
///   dart test
///
/// Dentro de un proyecto de Flutter: cambia el import de package:test por
/// package:flutter_test/flutter_test.dart y corre `flutter test`.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:senas_core/dtw.dart';
import 'package:senas_core/sign_norm.dart';

const String kGoldenPath = 'test/golden/golden_cases.json';

List<double> _vec(dynamic raw) =>
    (raw as List).map<double>((v) => (v as num).toDouble()).toList();

List<List<double>> _seq(dynamic raw) =>
    (raw as List).map<List<double>>(_vec).toList();

void main() {
  final file = File(kGoldenPath);
  if (!file.existsSync()) {
    throw StateError('no encuentro $kGoldenPath — corre python3 tools/gen_golden.py');
  }
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final tol = (data['tolerance'] as num).toDouble();
  final dtwGolden = data['dtw'] as Map<String, dynamic>;

  final casos = data['cases'] as List;
  final a = _seq((casos[0] as Map)['expected_frames']);
  final b = _seq((casos[1] as Map)['expected_frames']);

  test('los pesos coinciden con los de Python', () {
    final p = dtwGolden['pesos'] as Map<String, dynamic>;
    expect(p['body'], kWBody);
    expect(p['loc'], kWLoc);
    expect(p['pres'], kWPres);
    expect(p['shape'], kWShape);
    expect(p['shape_penalty'], kShapePenalty);
    expect(p['band'], kBand);
  });

  test('distancias entre frames', () {
    final esperado = (dtwGolden['frame_distances'] as List).map(_vec).toList();
    for (var i = 0; i < a.length; i++) {
      for (var j = 0; j < b.length; j++) {
        expect((frameDistance(a[i], b[j]) - esperado[i][j]).abs(), lessThan(tol),
            reason: 'frame_distance($i, $j)');
      }
    }
  });

  test('la distancia entre frames es simetrica y cero consigo misma', () {
    expect(frameDistance(a[0], a[0]), 0.0);
    expect((frameDistance(a[0], b[0]) - frameDistance(b[0], a[0])).abs(),
        lessThan(1e-12));
  });

  test('DTW coincide con Python', () {
    expect((dtwDistance(a, a) - (dtwGolden['dtw_a_a'] as num).toDouble()).abs(),
        lessThan(tol));
    expect((dtwDistance(a, b) - (dtwGolden['dtw_a_b'] as num).toDouble()).abs(),
        lessThan(tol));
    expect((dtwDistance(b, a) - (dtwGolden['dtw_b_a'] as num).toDouble()).abs(),
        lessThan(tol));
  });

  test('signature coincide con Python', () {
    final esperado = _vec(dtwGolden['signature_a']);
    final got = signature(a);
    expect(got.length, kFrameDim);
    for (var i = 0; i < kFrameDim; i++) {
      expect((got[i] - esperado[i]).abs(), lessThan(tol), reason: 'dim $i');
    }
  });

  test('el ceiling corta sin cambiar el resultado cuando no aplica', () {
    final d = dtwDistance(a, b);
    expect(dtwDistance(a, b, ceiling: d * 2), closeTo(d, 1e-12));
    expect(dtwDistance(a, b, ceiling: d * 0.1), double.infinity);
  });

  test('el clasificador elige la plantilla correcta', () {
    final clf = DtwClassifier(prefilter: 0);
    clf.add('1', 'CASA', a);
    clf.add('2', 'AGUA', b);

    final p = clf.classify(a);
    expect(p.gloss, 'CASA');
    expect(p.distance, lessThan(1e-9));
    expect(p.aceptada, isTrue);

    final q = clf.classify(b);
    expect(q.gloss, 'AGUA');
  });

  test('rechaza cuando nada se parece', () {
    final clf = DtwClassifier(prefilter: 0);
    clf.add('1', 'CASA', a);

    final lejos = a
        .map((f) => List<double>.generate(kFrameDim, (i) => f[i] + 3.0))
        .toList();
    expect(clf.classify(lejos).aceptada, isFalse);
  });
}
