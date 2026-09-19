# Syllabus técnico

Orden de estudio ligado al código.

## 1. Vectores y marcos

- producto punto: proyección y ángulo;
- producto cruz: normales y ejes;
- normalización y degeneración;
- espacio cámara, mundo, cuerpo, palma y hueso.

Aplicación: `marcoMano`, normalización de cuerpo y ejes VRM.

## 2. Rotaciones

- axis-angle;
- cuaterniones;
- SLERP/NLERP;
- continuidad de signo;
- swing-twist.

Aplicación: muñeca, brazos y prevención de torsión.

## 3. Señales

- mediana y MAD;
- One Euro;
- Kalman constante-velocidad;
- rate limiting;
- latencia frente a suavizado.

Aplicación: comparar low-pass actual contra filtros adaptativos con métricas.

## 4. Biomecánica

- planos sagital, frontal y transversal;
- ley de cosenos;
- two-bone IK;
- límites y rangos dependientes del usuario.

Aplicación: brazo y pulgar.

## 5. Tracking

- asociación de detecciones;
- costo y matching uno-a-uno;
- Hungarian/Munkres;
- FSM de `TENTATIVE`, `TRACKING`, `OCCLUDED`, `LOST`.

Aplicación: cruces, oclusiones y reaparición.

## 6. IA de secuencias

- DTW y banda Sakoe–Chiba;
- features con pesos por bloque;
- SVM/kNN;
- precisión, recall, F1 y rechazo;
- modelos temporales solo tras tener dataset.

## 7. Ingeniería de evidencia

- fixtures sintéticos con ground truth;
- pruebas de contrato;
- golden tests entre Dart y Python;
- métricas p50/p95/p99;
- registro sin video.
