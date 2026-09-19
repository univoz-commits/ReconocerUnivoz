/// Cliente HTTP opcional para inferencia remota.
library backend_api;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config_backend.dart';
import 'motion_contract.dart';

class BackendError implements Exception {
  final String mensaje;
  BackendError(this.mensaje);
  @override
  String toString() => mensaje;
}

class BackendPrediction {
  final String? label;
  final double confidence;
  final String classifier;
  final String modelVersion;

  const BackendPrediction({
    required this.label,
    required this.confidence,
    required this.classifier,
    required this.modelVersion,
  });

  factory BackendPrediction.fromJson(Map<String, dynamic> json) =>
      BackendPrediction(
        label: json['label'] as String?,
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
        classifier: json['classifier'] as String? ?? 'unknown',
        modelVersion: json['model_version'] as String? ?? 'unknown',
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'confidence': confidence,
        'classifier': classifier,
        'model_version': modelVersion,
      };
}

class BackendApi {
  final String baseUrl;
  final http.Client _http;

  BackendApi({String? url, http.Client? client})
      : baseUrl = (url ?? kBackendUrl).replaceAll(RegExp(r'/+$'), ''),
        _http = client ?? http.Client();

  bool get configurado => baseUrl.isNotEmpty;

  Future<BackendPrediction> clasificar(List<List<double>> frames) async {
    if (!configurado) {
      throw BackendError('AI Engine no configurado.');
    }
    final secuencia = MotionSequenceV2.fromFrames(frames);
    final response = await _http.post(
      Uri.parse('$baseUrl/v1/classify'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'norm_version': secuencia.normVersion,
        'frames': secuencia.frames,
      }),
    );
    if (response.statusCode >= 400) {
      throw BackendError(
          'AI Engine falló (HTTP ${response.statusCode}): ${response.body}');
    }
    final raw = jsonDecode(response.body);
    if (raw is! Map) throw BackendError('Respuesta inválida del AI Engine.');
    return BackendPrediction.fromJson(raw.cast<String, dynamic>());
  }

  Future<bool> saludable() async {
    if (!configurado) return false;
    final response = await _http.get(Uri.parse('$baseUrl/health'));
    return response.statusCode == 200;
  }

  void cerrar() => _http.close();
}
