import 'package:test/test.dart';

import 'package:senas_core/backend_api.dart';

void main() {
  test('BackendPrediction lee respuesta estable de inferencia', () {
    final result = BackendPrediction.fromJson({
      'label': 'CASA',
      'confidence': 0.94,
      'classifier': 'svm',
      'model_version': 'svm-v2',
    });

    expect(result.label, 'CASA');
    expect(result.confidence, closeTo(0.94, 1e-12));
    expect(result.classifier, 'svm');
    expect(result.toJson()['model_version'], 'svm-v2');
  });

  test('BackendPrediction permite rechazo sin etiqueta', () {
    final result = BackendPrediction.fromJson({
      'label': null,
      'confidence': 0,
      'classifier': 'knn',
      'model_version': 'baseline-v2',
    });

    expect(result.label, isNull);
    expect(result.confidence, 0);
  });
}
