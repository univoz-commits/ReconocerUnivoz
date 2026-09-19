import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('visor web expone cámara MediaPipe y contrato Motion V2', () {
    final html = File('assets/avatar_viewer/index.html').readAsStringSync();
    final bridge = File('lib/camera_bridge.dart').readAsStringSync();
    final tracking =
        File('assets/avatar_viewer/rig_tracking.mjs').readAsStringSync();

    expect(html, contains('getUserMedia'));
    expect(html, contains('PoseLandmarker'));
    expect(html, contains('HandLandmarker'));
    expect(html, contains('normalizarFrameWeb'));
    expect(html, contains('window.iniciarCamaraWeb'));
    expect(html, contains('window.detenerCamaraWeb'));
    expect(html, contains('window.webCameraState'));
    expect(html, contains('precargarDetectoresWeb'));
    expect(html, contains('detectorsReady'));
    expect(html, contains('hand_landmarks_incomplete'));
    expect(html, contains('leftHandPoints'));
    expect(html, contains('rightHandPoints'));
    expect(html, contains('assignHandsByArmChain'));
    expect(html, contains('shouldRunPoseFrame'));
    expect(html, contains('sideLocked'));
    expect(html, contains('handAssignmentMode'));
    expect(html, contains('kFrameDim = 152'));
    expect(html, contains('kTFrames = 32'));
    expect(html, contains('const ahora = Math.round(performance.now())'));
    expect(html, isNot(contains('performance.timeOrigin + performance.now')));
    expect(html, contains('if (webCameraState.running)'));
    expect(html, contains('webCameraState.running = false'));
    expect(html, contains('resolveAnatomicalHandSide'));
    expect(html, contains('pose_pending'));
    expect(html, contains('sideLocked'));
    expect(html, isNot(contains('function ladoFisicoManoWeb')));
    expect(html, isNot(contains('function poseMunecaConfiableWeb')));
    expect(html, contains('function puntoEnCuadroWeb'));
    expect(html, contains('createRigSafetyGate'));
    expect(html, contains('maxAngularVelocityRadS'));
    expect(html, contains('fases[0] === \'Metacarpal\''));
    expect(html, contains('let angulos = [anguloCmc, anguloMcp, anguloIp]'));
    expect(html, contains('thumbRigMap'));
    expect(html, contains('iniciarCalibracionPulgares'));
    expect(html, contains('function webManoUtilizable'));
    expect(html, contains('function webPoseGeometriaValida'));
    expect(html, contains('resetHandOnLoss'));
    expect(html, contains('kHandLossGraceMs = 250'));
    expect(html, contains('actualizarEstadoPerdidaMano'));
    expect(html, contains('camaraReposoMano'));
    expect(html, contains('const centroHombros ='));
    expect(html, contains('H-I'));
    expect(html, contains('H-D'));
    expect(html, contains('I:'));
    expect(html, isNot(contains('else if (!left) left = manos[i];')));
    expect(html, isNot(contains('id="camaraEspejo"')));
    expect(html, isNot(contains('camaraVideo.espejo')));
    expect(
        html, isNot(contains('if (typeof webHandTracker !== \'undefined\')')));
    expect(html, contains('hand_side_ambiguous'));
    expect(html, contains('hand_assignment_hysteresis'));
    expect(html, contains('motionScore'));
    expect(html, contains('fingerMotionScore'));
    expect(html, contains('renderFps'));
    expect(html, contains('renderPixelRatio'));
    expect(html, contains('captureFps'));
    expect(html, contains('poseP95Ms'));
    expect(html, contains('handP95Ms'));
    expect(html, contains('processP95Ms'));
    expect(tracking, contains('hand_surface_flip'));
    expect(tracking, contains('handSurfaceTransition'));
    expect(html, contains('wristDisagreementState'));
    expect(html, contains('state.frames >= 3'));
    expect(html, contains('droppedVideoFrames'));
    expect(html, contains('if (vrm) posarReposo();'));
    expect(html, contains('suavizarFrameWeb'));
    expect(html, contains('Suavizar movimiento'));
    expect(html, contains('webGrabacion.push(vector.slice())'));
    expect(html, contains('const refHand ='));
    expect(html, contains('function vectorManoAAvatar'));
    expect(html, contains('makeBasis'));
    expect(html, contains('mano.parent.getWorldQuaternion'));
    expect(html, contains('usarMuneca: true'));
    expect(html, contains('function ponerMunecaReposo'));
    expect(html, contains('id="sMuneca"'));
    expect(html, contains("cal.usarMuneca = \$('sMuneca').checked"));
    expect(html, contains('function calcularCalidadFrameWeb'));
    expect(html, contains('lastValidAt'));
    expect(html, contains('kFrameStaleMs'));
    expect(html, contains('staleMs'));
    expect(html, contains('frameVivoRecibidoAt'));
    expect(html, contains('frameVivoExterno'));
    expect(html, contains('frameVivoStale'));
    expect(html, contains('frameVivoRecibidoAt = performance.now()'));
    expect(
        html,
        contains(
            'const streamExternoEnVivo = !standaloneWeb && frameVivoExterno'));
    expect(html, isNot(contains('id="sProf"')));
    expect(html, contains('Q:'));
    expect(html, contains('rig_safety.mjs'));
    expect(html, contains('createAuditSnapshot'));
    expect(html, contains('stage_desync'));
    expect(html, contains('webPoseCache'));
    expect(html, contains('Hands run every accepted frame'));
    expect(bridge, contains('swapHands: false'));
  });

  test('visor web directo activa standalone sin depender de query manual', () {
    final html = File('assets/avatar_viewer/index.html').readAsStringSync();

    expect(html, contains("!window.SenasChannel"));
    expect(html, contains("window.location.protocol"));
  });

  test('raíz del servidor web redirige al visor standalone', () {
    final html = File('index.html').readAsStringSync();

    expect(html, contains('assets/avatar_viewer/index.html?standalone=1'));
  });
}
