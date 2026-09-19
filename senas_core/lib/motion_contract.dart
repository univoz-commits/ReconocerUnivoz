/// Contratos versionados compartidos por captura, avatar y modelos IA.
library motion_contract;

import 'sign_norm.dart' show kFrameDim, kNormVersion, kTFrames;

/// Un frame normalizado de [kFrameDim] dimensiones.
class MotionFrameV2 {
  final List<double> values;

  MotionFrameV2(Iterable<num> values)
      : values = List<double>.unmodifiable(
          values.map((value) => value.toDouble()),
        ) {
    if (this.values.length != kFrameDim) {
      throw FormatException(
        'MotionFrameV2 requiere $kFrameDim dimensiones, '
        'recibió ${this.values.length}.',
      );
    }
    if (this.values.any((value) => !value.isFinite)) {
      throw const FormatException('MotionFrameV2 contiene NaN o infinito.');
    }
  }

  factory MotionFrameV2.fromJson(Object? json) {
    if (json is! List) {
      throw const FormatException('MotionFrameV2 debe ser una lista.');
    }
    return MotionFrameV2(json.cast<num>());
  }

  List<double> toJson() => List<double>.from(values);
}

/// Secuencia canónica: 32 frames normalizados de 152 dimensiones.
class MotionSequenceV2 {
  final List<List<double>> frames;
  final int fps;
  final List<int> timestampsMs;
  final String normVersion;

  MotionSequenceV2._({
    required List<List<double>> frames,
    required this.fps,
    required List<int> timestampsMs,
    required this.normVersion,
  })  : frames = List<List<double>>.unmodifiable(
          frames.map((frame) => List<double>.unmodifiable(frame)),
        ),
        timestampsMs = List<int>.unmodifiable(timestampsMs) {
    _validar();
  }

  factory MotionSequenceV2.fromFrames(
    List<List<double>> frames, {
    int fps = 30,
    List<int>? timestampsMs,
    String normVersion = kNormVersion,
  }) {
    return MotionSequenceV2._(
      frames: frames,
      fps: fps,
      timestampsMs: timestampsMs ?? const [],
      normVersion: normVersion,
    );
  }

  factory MotionSequenceV2.fromJson(Map<String, dynamic> json) {
    final rawFrames = json['frames'];
    if (rawFrames is! List) {
      throw const FormatException('MotionSequenceV2 no contiene frames.');
    }
    return MotionSequenceV2.fromFrames(
      rawFrames
          .map<List<double>>((frame) => MotionFrameV2.fromJson(frame).values)
          .toList(),
      fps: (json['fps'] as num?)?.toInt() ?? 30,
      timestampsMs: (json['timestamps_ms'] as List?)
              ?.map((value) => (value as num).toInt())
              .toList() ??
          const [],
      normVersion: json['norm_version'] as String? ?? kNormVersion,
    );
  }

  int get tFrames => frames.length;

  Map<String, dynamic> toJson() => {
        'norm_version': normVersion,
        't_frames': tFrames,
        'frame_dim': kFrameDim,
        'fps': fps,
        if (timestampsMs.isNotEmpty) 'timestamps_ms': timestampsMs,
        'frames': frames,
      };

  void _validar() {
    if (normVersion != kNormVersion) {
      throw FormatException(
        'norm_version incompatible: $normVersion; se esperaba $kNormVersion.',
      );
    }
    if (fps <= 0 || fps > 120) {
      throw FormatException('FPS fuera de rango: $fps.');
    }
    if (frames.length != kTFrames) {
      throw FormatException(
        'MotionSequenceV2 requiere $kTFrames frames, recibió ${frames.length}.',
      );
    }
    for (var i = 0; i < frames.length; i++) {
      if (frames[i].length != kFrameDim) {
        throw FormatException(
          'Frame $i requiere $kFrameDim dimensiones, '
          'recibió ${frames[i].length}.',
        );
      }
      if (frames[i].any((value) => !value.isFinite)) {
        throw FormatException('Frame $i contiene NaN o infinito.');
      }
    }
    if (timestampsMs.isNotEmpty && timestampsMs.length != frames.length) {
      throw const FormatException(
          'timestamps_ms debe tener un valor por frame.');
    }
  }
}

/// Anclas de entrada para convertir gesto físico de pulgar en cierre [0,1].
class ThumbCalibration {
  final bool calibrated;
  final double openDistance;
  final double closedDistance;
  final List<double> openAngles;
  final List<double> closedAngles;
  final int updatedAtMs;

  const ThumbCalibration({
    this.calibrated = false,
    this.openDistance = 0.72,
    this.closedDistance = 0.22,
    this.openAngles = const [0.45, 0.18, 0.12],
    this.closedAngles = const [1.0, 0.85, 0.85],
    this.updatedAtMs = 0,
  });

