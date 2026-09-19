# RigBody, IK y retargeting VRM

## Principios

- Las posiciones de usuario no se aplican directamente sobre huesos VRM.
- El avatar tiene longitudes, ejes y pose de reposo propios.
- Orientación interna: cuaterniones.
- Dedos: ángulos locales por segmento.
- Brazos: objetivo de muñeca + plano/polo de codo.
- Ningún candidato llega al avatar sin pasar `Safety Gate` por unión.

## IK de dos huesos

Entradas:

```text
S = hombro
T = objetivo de muñeca
P = polo de codo
a = longitud del brazo superior del avatar
b = longitud del antebrazo del avatar
```

1. Clampear `d=|T-S|` a `|a-b|+ε ... a+b-ε`.
2. Obtener el ángulo con ley de cosenos.
3. Proyectar el polo sobre el plano perpendicular a `T-S`.
4. Resolver el codo en el lado indicado por el polo.
5. Resolver antebrazo contra el objetivo ya clampeado.
6. Aplicar límites y continuidad temporal.

El objetivo clampeado debe usarse para upper arm y lower arm. Usar el objetivo
original en una sola parte estira el brazo de forma imposible.

## Límites

Valores iniciales:

- codo: aproximadamente `0°–145°/150°`;
- muñeca: flexión/extensión y desviación limitadas;
- hombro: elevación y twist limitados;
- falange: tope por segmento;
- pulgar: rango separado.

Los límites del rig son aproximaciones de seguridad, no diagnóstico médico.
Exponer ajustes solo cuando faciliten calibración visual.

## Cuaterniones

Para cada nueva orientación:

```javascript
if (dot(q_prev, q_new) < 0) q_new = negate(q_new);
q_out = slerp(q_prev, q_new, alpha);
```

Usar `nlerp` cuando el ángulo sea pequeño y rendimiento sea más importante.
Separar `swing` y `twist` en antebrazo/hombro si el rig presenta torsión.

## Safety Gate

`rig_safety.mjs` valida finitud, quaternion, timestamp, `frameId`, padre,
longitud ósea, límites, velocidad angular, etapa e identidad de mano antes de
escribir `rotation` o `quaternion`. Códigos incluyen
`non_finite_transform`, `invalid_quaternion`, `bone_length_drift`,
`joint_limit_violation`, `quaternion_flip`, `stale_frame`,
`hand_identity_swap`, `parent_frame_mismatch` y `stage_desync`.

Estado por unión: `VALID → FROZEN → RECOVERING → VALID`. Rechazo conserva la
última pose local y no congela otras uniones. Recuperación usa tres frames y
mezcla gradual; prueba sintética confirma que escritor no aplica NaN.

## Manos

Los cuatro dedos largos siguen `Proximal → Intermediate → Distal`. El pulgar
del avatar presente usa `Metacarpal → Proximal → Distal`. La nomenclatura debe
detectarse desde `VRMHumanBoneName`, no suponerse.

Si una cadena de falanges es degenerada:

- no abrir/cerrar de golpe;
- conservar última rotación válida;
- bajar confianza;
- esperar una cadena geométricamente útil.

La ruta rápida usa `FingerRenderState` separado de `MotionFrameV2`: forma XYZ
queda sin segundo suavizado, ángulos MCP/PIP/DIP reciben un único filtro rápido
y cada entrada se identifica por timestamp para evitar colas viejas.

## Render y datos

El suavizado es visual: no debe contaminar el vector guardado si la captura
requiere datos canónicos. El avatar puede interpolar a 60 FPS entre estados de
tracking a 30 FPS.
