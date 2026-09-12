# ReconocerUnivoz — documentación de ingeniería

Índice de esta rama para planear y validar la evolución de captura de señas,
RigBody, avatar VRM y reconocimiento. Este `README.md` vive solo en la rama
de trabajo; no modifica el README de la rama principal.

## Estado actual

La base funcional ya contiene:

- Flutter + Android CameraX/MediaPipe.
- Visor WebView/standalone con avatar VRM.
- Pose de cuerpo y dos manos a aproximadamente 30 FPS.
- Render del avatar a 60 FPS usando solo el último frame vivo.
- Normalización `MotionFrameV2`: exactamente 32 frames × 152 valores.
- Validación de geometría, resolución de lado anatómico y asociación uno-a-uno.
- Marco de mano, calibración del pulgar, dedos por falange, IK de dos huesos,
  límites de codo y recuperación tras pérdida de mano.
- Suavizado visual con One Euro, rechazo MAD y rate limit; datos raw de captura
  permanecen separados.
- DTW offline; AI Engine opcional con SVM/kNN/centroide.

La suite automatizada está verde al documentar esta rama. La validación con
cámara física todavía requiere una sesión asistida.

## Navegación

### Decisiones y alcance

- [Objetivo, alcance y reglas de rama](00-objetivo-y-contexto.md)
- [Decisión de diseño](superpowers/specs/2026-09-11-rigbody-reconocimiento-design.md)

### Arquitectura y contratos

- [Pipeline y arquitectura por capas](01-arquitectura-pipeline.md)
- [Contratos de datos y MotionFrameV2](02-contratos-y-datos.md)
- [RigBody, IK y retargeting VRM](04-rig-ik-y-avatar.md)

### Estabilización y personalización

- [Validación, filtrado y pulgar](03-estabilizacion-y-pulgar.md)
- [Tracking, identidad y oclusiones](05-tracking-y-oclusiones.md)
- [Calibración, privacidad y hardware](06-calibracion-privacidad-y-hardware.md)

### Ejecución y validación

- [Roadmap por fases](07-roadmap.md)
- [Syllabus técnico](08-syllabus-tecnico.md)
- [Protocolo de cámara asistido](09-pruebas-camara.md)
- [Métricas y criterios de aceptación](10-metricas-y-criterios.md)
- [Evidencia de sesión web](evidence/2026-09-11-web-camera-session.md)
- [Plan ejecutable](superpowers/plans/2026-09-11-rigbody-roadmap.md)

## Verificación rápida

Desde raíz:

```bash
./scripts/univoz.sh test
```

Pruebas específicas:

```bash
cd senas_core
python3 tools/test_norm.py
python3 tools/test_dtw.py
cd tools/rig-tests && npm test
```

Prueba visual web:

```bash
./scripts/univoz.sh web
```

Después abrir `http://127.0.0.1:8080`, pulsar `Iniciar cámara` y seguir
[el protocolo asistido](09-pruebas-camara.md).

## Regla de compatibilidad

No cambiar `norm_version=2.0.0`, `kFrameDim=152` ni `kTFrames=32` sin una nueva
versión de contrato, golden tests, migración de muestras y modelo compatible.
Metadatos de confianza, tracking, rostro o profundidad quedan fuera del
vector canónico.

## Fuente de investigación

Este índice consolida los tres documentos adjuntos del objetivo. La
investigación extensa se convierte aquí en decisiones, límites comprobables y
tareas pequeñas; no se copian promesas de precisión que aún no tengan
medición.
