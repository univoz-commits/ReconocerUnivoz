import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('preview Flutter descarta landmarks fuera de cuadro', () {
    final source = File('lib/skeleton_painter.dart').readAsStringSync();

    expect(source, contains('bool _puntoEnCuadro'));
    expect(source, contains('p[0] >= 0 && p[0] <= 1'));
    expect(source, contains('p[1] >= 0 && p[1] <= 1'));
    expect(source, contains('if (!_puntoEnCuadro(pa)'));
    expect(source, contains('if (!_puntoEnCuadro(p)) continue;'));
  });

  test('preview Flutter conserva perspectiva anatomica sin espejo', () {
    final espejo = File('lib/pantalla_espejo.dart').readAsStringSync();
    final captura = File('lib/pantalla_captura.dart').readAsStringSync();
    final traduccion = File('lib/skeleton_painter.dart').readAsStringSync();

    expect(espejo, isNot(contains('Matrix4.diagonal3Values')));
    expect(captura, isNot(contains('Matrix4.diagonal3Values')));
    expect(traduccion, isNot(contains('Matrix4.diagonal3Values')));
    expect(espejo, isNot(contains('camara.espejo')));
    expect(captura, isNot(contains('camara.espejo')));
    expect(traduccion, isNot(contains('camara.espejo')));
  });
}
