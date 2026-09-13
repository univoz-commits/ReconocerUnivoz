import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('visor expone contrato RigBody V2 sin cola de frames vivos', () {
    final html = File('assets/avatar_viewer/index.html').readAsStringSync();

    expect(html, contains('window.configurarRig'));
    expect(html, contains('window.aplicarFrameVivo'));
    expect(html, contains('RigBodyEngine'));
    expect(html, contains('aplicarTorso'));
    expect(html, contains('getNormalizedBoneNode'));
    expect(html, contains('anchoHombrosAvatar'));
    expect(html, contains('radioObjetivo'));
    expect(html, contains('elbowTarget'));
    expect(html, contains('timestampMs'));
    expect(html, contains('quality'));
    expect(html, contains('kFrameDim = 152'));
    expect(html, contains('frameVivo'));
    expect(html, contains('createRigSafetyGate'));
    expect(html, contains('aplicarRotacionSegura'));
    expect(html, contains('fingerRenderState'));
    expect(html, contains('fingerLag'));
    expect(html, contains('rigAudit'));
    expect(html, contains('deadbandHeld'));
    expect(html, contains('posarReposoBrazo'));
  });
}
