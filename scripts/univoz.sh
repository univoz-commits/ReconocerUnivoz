#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION='1.0.0'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SENAS_DIR="$ROOT_DIR/senas_core"
AI_DIR="$ROOT_DIR/backend/ai-engine"
AI_VENV="$AI_DIR/.venv"
AI_PYTHON="$AI_VENV/bin/python"
RIG_TEST_DIR="$SENAS_DIR/tools/rig-tests"
HTML_VIEWER="$SENAS_DIR/assets/avatar_viewer/index.html"

PYTHON_BIN="${PYTHON_BIN:-}"
FLUTTER_BIN="${FLUTTER_BIN:-}"
BACKEND_URL="${UNIVOZ_BACKEND_URL:-}"
BACKEND_HOST="${UNIVOZ_BACKEND_HOST:-}"
BACKEND_PORT="${UNIVOZ_BACKEND_PORT:-8000}"
DEVICE="${UNIVOZ_DEVICE:-}"
INSTALL=false
RELEASE=false
WITH_BACKEND=true
WEB_HOST="${UNIVOZ_WEB_HOST:-127.0.0.1}"
WEB_PORT="${UNIVOZ_WEB_PORT:-8080}"
OPEN_BROWSER=true
BACKEND_HEALTH_URL=''
BACKEND_PID=''
WEB_PID=''
declare -a PIDS=()
declare -a EXTRA_ARGS=()

if [[ -t 2 ]]; then
    C_INFO=$'\033[1;36m'
    C_WARN=$'\033[1;33m'
    C_ERROR=$'\033[1;31m'
    C_RESET=$'\033[0m'
else
    C_INFO=''
    C_WARN=''
    C_ERROR=''
    C_RESET=''
fi

log_info() {
    printf '%s[INFO]%s %s\n' "$C_INFO" "$C_RESET" "$*" >&2
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2
}

log_error() {
    printf '%s[ERROR]%s %s\n' "$C_ERROR" "$C_RESET" "$*" >&2
}

die() {
    log_error "$*"
    exit 1
}

on_error() {
    local status=$?
    log_error "fallo en línea $1 (código $status)"
    exit "$status"
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM

    if [[ -n "$BACKEND_PID" ]] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        log_info 'Deteniendo AI Engine...'
        kill -TERM "$BACKEND_PID" 2>/dev/null || true
    fi

    for pid in "${PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    exit "$status"
}

trap 'on_error "$LINENO"' ERR
trap cleanup EXIT
trap 'exit 130' INT TERM

usage() {
    local status="${1:-0}"
    cat <<'EOF'
ReconocerUnivoz runner

USO
  ./scripts/univoz.sh [comando] [opciones] [-- argumentos flutter]

COMANDOS
  all, run       Levanta AI Engine y Flutter. Comando por defecto.
  setup          Instala dependencias Python y Flutter.
  test           Ejecuta tests Dart, Python, backend y sintaxis JS.
  doctor         Revisa herramientas, dependencias y dispositivos.
  backend        Levanta solo AI Engine en puerto 8000.
  frontend       Levanta solo Flutter.
  web            Sirve visor VRM/RigBody standalone en navegador.
  completion     Imprime autocompletado Bash.

OPCIONES
  -d, --device ID          Dispositivo Flutter destino.
      --backend-url URL    URL enviada a Flutter y usada para healthcheck.
      --backend-host HOST  Host donde escucha AI Engine (default: 127.0.0.1).
      --backend-port PORT  Puerto de AI Engine (default: 8000).
      --web-host HOST      Host del visor web (default: 127.0.0.1).
      --web-port PORT      Puerto del visor web (default: 8080).
      --install            Instala/actualiza dependencias antes de ejecutar.
      --release            Ejecuta Flutter en modo release.
      --no-backend         Usa solo DTW local; no levanta AI Engine.
      --no-open            No abre navegador automáticamente para comando web.
  -h, --help               Muestra esta ayuda.
      --version            Muestra versión del runner.

EJEMPLOS
  ./scripts/univoz.sh setup
  ./scripts/univoz.sh all -d emulator-5554
  ./scripts/univoz.sh all --install -d emulator-5554
  ./scripts/univoz.sh frontend --no-backend
  ./scripts/univoz.sh backend --backend-host 0.0.0.0
  ./scripts/univoz.sh web
  source <(./scripts/univoz.sh completion bash)

NOTAS
  En emulador Android, el runner usa http://10.0.2.2:8000 automáticamente.
  Para teléfono físico: UNIVOZ_BACKEND_HOST=0.0.0.0 y --backend-url con IP LAN.
EOF
    exit "$status"
}