  factory ThumbCalibration.fromJson(Map<String, dynamic> json) {
    List<double> angles(String key, List<double> fallback) {
      final raw = json[key];
      if (raw is! List || raw.length != 3) return fallback;
      final values = raw.map((value) => (value as num).toDouble()).toList();
      return values.every((value) => value.isFinite) ? values : fallback;
    }

    final openDistance = (json['open_distance'] as num?)?.toDouble() ?? 0.72;
    final closedDistance =
        (json['closed_distance'] as num?)?.toDouble() ?? 0.22;
    return ThumbCalibration(
      calibrated: json['calibrated'] == true &&
          openDistance.isFinite &&
          closedDistance.isFinite &&
          (openDistance - closedDistance).abs() >= 0.04,
      openDistance: openDistance.isFinite ? openDistance : 0.72,
      closedDistance: closedDistance.isFinite ? closedDistance : 0.22,
      openAngles: angles('open_angles', const [0.45, 0.18, 0.12]),
      closedAngles: angles('closed_angles', const [1.0, 0.85, 0.85]),
      updatedAtMs: (json['updated_at_ms'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'calibrated': calibrated,
        'open_distance': openDistance,
        'closed_distance': closedDistance,
        'open_angles': openAngles,
        'closed_angles': closedAngles,
        'updated_at_ms': updatedAtMs,
      };
}

/// Parámetros de adaptación entre espacio normalizado y rig VRM.
class RigCalibration {
  final int version;
  final double avatarScale;
  final bool invertZ;
  final double leftArmGain;
  final double rightArmGain;
  final double ikMin;
  final double ikMax;
  final double fingerSensitivity;
  final double wristCompensation;
  final bool resetHandOnLoss;
  final ThumbCalibration leftThumb;
  final ThumbCalibration rightThumb;

  const RigCalibration({
    this.version = 2,
    this.avatarScale = 1.0,
    this.invertZ = false,
    this.leftArmGain = 1.0,
    this.rightArmGain = 1.0,
    this.ikMin = 0.05,
    this.ikMax = 2.60,
    this.fingerSensitivity = 1.0,
    this.wristCompensation = 0.0,
    this.resetHandOnLoss = true,
    this.leftThumb = const ThumbCalibration(),
    this.rightThumb = const ThumbCalibration(),
  });

  factory RigCalibration.fromJson(Map<String, dynamic> json) {
    final sourceVersion = (json['version'] as num?)?.toInt() ?? 1;
    final thumbs =
        (json['thumb_calibration'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
    final left = (thumbs['left'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final right = (thumbs['right'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    return RigCalibration(
      version: 2,
      avatarScale: (json['avatar_scale'] as num?)?.toDouble() ?? 1.0,
      invertZ: json['invert_z'] as bool? ?? false,
      leftArmGain: (json['left_arm_gain'] as num?)?.toDouble() ?? 1.0,
      rightArmGain: (json['right_arm_gain'] as num?)?.toDouble() ?? 1.0,
      ikMin: (json['ik_min'] as num?)?.toDouble() ?? 0.05,
      ikMax: (json['ik_max'] as num?)?.toDouble() ?? 2.60,
      fingerSensitivity:
          (json['finger_sensitivity'] as num?)?.toDouble() ?? 1.0,
      wristCompensation:
          (json['wrist_compensation'] as num?)?.toDouble() ?? 0.0,
      resetHandOnLoss: json['reset_hand_on_loss'] as bool? ?? true,
      leftThumb: sourceVersion >= 2
          ? ThumbCalibration.fromJson(left)
          : const ThumbCalibration(),
      rightThumb: sourceVersion >= 2
          ? ThumbCalibration.fromJson(right)
          : const ThumbCalibration(),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'avatar_scale': avatarScale,
        'invert_z': invertZ,
        'left_arm_gain': leftArmGain,
        'right_arm_gain': rightArmGain,
        'ik_min': ikMin,
        'ik_max': ikMax,
        'finger_sensitivity': fingerSensitivity,
        'wrist_compensation': wristCompensation,
        'reset_hand_on_loss': resetHandOnLoss,
        'thumb_calibration': {
          'left': leftThumb.toJson(),
          'right': rightThumb.toJson(),
        },
      };

  RigCalibration copyWith({
    int? version,
    double? avatarScale,
    bool? invertZ,
    double? leftArmGain,
    double? rightArmGain,
    double? ikMin,
    double? ikMax,
    double? fingerSensitivity,
    double? wristCompensation,
    bool? resetHandOnLoss,
    ThumbCalibration? leftThumb,
    ThumbCalibration? rightThumb,
  }) =>
      RigCalibration(
        version: version ?? this.version,
        avatarScale: avatarScale ?? this.avatarScale,
        invertZ: invertZ ?? this.invertZ,
        leftArmGain: leftArmGain ?? this.leftArmGain,
        rightArmGain: rightArmGain ?? this.rightArmGain,
        ikMin: ikMin ?? this.ikMin,
        ikMax: ikMax ?? this.ikMax,
        fingerSensitivity: fingerSensitivity ?? this.fingerSensitivity,
        wristCompensation: wristCompensation ?? this.wristCompensation,
        resetHandOnLoss: resetHandOnLoss ?? this.resetHandOnLoss,
        leftThumb: leftThumb ?? this.leftThumb,
        rightThumb: rightThumb ?? this.rightThumb,
      );
}
