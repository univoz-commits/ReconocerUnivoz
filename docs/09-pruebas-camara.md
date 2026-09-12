# Protocolo de pruebas con cámara

## Preparación

1. Ejecutar `./scripts/univoz.sh test`.
2. Ejecutar `./scripts/univoz.sh web`.
3. Abrir `http://127.0.0.1:8080`.
4. Conceder permiso de cámara.
5. Usar luz frontal, torso y ambas manos visibles.
6. Confirmar que el panel muestra FPS, calidad y dimensiones `152`.

La asistencia del usuario es necesaria para observar avatar y cámara reales.
Los tests automáticos no pueden probar permisos, iluminación, orientación
física ni sensación visual.

## Secuencia base

| Prueba | Acción | Observar |
|---|---|---|
| estática | manos abiertas 5 s | jitter y calidad |
| pulgar | abierto → palma → índice | signo y monotonía |
| dorso | girar mano | normal de palma sin inversión |
| puño | cerrar lentamente | falanges sin saltos |
| pronación | girar antebrazo | twist razonable |
| cruce | cruzar manos | no intercambiar izquierda/derecha |
| oclusión corta | tapar 200 ms | continuidad |
| oclusión larga | tapar 500 ms | reposo suave |
| salida | sacar mano y volver | recuperación gradual |
| rápido | mover manos rápido | latencia y overshoot |
| grabación | pulsar `Grabar 32` | secuencia 32×152 |
| replay | pulsar `Repetir` | mismo avatar que captura |

## Prueba específica de pulgar

Repetir en izquierda y derecha:

1. palma hacia cámara;
2. pulgar extendido;
3. pulgar hacia palma;
4. pulgar tocando índice;
5. otros dedos flexionados con pulgar extendido;
6. giro de muñeca con pulgar visible;
7. dorso hacia cámara.

Resultado aceptable:

- sin inversión visible;
- sin salto al cruzar orientación;
- CMC, MCP e IP participan;
- pulgar vuelve a neutral;
- no cambia lado anatómico.

## Registro manual de evidencia

Anotar:

```text
dispositivo:
navegador o Android:
resolución:
luz:
fps inferencia:
fps render:
calidad:
latencia percibida:
frames perdidos:
swaps:
inversión de pulgar:
observación:
```

No guardar video por defecto. Si una regresión requiere evidencia, conservar
solo captura o landmarks mínimos y eliminar después.

## Criterio de parada

Parar y documentar, sin improvisar cambios, si:

- cámara no concede permiso;
- WASM no carga;
- avatar queda congelado;
- la salida no es 152D;
- aparecen swaps persistentes;
- una corrección visual rompe replay o golden.
