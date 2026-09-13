import 'package:test/test.dart';

import 'package:senas_core/camera_bridge.dart';

List<double> _pose({double visibility = 0.8}) => List<double>.generate(
      33 * 4,
      (i) => i % 4 == 3 ? visibility : i / 100,
    );

List<double> _validPose() {
  final pose = List<double>.filled(33 * 4, 0);
  for (var i = 0; i < 33; i++) pose[i * 4 + 3] = .8;
  pose[11 * 4] = .3;
  pose[11 * 4 + 1] = .4;
  pose[12 * 4] = .7;
  pose[12 * 4 + 1] = .4;
  return pose;
}

List<double> _validWorldPose() {
  final world = List<double>.filled(33 * 3, 0);
  void point(int index, double x, double y, double z) {
    world[index * 3] = x;
    world[index * 3 + 1] = y;
    world[index * 3 + 2] = z;
  }

  point(11, -.2, .5, 0);
  point(12, .2, .5, 0);
  point(23, -.15, 0, 0);
  point(24, .15, 0, 0);
  return world;
}

void main() {
  test('LandmarkFrameV1 conserva landmarks y metadata en JSON', () {
    final frame = LandmarkFrame.fromMap({
      't': 1234,
      'pose': _validPose(),
      'poseMundo': _validWorldPose(),
      'left': List<double>.filled(21 * 3, 0.2),
      'right': null,
      'renderLeft': List<double>.filled(21 * 3, 0.25),
      'renderRight': List<double>.filled(21 * 3, 0.3),
      'pose_t': 1200,
      'hands_t': 1234,
      'source_skew_ms': 34,
      'association': {'left_state': 'TRACKING', 'right_state': 'OCCLUDED'},
      'errors': [
        {'stage': 'association', 'code': 'hand_occluded', 'side': 'right'}
      ],
    });

    final json = frame.toJson();
    expect(json['schema'], 'LandmarkFrameV1');
    expect(json['t'], 1234);
    expect((json['pose'] as List).length, 33);
    expect(frame.visibilidadMin, closeTo(0.8, 1e-12));
    expect(frame.poseTimestampMs, 1200);
    expect(frame.handsTimestampMs, 1234);
    expect(frame.sourceSkewMs, 34);
    expect(frame.normalizeForRender(), hasLength(152));
    expect(frame.association['right_state'], 'OCCLUDED');
    expect(frame.errors.single['code'], 'hand_occluded');
    final restored = LandmarkFrame.fromMap(
        json.map((key, value) => MapEntry<Object?, Object?>(key, value)));
    expect(restored.pose, frame.pose);
    expect(restored.left, frame.left);
    expect(restored.renderRight, frame.renderRight);
  });

  test('skew de 50/120/121 ms controla proyeccion y rechazo', () {
    LandmarkFrame frame(int skew) => LandmarkFrame.fromMap({
          't': 1000,
          'pose': _validPose(),
          'poseMundo': _validWorldPose(),
          'source_skew_ms': skew,
        });

    expect(frame(50).requiereProyeccionRender, isFalse);
    expect(frame(50).fusionAceptada, isTrue);
    expect(frame(120).requiereProyeccionRender, isTrue);
    expect(frame(120).fusionAceptada, isTrue);
    expect(frame(121).fusionAceptada, isFalse);
  });

  test('LandmarkFrameV1 detecta frame incompleto sin inventar datos', () {
    final frame = LandmarkFrame.fromMap({'t': 1, 'pose': null});

    expect(frame.normalize(), isNull);
    expect(frame.esValido, isFalse);
    expect(frame.toJson()['left'], isNull);
  });
}
