import 'package:test/test.dart';

import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/controlador_captura.dart';
import 'package:senas_core/motion_contract.dart';
import 'package:senas_core/sign_norm.dart';

void main() {
  test('CapturaMovimiento expone secuencia, frames raw y métricas', () {
    final frames = List.generate(
      2,
      (i) => LandmarkFrame(
        timestampMs: i * 33,
        pose: List.generate(33, (_) => [0.0, 0.0, 0.0, 0.9]),
        poseMundo: List.generate(33, (_) => [0.0, 0.0, 0.0]),
      ),
    );
    final seq = List.generate(
      kTFrames,
      (_) => List<double>.filled(kFrameDim, 0),
    );

    final captura = CapturaMovimiento(
      secuencia: MotionSequenceV2.fromFrames(seq, fps: 30),
      framesCrudos: frames,
      framesInvalidos: 1,
      fps: 30,
      duracionMs: 33,
      visibilidadMin: 0.9,
      qualityScore: 0.5,
      checksumSha256: 'abc',
    );

    expect(captura.framesCrudos.length, 2);
    expect(captura.secuencia.frames.length, kTFrames);
    expect(captura.qualityScore, 0.5);
    expect(captura.toJson()['schema'], 'MotionCaptureV1');
  });
}
