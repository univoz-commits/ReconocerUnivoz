import 'package:test/test.dart';

import 'package:senas_core/motion_contract.dart';
import 'package:senas_core/muestras_locales.dart';
import 'package:senas_core/sign_norm.dart';

void main() {
  test('MotionSequenceV2 valida 32 frames de 152 dimensiones', () {
    final frames = List.generate(
      kTFrames,
      (_) => List<double>.filled(kFrameDim, 0.25),
    );

    final secuencia = MotionSequenceV2.fromFrames(
      frames,
      fps: 30,
      timestampsMs: List.generate(kTFrames, (i) => i * 33),
    );

    expect(secuencia.frames.length, kTFrames);
    expect(secuencia.frames.first.length, kFrameDim);
    expect(secuencia.normVersion, kNormVersion);
    expect(secuencia.toJson()['frame_dim'], kFrameDim);
  });

  test('MotionSequenceV2 rechaza dimensiones o version incompatibles', () {
    expect(
      () => MotionSequenceV2.fromFrames(
        [List<double>.filled(kFrameDim - 1, 0)],
      ),
      throwsFormatException,
    );
    expect(
      () => MotionSequenceV2.fromJson({
        'norm_version': '1.0.0',
        't_frames': kTFrames,
        'frame_dim': kFrameDim,
        'frames': List.generate(
          kTFrames,
          (_) => List<double>.filled(kFrameDim, 0),
        ),
      }),
      throwsFormatException,
    );
    expect(
      () => MotionSequenceV2.fromFrames(
        List.generate(kTFrames,
            (i) => List<double>.filled(kFrameDim, i == 0 ? double.nan : 0)),
      ),
      throwsFormatException,
    );
  });

  test('RigCalibration mantiene configuracion al serializar', () {
    final original = RigCalibration(
      avatarScale: 1.1,
      invertZ: true,
      leftArmGain: 0.8,
      rightArmGain: 1.2,
      ikMin: 0.15,
      ikMax: 1.45,
      fingerSensitivity: 0.9,
      wristCompensation: 0.2,
      resetHandOnLoss: false,
      leftThumb: const ThumbCalibration(
        calibrated: true,
        openDistance: 0.7,
        closedDistance: 0.2,
        openAngles: [0.1, 0.2, 0.3],
        closedAngles: [0.8, 0.9, 1.0],
        updatedAtMs: 123,
      ),
    );

    final copia = RigCalibration.fromJson(original.toJson());
    expect(copia.toJson(), original.toJson());
  });

  test('RigCalibration migra V1 dejando pulgares sin calibrar', () {
    final migrated = RigCalibration.fromJson({
      'version': 1,
      'avatar_scale': 1.2,
      'invert_z': true,
    });
    expect(migrated.version, 2);
    expect(migrated.avatarScale, 1.2);
    expect(migrated.invertZ, isTrue);
    expect(migrated.leftThumb.calibrated, isFalse);
    expect(migrated.rightThumb.calibrated, isFalse);
  });

  test('Ajustes persiste calibracion del RigBody', () {
    final ajustes = Ajustes();
    final calibracion = const RigCalibration(
      avatarScale: 0.95,
      invertZ: true,
      fingerSensitivity: 1.15,
    );
    final copia = Ajustes.fromJson({
      ...ajustes.toJson(),
      'rig_calibration': calibracion.toJson(),
    });

    expect(copia.rigCalibration.toJson(), calibracion.toJson());
  });

  test('Ajustes persiste modo diagnostico apagado por defecto', () {
    expect(Ajustes().rigDiagnosticMode, isFalse);
    final copy = Ajustes.fromJson({
      ...Ajustes().toJson(),
      'rig_diagnostic_mode': true,
    });
    expect(copy.rigDiagnosticMode, isTrue);
  });

  test('RigCalibration permite flexion natural del codo por defecto', () {
    expect(RigCalibration().ikMax, closeTo(2.60, 1e-12));
    expect(RigCalibration().resetHandOnLoss, isTrue);
  });
}