completion_bash() {
    cat <<'EOF'
_univoz_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local commands="all run setup test doctor backend frontend web completion"
    local options="--device --backend-url --backend-host --backend-port --web-host --web-port --install --release --no-backend --no-open --help --version"
    if (( COMP_CWORD == 1 )); then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    else
        COMPREPLY=( $(compgen -W "$options" -- "$cur") )
    fi
}
complete -F _univoz_complete univoz univoz.sh
EOF
}

require_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || die "No existe directorio requerido: $dir"
}

resolve_python() {
    if [[ -n "$PYTHON_BIN" ]]; then
        [[ -x "$PYTHON_BIN" ]] || die "PYTHON_BIN no ejecutable: $PYTHON_BIN"
        return
    fi
    if command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN="$(command -v python3)"
    elif command -v python >/dev/null 2>&1; then
        PYTHON_BIN="$(command -v python)"
    else
        die 'No encontré Python. Instala python3 o define PYTHON_BIN.'
    fi
}

resolve_flutter() {
    if [[ -n "$FLUTTER_BIN" ]]; then
        [[ -x "$FLUTTER_BIN" ]] || die "FLUTTER_BIN no ejecutable: $FLUTTER_BIN"
        return
    fi
    if command -v flutter >/dev/null 2>&1; then
        FLUTTER_BIN="$(command -v flutter)"
        return
    fi
    local sibling_flutter="$ROOT_DIR/../flutter/bin/flutter"
    if [[ -x "$sibling_flutter" ]]; then
        FLUTTER_BIN="$sibling_flutter"
        return
    fi
    die 'No encontré Flutter. Añádelo al PATH o define FLUTTER_BIN.'
}

require_backend_dirs() {
    require_dir "$AI_DIR"
    require_dir "$AI_DIR/ai_engine"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || die "Puerto inválido: $port"
    (( port >= 1 && port <= 65535 )) || die "Puerto fuera de rango: $port"
}

ensure_flutter_deps() {
    resolve_flutter
    require_dir "$SENAS_DIR"
    if [[ ! -f "$SENAS_DIR/.dart_tool/package_config.json" ]]; then
        log_info 'Instalando dependencias Flutter...'
        (cd "$SENAS_DIR" && "$FLUTTER_BIN" pub get)
    fi
}

setup_frontend() {
    resolve_flutter
    require_dir "$SENAS_DIR"
    log_info 'Preparando Flutter...'
    (cd "$SENAS_DIR" && "$FLUTTER_BIN" pub get)
}

setup_backend() {
    resolve_python
    require_backend_dirs
    if [[ ! -x "$AI_PYTHON" ]]; then
        log_info 'Creando entorno virtual Python...'
        "$PYTHON_BIN" -m venv "$AI_VENV"
    fi
    log_info 'Instalando dependencias AI Engine...'
    "$AI_PYTHON" -m pip install -r "$AI_DIR/requirements.txt"
}

setup_rig_tests() {
    require_dir "$RIG_TEST_DIR"
    command -v npm >/dev/null 2>&1 || die 'No encontré npm para instalar pruebas RigBody.'
    log_info 'Preparando pruebas matemáticas RigBody...'
    (cd "$RIG_TEST_DIR" && npm install --ignore-scripts --no-audit --no-fund)
}

setup_all() {
    setup_backend
    setup_frontend
    setup_rig_tests
}

ensure_backend_runtime() {
    resolve_python
    require_backend_dirs
    [[ -x "$AI_PYTHON" ]] || die "Falta entorno backend: ejecuta '$SCRIPT_DIR/univoz.sh setup'."
    if ! "$AI_PYTHON" -c 'import fastapi, uvicorn' >/dev/null 2>&1; then
        die "Faltan dependencias backend: ejecuta '$SCRIPT_DIR/univoz.sh setup'."
    fi
}

resolve_runtime_config() {
    validate_port "$BACKEND_PORT"

    if [[ -z "$BACKEND_URL" ]]; then
        if [[ "$DEVICE" == emulator-* ]]; then
            BACKEND_URL="http://10.0.2.2:$BACKEND_PORT"
        else
            BACKEND_URL="http://127.0.0.1:$BACKEND_PORT"
        fi
    fi
    BACKEND_URL="${BACKEND_URL%/}"

    if [[ -z "$BACKEND_HOST" ]]; then
        if [[ "$BACKEND_URL" == *'10.0.2.2'* ]]; then
            BACKEND_HOST='0.0.0.0'
        else
            BACKEND_HOST='127.0.0.1'
        fi
    fi
    if [[ -z "$BACKEND_HEALTH_URL" ]]; then
        BACKEND_HEALTH_URL="http://127.0.0.1:$BACKEND_PORT"
    fi
}

