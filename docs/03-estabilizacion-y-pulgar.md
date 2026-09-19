# Estabilización, marco de mano y pulgar

## Problemas y causas

| Síntoma | Causa probable |
|---|---|
| jitter | ruido de landmarks y filtro insuficiente |
| salto | outlier o reaparición sin rate limit |
| pulgar invertido | signo de palma, lado o eje VRM inconsistente |
| puntos mezclados | identidad de mano inestable |
| torsión | Euler/ejes globales o falta de límites |

## Estado implementado

El visor actual ya:

- valida valores finitos y conexiones geométricas;
- conserva presencia como estado discreto;
- conserva mano durante huecos breves;
- aplica One Euro adaptativo y rate limit para render;
- detecta y registra MAD; reparación solo ocurre en la salida visual validada,
  nunca en raw, grabación ni IA;
- construye marco de mano canónico `PalmFrameV2` con puntos de palma y CMC;
- calibra neutral del pulgar;
- calcula falanges por segmentos;
- usa nomenclatura de pulgar VRM distinta de dedos largos;
- aplica límites de flexión;
- mantiene continuidad mediante cuaterniones para brazo y muñeca.

El filtro actual recibe calidad global del frame; todavía no usa confianza
individual por landmark. Usa una ventana MAD de hasta cinco muestras, umbral
`z > 3.5` y sigma mínimo para no marcar cada movimiento pequeño como outlier.
Raw, grabación y vector IA no pasan por esta capa visual. La adaptación por
landmark queda pendiente de medición y no se activa por defecto.

## Validación robusta implementada

### Gating

Rechazar un punto si confianza está debajo del umbral configurado, es no
finito, sale de rango o rompe una longitud ósea calibrada.

### MAD: detección y reparación visual

Para ventana `N=5` o `7`:

```text
m = median(x)
MAD = median(|x - m|)
sigma_robust = 1.4826 × MAD
z = |x_actual - m| / (sigma_robust + ε)
```

Marcar outlier cuando `z > 3.5`. MAD por sí solo no prueba que el movimiento sea
falso. Reparar solo cuando también existe salto temporal o inconsistencia
geométrica; usar predicción/mediana en `ValidatedFrame` y conservar raw intacto.
La salida semántica de captura no se modifica silenciosamente.

### One Euro

Aplicar a posición o ángulo, con `dt` validado:

```text
dx = (x_t - x_raw_prev) / dt
dx_hat = lowpass(dx)
cutoff = min_cutoff + beta × |dx_hat|
alpha = 1 / (1 + 1/(2π × cutoff × dt))
x_hat = alpha × x_t + (1-alpha) × x_hat_prev
```

Parámetros iniciales a calibrar con cámara:

| Señal | `min_cutoff` | `beta` |
|---|---:|---:|
| cuerpo | 0.8–1.2 Hz | 0.004–0.008 |
| muñeca | 1.0–1.5 Hz | 0.006–0.012 |
| dedos | 1.2–2.0 Hz | 0.008–0.015 |
| pulgar | 0.8–1.2 Hz | 0.003–0.007 |

No aplicar One Euro directamente a cuaterniones; usar continuidad de signo y
SLERP/NLERP.

## Marco de palma `PalmFrameV2`

Con `W=0`, `I=5`, `M=9`, `P=17`, `C=1`:

```text
f = normalize(M-W)
n = normalize(cross(I-W, P-W))
r = normalize(cross(n, f))
```

Corregir signo de `r` usando dirección `C-W` y lado anatómico. Exigir
`dot(C-W, r) > 0` después de corrección. Usar este mismo marco para asociación,
orientación de muñeca y cálculo del pulgar; no mantener un marco distinto para
render. Luego:

```text
x_palm = f
y_palm = normalize(cross(n, f))
z_palm = n
```

Rechazar marco degenerado y conservar marco anterior. Si lado o normal no son
verificables, conservar último quaternion y emitir `hand_surface_ambiguous`.
Suavizar marco antes de derivar ángulos. No existe garantía física absoluta con
RGB monocular; criterio de seguridad es cero inversiones no verificadas
aplicadas al avatar.

## Pulgar

Cadena MediaPipe: `CMC=1`, `MCP=2`, `IP=3`, punta `4`.

1. Proyectar segmento CMC/MCP al plano de palma.
2. Medir ángulo firmado respecto a referencia neutral.
3. Multiplicar por signo calibrado del lado.
4. Limitar rango anatómico.
5. Aplicar rate limit, histéresis y filtro angular.
6. Retargetear alrededor del eje local del hueso VRM.

No corregir el pulgar invirtiendo landmarks crudos. Corregir signo en el marco
anatómico o en el mapeo local del rig.

## Regla de diagnóstico

Si el azul de la normal de palma cambia de sentido sin que cambie la mano,
revisar degeneración, signo y asociación antes de tocar el modelo de IA.
