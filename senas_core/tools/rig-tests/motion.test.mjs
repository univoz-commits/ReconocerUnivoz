import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';
import * as THREE from 'three';
import {
  createThumbCalibration,
  measureThumbPose,
  solveThumbPose,
} from '../../assets/avatar_viewer/rig_math.mjs';
import { createRigSafetyGate } from '../../assets/avatar_viewer/rig_safety.mjs';
import { assignHandsByArmChain } from '../../assets/avatar_viewer/rig_tracking.mjs';

// Execute production functions with real Three.js math, without camera/DOM.
const html = readFileSync(new URL('../../assets/avatar_viewer/index.html', import.meta.url), 'utf8');
function source(name) {
  const start = html.indexOf(`    function ${name}(`);
  assert.ok(start >= 0, `Missing production function ${name}`);
  return html.slice(start, html.indexOf('\n    }', start) + 6);
}
function runtime(names, extra = {}) {
  const ctx = vm.createContext({
    THREE, Math, Number, Array, kMadMinSigmaRig: 0.005, ...extra,
  });
  vm.runInContext(names.map(source).join('\n'), ctx);
  return ctx;
}
const vector = (...p) => new THREE.Vector3(...p);
const base = { pDer: vector(1,0,0), pArr: vector(0,1,0), pFre: vector(0,0,1) };
const mathRuntime = () => runtime(['vectorBaseAvatar', 'aBaseAvatar', 'vectorManoAAvatar'], {
  cal: { invertZ: false }, avDerecha: vector(-1,0,0),
  avArriba: vector(0,1,0), avFrente: vector(0,0,1),
});
const calStart = html.indexOf('const cal =');
const calBlock = html.slice(calStart, html.indexOf('\n    };', calStart));
const productionFingerSigns = {
  left: Number(calBlock.match(/left:\s*\{[^\n]*dedos:\s*(-?\d+)/)[1]),
  right: Number(calBlock.match(/right:\s*\{[^\n]*dedos:\s*(-?\d+)/)[1]),
};
const coord = (x,y,z=0) => ({ x,y,z,visibility:1 });
function pose() {
  const p = Array.from({length:33}, () => coord(0,0));
  p[11]=coord(.7,.4); p[12]=coord(.3,.4);
  p[15]=coord(.75,.2); p[16]=coord(.25,.3);
  return p;
}
function hand(x,y) { return Array.from({length:21}, () => coord(x,y)); }
const sidesRuntime = () => runtime([
  'webCoord', 'webFinito', 'poseMunecaConfiableWeb',
  'ladoPorMunecaPoseWeb', 'ladoFisicoManoWeb',
]);

test('hand at left pose wrist stays left despite contradictory category', () => {
  const c=sidesRuntime(), h=hand(.75,.2);
  assert.equal(c.ladoFisicoManoWeb(h,'Left',pose()), 'left');
});
test('crossed hands follow anatomical pose wrists, not image half', () => {
  const p=pose(); p[15]=coord(.35,.2); p[16]=coord(.65,.3);
  const c=sidesRuntime();
  assert.equal(c.ladoFisicoManoWeb(hand(.35,.2),'',p),'left');
  assert.equal(c.ladoFisicoManoWeb(hand(.65,.3),'',p),'right');
});
test('low-confidence pose wrists do not override hand fallback', () => {
  const p=pose(); p[15].visibility=.1; p[16].visibility=.1;
  assert.equal(sidesRuntime().ladoFisicoManoWeb(hand(.75,.2),'Left',p),'right');
});
test('two hands use one-to-one pose matching when one crosses center', () => {
  const p=pose(); p[15]=coord(.35,.2); p[16]=coord(.65,.3);
  const hCenter=hand(.50,.25), hRight=hand(.65,.3);
  const result=assignHandsByArmChain([
    {landmarks:hRight, side:''}, {landmarks:hCenter, side:''},
  ], {
    leftShoulder: coord(.70,.4), leftElbow: coord(.45,.3), leftWrist: p[15],
    rightShoulder: coord(.30,.4), rightElbow: coord(.55,.3), rightWrist: p[16],
    shoulderWidth: .4,
  });
  assert.deepEqual(result.sideByIndex, ['right', 'left']);
});
test('ambiguous arm-chain assignment never guesses a side', () => {
  const result = assignHandsByArmChain([
    {landmarks:hand(.49,.25), side:''},
    {landmarks:hand(.51,.25), side:''},
  ], {
    leftShoulder: coord(.40,.35), leftElbow: coord(.46,.45), leftWrist: coord(.50,.25),
    rightShoulder: coord(.60,.35), rightElbow: coord(.54,.45), rightWrist: coord(.50,.25),
    shoulderWidth: .2,
  });
  assert.deepEqual(result.sideByIndex, [null, null]);
  assert.equal(result.mode, 'ambiguous');
});
test('two low-confidence pose wrists keep handedness fallback', () => {
  const p=pose(); p[15].visibility=.1; p[16].visibility=.1;
  const c=sidesRuntime();
  assert.equal(c.ladoFisicoManoWeb(hand(.75,.2),'Left',p),'right');
  assert.equal(c.ladoFisicoManoWeb(hand(.25,.3),'Right',p),'left');
});
test('unknown hand without reliable wrists is not assigned an invented side', () => {
  assert.equal(sidesRuntime().ladoFisicoManoWeb(hand(.75,.2),'',null),null);
});
test('normalized upward fingers remain upward in avatar', () => {
  // For a front-facing person cosT=-1; image dy<0 becomes shape y>0.
  const out=mathRuntime().vectorManoAAvatar([0,1,0],base);
  assert.ok(out.y > .999, `fingers point down: ${out.y}`);
});
test('hand depth toward camera points forward on avatar', () => {
  const out=mathRuntime().vectorManoAAvatar([0,0,-1],base);
  assert.ok(out.z > .999, `palm depth reversed: ${out.z}`);
});

function thumbRuntime(side) {
  const hand = new THREE.Object3D();
  const metacarpal = new THREE.Object3D();
  const proximal = new THREE.Object3D();
  const distal = new THREE.Object3D();
  const sign = side === 'left' ? -1 : 1;
  // Bind directions from UNIVOZ's VRM thumb chain.
  metacarpal.position.set(sign * .003, -.008, -.013);
  proximal.position.set(sign * .029, -.002, -.025);
  distal.position.set(sign * .019, -.001, -.015);
  hand.add(metacarpal); metacarpal.add(proximal); proximal.add(distal);

  const names = side === 'left'
    ? { metacarpal:'leftThumbMetacarpal', proximal:'leftThumbProximal', distal:'leftThumbDistal' }
    : { metacarpal:'rightThumbMetacarpal', proximal:'rightThumbProximal', distal:'rightThumbDistal' };
  const map = {
    [names.metacarpal]: metacarpal,
    [names.proximal]: proximal,
    [names.distal]: distal,
  };
  const ctx = vm.createContext({
    THREE, Math, Number, Array,
    VRMHumanBoneName: {
      LeftThumbMetacarpal:'leftThumbMetacarpal', LeftThumbProximal:'leftThumbProximal', LeftThumbDistal:'leftThumbDistal',
      RightThumbMetacarpal:'rightThumbMetacarpal', RightThumbProximal:'rightThumbProximal', RightThumbDistal:'rightThumbDistal',
    },
    bone: name => map[name] ?? null,
    kFasesGenericas: ['Proximal', 'Intermediate', 'Distal'],
    kFasesPulgar: ['Metacarpal', 'Proximal', 'Distal'],
    cal: {
      fingerSensitivity: 1,
      thumbCalibration: {
        left: createThumbCalibration(
          measureThumbPose(openThumbShape('left')),
          measureThumbPose(bentThumbShape('left')),
          1,
        ),
        right: createThumbCalibration(
          measureThumbPose(openThumbShape('right')),
          measureThumbPose(bentThumbShape('right')),
          1,
        ),
      },
      left: { dedos: productionFingerSigns.left },
      right: { dedos: productionFingerSigns.right },
    },
    thumbRigMap: {
      left: {
        Metacarpal: {axis:'x', sign:1},
        Proximal: {axis:'y', sign:-1},
        Distal: {axis:'z', sign:1},
      },
      right: {
        Metacarpal: {axis:'x', sign:-1},
        Proximal: {axis:'y', sign:1},
        Distal: {axis:'z', sign:-1},
      },
    },
    rigThumbState: {left:null, right:null},
    thumbNeutralRig: {left:null, right:null},
    measureThumbPose,
    solveThumbPose,
  });
  vm.runInContext([
    ...['_largo','_norm','_pto','_resta','_angulo','moverMano'].map(source),
  ].join('\n'), ctx);
  return { ctx, hand, metacarpal, proximal, distal };
}

function bentThumbShape(side) {
  const s = side === 'left' ? -1 : 1;
  const points = Array.from({length:20}, () => [0,0,0]);
  // CMC, MCP, IP and tip. Flexion points toward avatar-down.
  points[0] = [s * .10, 0, 0];
  points[1] = [s * .18, -.05, 0];
  points[2] = [s * .24, -.11, 0];
  points[3] = [s * .28, -.14, 0];
  points[8] = [0, -.20, 0];
  return points;
}

function openThumbShape(side) {
  const s = side === 'left' ? -1 : 1;
  const points = Array.from({length:20}, () => [0,0,0]);
  points[0] = [s * .10, 0, 0];
  points[1] = [s * .18, .02, 0];
  points[2] = [s * .26, .03, 0];
  points[3] = [s * .34, .04, 0];
  points[8] = [0, -.20, 0];
  return points;
}

for (const side of ['left', 'right']) {
  test(`${side} thumb applies independent calibrated bone axes`, () => {
    const {ctx, hand, metacarpal, proximal, distal} = thumbRuntime(side);
    ctx.moverMano(side, true, openThumbShape(side));
    const points = bentThumbShape(side);
    ctx.moverMano(side, true, points);
    hand.updateMatrixWorld(true);
    const s = side === 'left' ? 1 : -1;
    assert.ok(metacarpal.rotation.x * s > .1, `${side} CMC axis/sign ignored`);
    assert.ok(proximal.rotation.y * -s > .1, `${side} MCP axis/sign ignored`);
    assert.ok(distal.rotation.z * s > .1, `${side} IP axis/sign ignored`);
    assert.equal(metacarpal.rotation.z, 0);
    assert.equal(proximal.rotation.z, 0);
  });
}

function handLossRuntime(resetHandOnLoss = true) {
  const calls = [];
  const ctx = runtime(['actualizarEstadoPerdidaMano'], {
    cal: {resetHandOnLoss},
    kHandLossGraceMs: 250,
    estadoPerdidaMano: {
      left: {desde: 0, enReposo: false},
      right: {desde: 0, enReposo: false},
    },
    rigThumbState: {left: {}, right: {}},
    thumbNeutralRig: {left: {}, right: {}},
    ponerManoReposo: lado => calls.push(`mano:${lado}`),
    ponerMunecaReposo: lado => calls.push(`muneca:${lado}`),
  });
  return {ctx, calls};
}

test('hand loss waits grace, returns to rest and recalibrates on reappearance', () => {
  const {ctx, calls} = handLossRuntime();
  assert.equal(ctx.actualizarEstadoPerdidaMano('left', false, 100), false);
  assert.deepEqual(calls, []);
  assert.equal(ctx.actualizarEstadoPerdidaMano('left', false, 349), false);
  assert.deepEqual(calls, []);
  assert.equal(ctx.actualizarEstadoPerdidaMano('left', false, 350), false);
  assert.deepEqual(calls, ['mano:left', 'muneca:left']);
  assert.equal(ctx.estadoPerdidaMano.left.enReposo, true);
  assert.equal(ctx.actualizarEstadoPerdidaMano('left', true, 383), true);
  assert.equal(ctx.estadoPerdidaMano.left.enReposo, false);
  assert.equal(ctx.rigThumbState.left, null);
});

test('hand loss option disabled preserves last valid hand pose', () => {
  const {ctx, calls} = handLossRuntime(false);
  ctx.actualizarEstadoPerdidaMano('right', false, 100);
  ctx.actualizarEstadoPerdidaMano('right', false, 1000);
  assert.deepEqual(calls, []);
  assert.equal(ctx.estadoPerdidaMano.right.enReposo, false);
});

test('overlay rejects non-finite and out-of-frame landmarks', () => {
  const c = runtime(['webCoord','webFinito','puntoEnCuadroWeb']);
  assert.equal(c.puntoEnCuadroWeb({x:.5,y:.5,z:0}), true);
  assert.equal(c.puntoEnCuadroWeb({x:1.01,y:.5,z:0}), false);
  assert.equal(c.puntoEnCuadroWeb({x:.5,y:-.01,z:0}), false);
  assert.equal(c.puntoEnCuadroWeb({x:NaN,y:.5,z:0}), false);
});

function validHand() {
  const p = Array.from({length:21}, () => coord(.5,.6));
  p[0] = coord(.50,.70);
  p[1] = coord(.44,.65); p[2] = coord(.39,.60);
  p[3] = coord(.36,.54); p[4] = coord(.34,.48);
  p[5] = coord(.46,.62); p[6] = coord(.45,.54);
  p[7] = coord(.44,.46); p[8] = coord(.44,.38);
  p[9] = coord(.50,.60); p[10] = coord(.50,.50);
  p[11] = coord(.50,.40); p[12] = coord(.50,.30);
  p[13] = coord(.54,.61); p[14] = coord(.56,.52);
  p[15] = coord(.57,.44); p[16] = coord(.58,.36);
  p[17] = coord(.58,.64); p[18] = coord(.61,.57);
  p[19] = coord(.63,.51); p[20] = coord(.64,.46);
  return p;
}

test('hand geometry rejects broken connections before normalization', () => {
  const c = runtime(['webCoord','webFinito','puntoEnCuadroWeb','webDistancia','webManoUtilizable'], {
    kMargenManoWeb: .15,
    kConexionesManoWeb: [
      [0,1],[1,2],[2,3],[3,4],[0,5],[5,6],[6,7],[7,8],
      [0,9],[9,10],[10,11],[11,12],[0,13],[13,14],[14,15],[15,16],
      [0,17],[17,18],[18,19],[19,20],[5,9],[9,13],[13,17],
    ],
  });
  assert.equal(c.webManoUtilizable(validHand()), true);
  const outside = validHand(); outside[12] = coord(1.4,.3);
  assert.equal(c.webManoUtilizable(outside), false);
  const jump = validHand(); jump[12] = coord(.5,.02);
  assert.equal(c.webManoUtilizable(jump), false);
});

test('production rotation writer never applies invalid transform', () => {
  const gate = createRigSafetyGate();
  const h = new THREE.Object3D();
  const c = runtime(['metaRigFrame', 'aplicarRotacionSegura'], {
    safetyGateFor: () => gate,
    reportSafetyAnomaly: () => {},
    performance: {now: () => 1000},
  });
  c.aplicarRotacionSegura(h, 'left:Index:Proximal', [0.2, 0, 0], {
    frameId: 1, timestampMs: 1000,
  });
  const before = h.rotation.x;
  const result = c.aplicarRotacionSegura(h, 'left:Index:Proximal', [NaN, 0, 0], {
    frameId: 2, timestampMs: 1033,
  });
  assert.equal(result.accepted, false);
  assert.equal(result.code, 'non_finite_transform');
  assert.equal(h.rotation.x, before);
});

function validPoseWorld() {
  const p = Array.from({length:33}, () => coord(0,0,0));
  p[11] = coord(-.2,1,0); p[12] = coord(.2,1,0);
  p[13] = coord(-.42,.7,0); p[14] = coord(.42,.7,0);
  p[15] = coord(-.55,.4,0); p[16] = coord(.55,.4,0);
  p[23] = coord(-.15,0,0); p[24] = coord(.15,0,0);
  return p;
}

function validPoseImage() {
  const p = Array.from({length:33}, () => coord(.5,.5,0));
  p[11] = coord(.4,.35); p[12] = coord(.6,.35);
  p[13] = coord(.3,.5); p[14] = coord(.7,.5);
  p[15] = coord(.25,.65); p[16] = coord(.75,.65);
  p[23] = coord(.43,1.20); p[24] = coord(.57,1.20);
  return p;
}

test('pose geometry rejects disconnected body landmarks', () => {
  const c = runtime(['webCoord','webFinito','puntoEnCuadroWeb','webDistancia','webPoseGeometriaValida'], {
    kMargenCuerpoWeb: .15,
  });
  const image = validPoseImage();
  assert.equal(c.webPoseGeometriaValida(image, validPoseWorld()), true);
  const broken = validPoseWorld(); broken[15] = coord(8,8,8);
  assert.equal(c.webPoseGeometriaValida(image, broken), false);
});

function fingerRuntime(side) {
  const hand = new THREE.Object3D();
  const proximal = new THREE.Object3D();
  const intermediate = new THREE.Object3D();
  const distal = new THREE.Object3D();
  const sign = side === 'left' ? -1 : 1;
  intermediate.position.x = sign * 0.028;
  distal.position.x = sign * 0.017;
  hand.add(proximal); proximal.add(intermediate); intermediate.add(distal);

  const names = side === 'left'
    ? { proximal:'leftIndexProximal', intermediate:'leftIndexIntermediate', distal:'leftIndexDistal' }
    : { proximal:'rightIndexProximal', intermediate:'rightIndexIntermediate', distal:'rightIndexDistal' };
  const map = {
    [names.proximal]: proximal,
    [names.intermediate]: intermediate,
    [names.distal]: distal,
  };
  const ctx = vm.createContext({
    THREE, Math, Number, Array,
    VRMHumanBoneName: {
      LeftIndexProximal:'leftIndexProximal', LeftIndexIntermediate:'leftIndexIntermediate', LeftIndexDistal:'leftIndexDistal',
      RightIndexProximal:'rightIndexProximal', RightIndexIntermediate:'rightIndexIntermediate', RightIndexDistal:'rightIndexDistal',
      LeftThumbMetacarpal: null,
    },
    bone: name => map[name] ?? null,
    cal: { fingerSensitivity: 1, left: { dedos:productionFingerSigns.left }, right: { dedos:productionFingerSigns.right } },
  });
  vm.runInContext([
    'const kFasesGenericas=["Proximal","Intermediate","Distal"];',
    'const kFasesPulgar=kFasesGenericas;',
    ...['_largo','_norm','_pto','_resta','_angulo','moverMano'].map(source),
  ].join('\n'), ctx);
  return { ctx, hand, intermediate, distal };
}

function bentIndexShape() {
  const points = Array.from({length:20}, () => [0,0,0]);
  // First index segment turns down/right from wrist; angle magnitude is
  // positive, while direction must come from the VRM side convention.
  points[4]=[0,0.2,0]; points[5]=[0.1,0.3,0];
  points[6]=[0.2,0.4,0]; points[7]=[0.3,0.5,0];
  return points;
}

for (const side of ['left','right']) {
  test(`${side} index flexion bends down, never up`, () => {
    const {ctx,hand,intermediate,distal}=fingerRuntime(side);
    ctx.moverMano(side, true, bentIndexShape());
    hand.updateMatrixWorld(true);
    const tip = distal.getWorldPosition(new THREE.Vector3());
    assert.ok(tip.y < 0, `${side} finger bent upward: y=${tip.y}`);
  });
}

function armRuntime() {
  const root=new THREE.Object3D(), up=new THREE.Object3D();
  const lo=new THREE.Object3D(), wrist=new THREE.Object3D();
  root.add(up); up.add(lo); lo.add(wrist);
  lo.position.x=.3; wrist.position.x=.25; root.updateMatrixWorld(true);
  const r={dirUp:vector(1,0,0), dirLo:vector(1,0,0), lenUp:.3,lenLo:.25,
    qUp:new THREE.Quaternion(),qLo:new THREE.Quaternion()};
  const ctx=runtime(['vectorBaseAvatar','resolverBrazo'],{
    refRig:{left:r}, bone:n=>n==='upper'?up:lo,
    VRMHumanBoneName:{LeftUpperArm:'upper',LeftLowerArm:'lower'},
    cal:{invertZ:false,leftArmGain:1,ikMin:.05,ikMax:2.60},
    avDerecha:vector(1,0,0),avArriba:vector(0,1,0),avFrente:vector(0,0,1),
    anchoHombrosAvatar:1,
  });
  return {ctx,root,up,lo,wrist};
}
for (const target of [[2,0,0],[.001,0,0],[.3,.2,0]]) {
  test(`IK respects elbow limits and bone lengths for target ${target}`, () => {
    const {ctx,root,up,lo,wrist}=armRuntime();
    ctx.resolverBrazo('left',base,vector(0,0,0),vector(.1,-.2,0),vector(...target));
    root.updateMatrixWorld(true);
    const a=up.getWorldPosition(vector()), b=lo.getWorldPosition(vector()), c=wrist.getWorldPosition(vector());
    assert.ok(Math.abs(a.distanceTo(b)-.3)<1e-8);
    assert.ok(Math.abs(b.distanceTo(c)-.25)<1e-8);
    const angle=b.clone().sub(a).angleTo(c.clone().sub(b));
    assert.ok(angle >= .05-1e-6 && angle <= 2.60+1e-6, `elbow ${angle}`);
    assert.ok(Math.abs(c.y/Math.max(c.length(),1e-9)-vector(...target).normalize().y)<1e-6,
      'clamped wrist left target ray');
  });
}
