# ReconocerUnivoz — plan de ingeniería

Índice de trabajo de esta rama. La documentación completa, fases, contratos,
tecnologías, pruebas y criterios de aceptación está en [`docs/README.md`](docs/README.md).

## Navegación rápida

- [Objetivo y reglas de rama](docs/00-objetivo-y-contexto.md)
- [Arquitectura del pipeline](docs/01-arquitectura-pipeline.md)
- [Contratos y `MotionFrameV2`](docs/02-contratos-y-datos.md)
- [Estabilización y pulgar](docs/03-estabilizacion-y-pulgar.md)
- [Roadmap](docs/07-roadmap.md)
- [Pruebas con cámara](docs/09-pruebas-camara.md)
- [Métricas y aceptación](docs/10-metricas-y-criterios.md)

## Verificación

```bash
./scripts/univoz.sh test
```

## Probar sistema

Desde raíz del repositorio:

```bash
./scripts/univoz.sh doctor       # herramientas y dispositivos
./scripts/univoz.sh setup        # primera vez o tras cambiar dependencias
./scripts/univoz.sh web --no-open
```

Abrir `http://127.0.0.1:8080/assets/avatar_viewer/index.html?standalone=1` y
pulsar `Iniciar cámara`. La raíz `http://127.0.0.1:8080` solo muestra listado
de archivos. Para app Flutter:

```bash
./scripts/univoz.sh all -d <device-id>
```

`Ctrl+C` detiene procesos levantados por el runner. Usar
`./scripts/univoz.sh --help` para puertos, backend, release y opciones de
instalación.

No anteponer `>` al comando: Bash lo interpreta como redirección y puede
truncar el script. Correcto: `./scripts/univoz.sh web --no-open`. Para guardar
salida, poner redirección después del comando: `./scripts/univoz.sh web >web.log 2>&1`.

Este índice pertenece únicamente a la rama de trabajo `codex/rigbody-ai`.
No implica cambios ni merge en la rama principal.
