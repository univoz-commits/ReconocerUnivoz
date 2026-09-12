# Objetivo, alcance y reglas

## Objetivo

Hacer evolucionar ReconocerUnivoz hacia un sistema de captura de señas
estable, anatómicamente coherente y útil para un avatar VRM, manteniendo la
base multiplataforma actual y el contrato de reconocimiento existente.

El trabajo de esta rama debe dejar:

1. Documentación Markdown navegable y legible en GitHub.
2. Un roadmap por fases con dependencias y criterios de salida.
3. Registro honesto de lo ya implementado y lo que falta.
4. Cambios inmediatos pequeños, medibles y compatibles.
5. Protocolo para validar cámara con asistencia del usuario.

## Fuentes consolidadas

Los adjuntos cubren cuatro temas:

- estabilización de landmarks: confianza, longitudes óseas, MAD, One Euro y
  predicción durante oclusiones;
- reconstrucción anatómica: marco de palma, pulgar, cuaterniones, límites e IK;
- personalización: proporciones, calibración y adaptación del avatar;
- reconocimiento: features semánticas, `MotionFrameV2`, DTW y modelos futuros.

La idea “estilo Face ID” se interpreta como calibración cinemática local. No se
trata de identificar a una persona ni de guardar biometría facial.

## Alcance inmediato

- Documentar el sistema presente.
- Medir el baseline automatizado.
- Validar visualmente el visor web con cámara.
- Corregir regresiones concretas que aparezcan en esa sesión.
- Preparar Fase 1: telemetría, validación robusta y filtrado.

## Fuera de alcance inmediato

- MANO/SMPL u otro modelo paramétrico.
- LiDAR, RGB-D, ARCore Depth, ARKit o multicámara como dependencia.
- Cambiar dimensión u orden del vector 152D.
- Entrenar Transformer, TCN, LSTM o GNN sin dataset real suficiente.
- Crear identificación persistente del usuario.
- Fusionar esta documentación con la rama principal.

## Reglas de rama

- Rama de trabajo actual: `codex/rigbody-ai`.
- La documentación de este objetivo vive bajo `docs/`.
- No revertir, limpiar ni sobrescribir modificaciones previas del usuario.
- No modificar README de raíz salvo solicitud explícita.
- Separar commits por entregable cuando se incorporen cambios futuros.

## Criterio de éxito

El lector debe poder seguir desde `docs/README.md`:

```text
problema → arquitectura → contrato → fase → prueba → evidencia
```

La cámara no se considera validada por tests unitarios. Requiere evidencia
visual y métricas capturadas durante una sesión real.
