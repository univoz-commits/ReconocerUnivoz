# RigBody y reconocimiento de señas — diseño

## Objetivo

Consolidar en una arquitectura comprobable la captura RGB, el avatar VRM y el
reconocimiento de señas, mejorando estabilidad anatómica sin romper
`MotionFrameV2` 2.0.0 de 152 dimensiones.

## Arquitectura

El sistema mantiene MediaPipe como detector y agrega capas explícitas:

```text
raw → validado → asociado → suavizado → semántico → rig/render + IA
```

Preview se mantiene separado de datos fusionados. El avatar consume estado
suavizado; captura y reconocimiento consumen secuencias canónicas.

## Decisiones

1. Usar la rama `codex/rigbody-ai`; no modificar rama principal.
2. Crear `docs/README.md` como índice propio de esta rama.
3. Mantener Flutter, Kotlin/CameraX, WebView/Three.js/VRM, Python y DTW.
4. Mantener 30 FPS de tracking, 60 FPS de render y cola de último frame.
5. No cambiar `norm_version`, orden ni dimensión del vector.
6. Tratar rostro, profundidad y embeddings como metadatos versionados aparte.
7. Priorizar geometría, filtros, tracking y restricciones antes de modelos
   paramétricos o hardware adicional.

## Componentes

### Captura

`LandmarkFrameV1` conserva pose de imagen, pose mundial, manos, timestamp y
validez. Stream fusionado alimenta normalización; preview alimenta UI.

### Validación

Confianza, finitud, rango, conexiones, longitudes óseas y outliers. El visor
aplica MAD, One Euro y rate limit a RenderState; la comparación cuantitativa
contra baseline sigue pendiente con cámara real.

### Mano

Marco con muñeca, nudillos índice/medio/meñique y CMC del pulgar. Ángulos
locales; pulgar con neutral, signo, límites e histéresis.

### Rig

IK de dos huesos con polo, objetivos alcanzables, límites y cuaterniones.
Retargeting usa ejes locales del VRM.

### Tracking

Identidad basada en pose, trayectoria, orientación y evidencia de handedness.
Gracia de oclusión y recuperación suave.

### IA

DTW offline es baseline. SVM/kNN opcional. Features semánticas se introducen
sin alterar longitud del vector y se comparan contra golden/dataset.

## Errores y recuperación

- frame no válido: descartar para datos, mantener estado visual si corresponde;
- outlier: marcar, reparar/predicción y bajar confianza;
- mano perdida breve: conservar/predicción;
- pérdida prolongada: reposo suave;
- mano reaparece: mezcla progresiva;
- conflicto de lado: conservar track hasta evidencia estable;
- contrato incompatible: rechazar, no convertir silenciosamente.

## Pruebas

- Dart: contrato, normalización, cámara y persistencia.
- Python: golden, invariancia, empaquetado y DTW.
- JavaScript: lados, pulgar, pérdida, geometría, suavizado e IK.
- Cámara real: protocolo de `docs/09-pruebas-camara.md`.

## Riesgos

- La Z monocular puede parecer 3D pero no ser consistente.
- El low-pass actual puede ocultar jitter a costa de latencia.
- MediaPipe puede perder manos en cruce, giro o baja luz.
- Proporciones VRM distintas pueden producir retargeting visual extraño.
- Datos sintéticos no representan manos reales.

## Criterios de aceptación

Se acepta una fase solo con tests automatizados verdes, contrato intacto y
evidencia de cámara cuando la fase afecta tracking visual.