http_ok() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl --silent --show-error --fail --max-time 1 "$url/health" >/dev/null
        return
    fi
    "$AI_PYTHON" - "$url/health" <<'PY'
import sys
import urllib.request

with urllib.request.urlopen(sys.argv[1], timeout=1) as response:
    raise SystemExit(0 if response.status == 200 else 1)
PY
}

wait_for_health() {
    local url="$1"
    local attempt
    for ((attempt = 1; attempt <= 40; attempt++)); do
        if [[ -n "$BACKEND_PID" ]] && ! kill -0 "$BACKEND_PID" 2>/dev/null; then
            die 'AI Engine terminó antes de responder /health.'
        fi
        if http_ok "$url"; then
            log_info "AI Engine listo: $url"
            return
        fi
        sleep 0.25
    done
    die "AI Engine no respondió /health: $url"
}

start_backend() {
    ensure_backend_runtime
    resolve_runtime_config
    log_info "Iniciando AI Engine en $BACKEND_HOST:$BACKEND_PORT..."
    (
        cd "$AI_DIR"
        exec env PYTHONPATH="$AI_DIR" "$AI_PYTHON" -m uvicorn \
            ai_engine.server:app \
            --host "$BACKEND_HOST" \
            --port "$BACKEND_PORT"
    ) &
    BACKEND_PID="$!"
    PIDS+=("$BACKEND_PID")
    wait_for_health "$BACKEND_HEALTH_URL"
}

run_frontend() {
    ensure_flutter_deps
    local -a args=(run)
    if [[ -n "$DEVICE" ]]; then
        args+=(-d "$DEVICE")
    fi
    if [[ "$RELEASE" == true ]]; then
        args+=(--release)
    fi
    if [[ "$WITH_BACKEND" == true ]]; then
        resolve_runtime_config
        args+=("--dart-define=UNIVOZ_BACKEND_URL=$BACKEND_URL")
    fi
    args+=("${EXTRA_ARGS[@]}")

    log_info 'Iniciando Flutter; Ctrl+C detiene frontend y AI Engine.'
    (cd "$SENAS_DIR" && "$FLUTTER_BIN" "${args[@]}")
}

run_web() {
    resolve_python
    require_dir "$SENAS_DIR"
    require_dir "$SENAS_DIR/assets/avatar_viewer"
    require_dir "$SENAS_DIR/assets/avatar"
    validate_port "$WEB_PORT"

    local web_url="http://127.0.0.1:$WEB_PORT/assets/avatar_viewer/index.html?standalone=1"
    log_info "Visor web: $web_url"
    log_info 'Modo web: avatar/RigBody + cámara MediaPipe; pulsa Iniciar cámara en el visor.'

    if [[ "$OPEN_BROWSER" == true ]] && command -v xdg-open >/dev/null 2>&1; then
        (
            sleep 0.5
            xdg-open "$web_url" >/dev/null 2>&1 || true
        ) &
        PIDS+=("$!")
    fi

    log_info 'Servidor web activo; Ctrl+C detiene visor.'
    (
        cd "$SENAS_DIR"
        exec "$PYTHON_BIN" -m http.server "$WEB_PORT" --bind "$WEB_HOST"
    ) &
    WEB_PID="$!"
    PIDS+=("$WEB_PID")
    wait "$WEB_PID"
}

run_tests() {
    resolve_python
    resolve_flutter
    require_dir "$SENAS_DIR"
    require_backend_dirs
    [[ -e "$ROOT_DIR/.git" ]] || die "No parece un checkout Git: $ROOT_DIR"
    command -v node >/dev/null 2>&1 || die 'No encontré Node.js para validar avatar_viewer.'

    log_info 'Flutter tests...'
    (cd "$SENAS_DIR" && "$FLUTTER_BIN" test)
    log_info 'Flutter analyze...'
    (cd "$SENAS_DIR" && "$FLUTTER_BIN" analyze)
    log_info 'Python tests y golden...'
    "$PYTHON_BIN" -m pytest -q "$SENAS_DIR"
    "$PYTHON_BIN" "$SENAS_DIR/tools/test_norm.py"
    "$PYTHON_BIN" "$SENAS_DIR/tools/test_dtw.py"
    log_info 'AI Engine tests...'
    PYTHONPATH="$AI_DIR" "$PYTHON_BIN" -m pytest -q "$AI_DIR/tests"
    PYTHONPATH="$AI_DIR" "$PYTHON_BIN" -m compileall -q "$AI_DIR/ai_engine"
    log_info 'Sintaxis JavaScript y diff...'
    awk '
        /<script[^>]*type="module"/ {inside=1; next}
        inside && /<\/script>/ {exit}
        inside {print}
    ' "$HTML_VIEWER" | node --check --input-type=module
    if [[ -f "$RIG_TEST_DIR/package.json" ]]; then
        [[ -d "$RIG_TEST_DIR/node_modules/three" ]] || die "Faltan pruebas RigBody: ejecuta '$SCRIPT_DIR/univoz.sh setup'."
        log_info 'Pruebas geométricas RigBody...'
        (cd "$RIG_TEST_DIR" && npm test)
    fi
    (cd "$ROOT_DIR" && git diff --check)
    log_info 'Todas las verificaciones pasaron.'
}

