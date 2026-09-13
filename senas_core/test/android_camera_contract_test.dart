import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Android resuelve lados con pose y asignacion global', () {
    final source = File(
      'android/app/src/main/kotlin/com/univoz/senas/LandmarkEngine.kt',
    ).readAsStringSync();
    final coordinator = File(
      'android/app/src/main/kotlin/com/univoz/senas/HandTrackCoordinator.kt',
    ).readAsStringSync();
    final plugin = File(
      'android/app/src/main/kotlin/com/univoz/senas/LandmarkPlugin.kt',
    ).readAsStringSync();

    expect(source, contains('private fun ladoPorMunecaPose('));
    expect(source, contains('val normal = costos[0].first + costos[1].second'));
    expect(source, contains('val cruzada = costos[0].second + costos[1].first'));
    expect(source, contains('abs(normal - cruzada) >= margen'));
    expect(source, contains('poseTieneMunecas(poseParaLados)'));
    expect(source, contains('MIN_POSE_WRIST_VISIBILITY'));
    expect(source, contains('pose[i * 4 + 3] >= MIN_POSE_WRIST_VISIBILITY'));
    expect(source, contains('poseTieneCadenaBrazo'));
    expect(source, contains('asignarLadosCadena'));
    expect(source, contains('costoCadenaBrazo'));
    expect(source, contains('if (lm.size != 21)'));
    expect(source, contains('arr.any { !it.isFinite() }'));
    expect(source, contains('hand_landmarks_incomplete'));
    expect(source, contains('point_non_finite'));
    expect(source, contains('sideLocked = ladoCadena != null'));
    expect(source, contains('sideAmbiguous'));
    expect(coordinator, contains('sideAmbiguous'));
    expect(coordinator, contains('hand_side_ambiguous'));
    expect(plugin, contains('rotationDegrees'));
    expect(source, isNot(contains(
      'when (ladoFisicoMano(etiqueta, lm[0].x()))',
    )));
  });

  test('CameraX keeps hand cadence and halves pose workload', () {
    final source = File(
      'android/app/src/main/kotlin/com/univoz/senas/LandmarkPlugin.kt',
    ).readAsStringSync();
    expect(source, contains('INTERVALO_MIN_POSE_NS = 66_000_000L'));
    expect(source, contains('RESOLUCION_ANALISIS = Size(360, 480)'));
    expect(source, contains('STRATEGY_KEEP_ONLY_LATEST'));
    expect(source, contains('"espejo" to false'));
  });
}