run_doctor() {
    resolve_python
    resolve_flutter
    require_dir "$SENAS_DIR"
    require_backend_dirs

    log_info "Python: $PYTHON_BIN"
    "$PYTHON_BIN" --version
    log_info "Flutter: $FLUTTER_BIN"
    "$FLUTTER_BIN" --version
    if [[ -x "$AI_PYTHON" ]] && "$AI_PYTHON" -c 'import fastapi, uvicorn' >/dev/null 2>&1; then
        log_info 'Backend Python: listo'
    else
        log_warn "Backend Python: falta setup ('$SCRIPT_DIR/univoz.sh setup')"
    fi
    if command -v adb >/dev/null 2>&1; then
        log_info 'ADB:'
        adb devices
    else
        log_warn 'ADB no encontrado; Flutter aún puede usar otros targets.'
    fi
    log_info 'Targets Flutter:'
    "$FLUTTER_BIN" devices
}

COMMAND='all'
if [[ $# -gt 0 && "$1" != -* ]]; then
    COMMAND="$1"
    shift
fi

if [[ "$COMMAND" == completion ]]; then
    [[ "${1:-bash}" == bash ]] || die 'Solo autocompletado Bash está disponible.'
    completion_bash
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device)
            [[ $# -ge 2 ]] || die "Falta valor para $1"
            DEVICE="$2"
            shift 2
            ;;
        --backend-url)
            [[ $# -ge 2 ]] || die 'Falta valor para --backend-url'
            BACKEND_URL="$2"
            shift 2
            ;;
        --backend-host)
            [[ $# -ge 2 ]] || die 'Falta valor para --backend-host'
            BACKEND_HOST="$2"
            shift 2
            ;;
        --backend-port)
            [[ $# -ge 2 ]] || die 'Falta valor para --backend-port'
            BACKEND_PORT="$2"
            shift 2
            ;;
        --web-host)
            [[ $# -ge 2 ]] || die 'Falta valor para --web-host'
            WEB_HOST="$2"
            shift 2
            ;;
        --web-port)
            [[ $# -ge 2 ]] || die 'Falta valor para --web-port'
            WEB_PORT="$2"
            shift 2
            ;;
        --install)
            INSTALL=true
            shift
            ;;
        --release)
            RELEASE=true
            shift
            ;;
        --no-backend)
            WITH_BACKEND=false
            shift
            ;;
        --no-open)
            OPEN_BROWSER=false
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        --version)
            printf 'univoz-runner %s\n' "$SCRIPT_VERSION"
            exit 0
            ;;
        --)
            shift
            EXTRA_ARGS=("$@")
            break
            ;;
        *)
            die "Opción o argumento desconocido: $1. Usa --help."
            ;;
    esac
done

case "$COMMAND" in
    setup)
        setup_all
        ;;
    test)
        if [[ "$INSTALL" == true ]]; then setup_all; fi
        run_tests
        ;;
    doctor)
        run_doctor
        ;;
    backend)
        [[ "$WITH_BACKEND" == true ]] || die 'backend no admite --no-backend.'
        if [[ "$INSTALL" == true ]]; then setup_backend; fi
        start_backend
        wait "$BACKEND_PID"
        ;;
    frontend)
        if [[ "$INSTALL" == true ]]; then setup_frontend; fi
        run_frontend
        ;;
    web)
        run_web
        ;;
    all|run)
        if [[ "$INSTALL" == true ]]; then
            setup_all
        fi
        if [[ "$WITH_BACKEND" == true ]]; then
            start_backend
        fi
        run_frontend
        ;;
    *)
        die "Comando desconocido: $COMMAND. Usa --help."
        ;;
esac
