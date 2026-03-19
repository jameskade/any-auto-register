#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$SCRIPT_DIR}"
APP_NAME="any-auto-register"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
RUNTIME_DIR="$STATE_HOME/$APP_NAME"
LOG_FILE="$RUNTIME_DIR/backend.log"
PID_FILE="$RUNTIME_DIR/backend.pid"
FRONTEND_LOG_FILE="$RUNTIME_DIR/frontend.log"
FRONTEND_PID_FILE="$RUNTIME_DIR/frontend.pid"
PORT="${PORT:-8000}"
HOST="${HOST:-0.0.0.0}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"
FRONTEND_HOST="${FRONTEND_HOST:-0.0.0.0}"
CONDA_ENV_NAME="${CONDA_ENV_NAME:-3.11}"
NO_TAIL="0"
QUIET="0"
ACTION="start"
USE_COLOR="0"
COLOR_RESET=""
COLOR_RED=""
COLOR_GREEN=""
COLOR_YELLOW=""
STARTED_BACKEND_THIS_RUN="0"
STARTED_FRONTEND_THIS_RUN="0"

usage() {
  cat <<EOF2
Usage: $(basename "$0") [start|stop|restart|status|logs] [--no-tail] [--quiet] [--help]

Options:
  --no-tail   Start in background and return immediately after readiness check
  --quiet     Reduce output
  --help      Show this help message

Environment overrides:
  CONDA_ENV_NAME   Conda environment name (default: 3.11)
  REPO_ROOT        Git repo path (default: \$SCRIPT_DIR)
  HOST             Backend host (default: 0.0.0.0)
  PORT             Backend port (default: 8000)
  FRONTEND_HOST    Frontend host (default: 0.0.0.0)
  FRONTEND_PORT    Frontend port (default: 5173)
EOF2
}

log() {
  if [[ "$QUIET" != "1" ]]; then
    printf '%s\n' "$*"
  fi
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  command_exists "$1" || fail "Missing required command: $1"
}

init_colors() {
  if [[ -n "${NO_COLOR:-}" ]]; then
    return
  fi
  if [[ "${CLICOLOR_FORCE:-0}" == "1" || -t 1 ]]; then
    USE_COLOR="1"
    COLOR_RESET=$'\033[0m'
    COLOR_RED=$'\033[31m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
  fi
}

colorize() {
  local color="$1"
  shift
  if [[ "$USE_COLOR" != "1" ]]; then
    printf '%s' "$*"
    return
  fi

  case "$color" in
    red) printf '%s%s%s' "$COLOR_RED" "$*" "$COLOR_RESET" ;;
    green) printf '%s%s%s' "$COLOR_GREEN" "$*" "$COLOR_RESET" ;;
    yellow) printf '%s%s%s' "$COLOR_YELLOW" "$*" "$COLOR_RESET" ;;
    *) printf '%s' "$*" ;;
  esac
}

color_status() {
  case "$1" in
    已运行) colorize green "$1" ;;
    启动中) colorize yellow "$1" ;;
    *) colorize red "$1" ;;
  esac
}

ensure_runtime_dir() {
  mkdir -p "$RUNTIME_DIR"
}

read_pid() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1
  tr -d '[:space:]' <"$pid_file"
}

is_pid_running() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1
}

cleanup_pid_file() {
  local pid_file="$1"
  local pid
  pid="$(read_pid "$pid_file" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && ! is_pid_running "$pid"; then
    rm -f "$pid_file"
  fi
}

listener_pids() {
  local port="$1"
  lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
}

listener_pid() {
  local port="$1"
  listener_pids "$port" | head -n 1
}

backend_process_pid() {
  pgrep -f "uvicorn main:app .*--port $PORT" | head -n 1 || true
}

frontend_process_pid() {
  pgrep -f "vite.*--port $FRONTEND_PORT" | head -n 1 || true
}

resolve_service_pid() {
  local pid_file="$1"
  local port="$2"
  local process_fn="${3:-}"
  local pid
  local port_pid
  local process_pid

  cleanup_pid_file "$pid_file"
  pid="$(read_pid "$pid_file" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && is_pid_running "$pid"; then
    printf '%s\n' "$pid"
    return 0
  fi

  port_pid="$(listener_pid "$port" || true)"
  if [[ -n "$port_pid" ]] && is_pid_running "$port_pid"; then
    printf '%s\n' "$port_pid"
    return 0
  fi

  if [[ -n "$process_fn" ]]; then
    process_pid="$("$process_fn" 2>/dev/null || true)"
    if [[ -n "$process_pid" ]] && is_pid_running "$process_pid"; then
      printf '%s\n' "$process_pid"
      return 0
    fi
  fi

  return 1
}

ensure_port_available() {
  local port="$1"
  local owned_pid_file="$2"
  local owned_pid
  local port_pid

  owned_pid="$(read_pid "$owned_pid_file" 2>/dev/null || true)"
  port_pid="$(listener_pid "$port" || true)"

  if [[ -z "$port_pid" ]]; then
    return 0
  fi

  if [[ -n "$owned_pid" && "$owned_pid" == "$port_pid" ]]; then
    return 0
  fi

  fail "Port $port is already in use by PID $port_pid"
}

wait_for_port() {
  local port="$1"
  local pid="$2"
  local label="$3"
  local timeout="${4:-30}"
  local i

  for ((i = 0; i < timeout; i++)); do
    if ! is_pid_running "$pid"; then
      return 1
    fi
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  log "$label did not open port $port within ${timeout}s"
  return 1
}

wait_for_http() {
  local url="$1"
  local timeout="${2:-30}"
  local i

  if ! command_exists curl; then
    return 0
  fi

  for ((i = 0; i < timeout; i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

conda_init() {
  require_command conda
  local conda_base
  conda_base="$(conda info --base 2>/dev/null || true)"
  [[ -n "$conda_base" ]] || fail "Unable to locate conda base"
  # shellcheck disable=SC1090
  source "$conda_base/etc/profile.d/conda.sh"
}

ensure_conda_env() {
  conda_init
  conda activate "$CONDA_ENV_NAME" >/dev/null 2>&1 || fail "Conda env '$CONDA_ENV_NAME' not found"
  conda deactivate >/dev/null 2>&1 || true
}

backend_pid() {
  resolve_service_pid "$PID_FILE" "$PORT" backend_process_pid 2>/dev/null || true
}

frontend_pid() {
  resolve_service_pid "$FRONTEND_PID_FILE" "$FRONTEND_PORT" frontend_process_pid 2>/dev/null || true
}

backend_running() {
  [[ -n "$(backend_pid)" ]]
}

frontend_running() {
  [[ -n "$(frontend_pid)" ]]
}

backend_health_ok() {
  command_exists curl && curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1
}

frontend_health_ok() {
  command_exists curl && curl -fsS "http://127.0.0.1:${FRONTEND_PORT}" >/dev/null 2>&1
}

safe_stop_service() {
  local label="$1"
  local pid_file="$2"
  local port="$3"
  local process_fn="$4"
  local primary_pid
  local force_pid
  local listeners
  local pid

  primary_pid="$(resolve_service_pid "$pid_file" "$port" "$process_fn" 2>/dev/null || true)"
  if [[ -n "$primary_pid" ]]; then
    kill "$primary_pid" >/dev/null 2>&1 || true
  fi

  for _ in {1..10}; do
    if [[ -z "$(resolve_service_pid "$pid_file" "$port" "$process_fn" 2>/dev/null || true)" ]]; then
      rm -f "$pid_file"
      return 0
    fi
    sleep 1
  done

  listeners="$(listener_pids "$port" | tr '\n' ' ')"
  for pid in $listeners; do
    kill "$pid" >/dev/null 2>&1 || true
  done

  for _ in {1..5}; do
    if [[ -z "$(resolve_service_pid "$pid_file" "$port" "$process_fn" 2>/dev/null || true)" ]]; then
      rm -f "$pid_file"
      return 0
    fi
    sleep 1
  done

  force_pid="$(resolve_service_pid "$pid_file" "$port" "$process_fn" 2>/dev/null || true)"
  if [[ -n "$force_pid" ]]; then
    kill -9 "$force_pid" >/dev/null 2>&1 || true
  fi
  listeners="$(listener_pids "$port" | tr '\n' ' ')"
  for pid in $listeners; do
    kill -9 "$pid" >/dev/null 2>&1 || true
  done

  rm -f "$pid_file"
  log "$label required force stop"
  return 0
}

cleanup_started_services() {
  if [[ "$STARTED_FRONTEND_THIS_RUN" == "1" ]]; then
    safe_stop_service "Frontend" "$FRONTEND_PID_FILE" "$FRONTEND_PORT" frontend_process_pid
  fi
  if [[ "$STARTED_BACKEND_THIS_RUN" == "1" ]]; then
    safe_stop_service "Backend" "$PID_FILE" "$PORT" backend_process_pid
  fi
}

start_backend() {
  local started_pid

  if backend_running; then
    log "Backend already running (PID $(backend_pid))"
    return 0
  fi

  ensure_port_available "$PORT" "$PID_FILE"
  : >"$LOG_FILE"
  cd "$REPO_ROOT"
  conda_init
  conda activate "$CONDA_ENV_NAME"
  if command_exists setsid; then
    setsid python -m uvicorn main:app --host "$HOST" --port "$PORT" >>"$LOG_FILE" 2>&1 < /dev/null &
  else
    nohup python -m uvicorn main:app --host "$HOST" --port "$PORT" >>"$LOG_FILE" 2>&1 < /dev/null &
  fi
  started_pid="$!"
  conda deactivate >/dev/null 2>&1 || true
  echo "$started_pid" >"$PID_FILE"

  if wait_for_port "$PORT" "$(read_pid "$PID_FILE")" "Backend" && wait_for_http "http://127.0.0.1:${PORT}/api/health" 30; then
    STARTED_BACKEND_THIS_RUN="1"
    log "Backend started on http://127.0.0.1:$PORT"
    return 0
  fi

  log "Backend failed to start. Recent log output:"
  tail -n 40 "$LOG_FILE" || true
  safe_stop_service "Backend" "$PID_FILE" "$PORT" backend_process_pid
  return 1
}

start_frontend() {
  local started_pid

  if frontend_running; then
    log "Frontend already running (PID $(frontend_pid))"
    return 0
  fi

  ensure_port_available "$FRONTEND_PORT" "$FRONTEND_PID_FILE"
  : >"$FRONTEND_LOG_FILE"
  cd "$REPO_ROOT/frontend"
  conda_init
  conda activate "$CONDA_ENV_NAME"
  if command_exists setsid; then
    setsid npm run dev -- --host "$FRONTEND_HOST" --port "$FRONTEND_PORT" >>"$FRONTEND_LOG_FILE" 2>&1 < /dev/null &
  else
    nohup npm run dev -- --host "$FRONTEND_HOST" --port "$FRONTEND_PORT" >>"$FRONTEND_LOG_FILE" 2>&1 < /dev/null &
  fi
  started_pid="$!"
  conda deactivate >/dev/null 2>&1 || true
  echo "$started_pid" >"$FRONTEND_PID_FILE"

  if wait_for_port "$FRONTEND_PORT" "$(read_pid "$FRONTEND_PID_FILE")" "Frontend" && wait_for_http "http://127.0.0.1:${FRONTEND_PORT}" 30; then
    STARTED_FRONTEND_THIS_RUN="1"
    log "Frontend started on http://127.0.0.1:$FRONTEND_PORT"
    return 0
  fi

  log "Frontend failed to start. Recent log output:"
  tail -n 40 "$FRONTEND_LOG_FILE" || true
  safe_stop_service "Frontend" "$FRONTEND_PID_FILE" "$FRONTEND_PORT" frontend_process_pid
  return 1
}

stop_one() {
  local label="$1"
  local pid_file="$2"
  local port="$3"
  local process_fn="$4"
  local pid
  pid="$(resolve_service_pid "$pid_file" "$port" "$process_fn" 2>/dev/null || true)"

  if [[ -z "$pid" ]]; then
    rm -f "$pid_file"
    log "$label is not running"
    return 0
  fi

  safe_stop_service "$label" "$pid_file" "$port" "$process_fn"
  log "$label stopped"
}

service_status_text() {
  local pid_file="$1"
  local port="$2"
  local health_fn="$3"
  local process_fn="$4"
  local pid
  local listeners

  pid="$(resolve_service_pid "$pid_file" "$port" "$process_fn" 2>/dev/null || true)"
  listeners="$(listener_pids "$port" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

  if "$health_fn"; then
    printf '已运行\n'
  elif [[ -n "$pid" || -n "$listeners" ]]; then
    printf '启动中\n'
  else
    printf '未运行\n'
  fi
}

show_status() {
  ensure_runtime_dir
  init_colors

  local backend_pid_value frontend_pid_value backend_status frontend_status
  local backend_health frontend_health

  backend_pid_value="$(backend_pid)"
  frontend_pid_value="$(frontend_pid)"
  backend_status="$(service_status_text "$PID_FILE" "$PORT" backend_health_ok backend_process_pid)"
  frontend_status="$(service_status_text "$FRONTEND_PID_FILE" "$FRONTEND_PORT" frontend_health_ok frontend_process_pid)"

  if backend_health_ok; then
    backend_health="正常"
  else
    backend_health="异常"
  fi
  if frontend_health_ok; then
    frontend_health="正常"
  else
    frontend_health="异常"
  fi

  [[ -n "$backend_pid_value" ]] || backend_pid_value="-"
  [[ -n "$frontend_pid_value" ]] || frontend_pid_value="-"

  printf '=== AnyAutoRegister 状态 ===\n'
  printf '安装状态: %s (目录: %s)\n' "$(colorize green 已安装)" "$REPO_ROOT"
  printf '后端状态: %s\n' "$(color_status "$backend_status")"
  printf '前端状态: %s\n' "$(color_status "$frontend_status")"
  printf '后端 PID: %s\n' "$backend_pid_value"
  printf '前端 PID: %s\n' "$frontend_pid_value"
  printf '后端地址: http://127.0.0.1:%s\n' "$PORT"
  printf '前端地址: http://127.0.0.1:%s\n' "$FRONTEND_PORT"
  printf '健康检查:\n'
  printf '  后端 API: %s (/api/health)\n' "$backend_health"
  printf '  前端 Web: %s (/)\n' "$frontend_health"
  printf 'Conda 环境: %s\n' "$CONDA_ENV_NAME"
  printf '日志文件:\n'
  printf '  Backend: %s\n' "$LOG_FILE"
  printf '  Frontend: %s\n' "$FRONTEND_LOG_FILE"
}

tail_logs() {
  local files=()
  [[ -f "$LOG_FILE" ]] && files+=("$LOG_FILE")
  [[ -f "$FRONTEND_LOG_FILE" ]] && files+=("$FRONTEND_LOG_FILE")
  [[ ${#files[@]} -gt 0 ]] || fail "No log files found"
  exec tail -n 40 -f "${files[@]}"
}

follow_startup_logs() {
  local tail_pid

  log "Press Ctrl+C to stop services started in this session."
  tail -n 0 -F "$LOG_FILE" "$FRONTEND_LOG_FILE" &
  tail_pid=$!

  trap 'echo; log "Stopping services started in this session..."; kill "$tail_pid" >/dev/null 2>&1 || true; cleanup_started_services; exit 130' INT TERM

  while true; do
    if [[ "$STARTED_BACKEND_THIS_RUN" == "1" ]] && ! backend_running; then
      log "Backend exited unexpectedly. Cleaning up services started in this session..."
      break
    fi
    if [[ "$STARTED_FRONTEND_THIS_RUN" == "1" ]] && ! frontend_running; then
      log "Frontend exited unexpectedly. Cleaning up services started in this session..."
      break
    fi
    sleep 1
  done

  kill "$tail_pid" >/dev/null 2>&1 || true
  cleanup_started_services
  return 1
}

start_all() {
  ensure_runtime_dir
  require_command lsof
  require_command npm
  ensure_conda_env

  [[ -f "$REPO_ROOT/main.py" ]] || fail "main.py not found in $REPO_ROOT"
  [[ -f "$REPO_ROOT/frontend/package.json" ]] || fail "frontend/package.json not found in $REPO_ROOT/frontend"

  STARTED_BACKEND_THIS_RUN="0"
  STARTED_FRONTEND_THIS_RUN="0"

  if ! start_backend; then
    return 1
  fi
  if ! start_frontend; then
    cleanup_started_services
    return 1
  fi

  log "Backend log: $LOG_FILE"
  log "Frontend log: $FRONTEND_LOG_FILE"

  if [[ "$NO_TAIL" == "1" ]]; then
    return 0
  fi

  if [[ "$STARTED_BACKEND_THIS_RUN" != "1" && "$STARTED_FRONTEND_THIS_RUN" != "1" ]]; then
    log "Services are already running. Use '$0 logs' to inspect live output."
    show_status
    return 0
  fi

  follow_startup_logs
}

stop_all() {
  stop_one "Frontend" "$FRONTEND_PID_FILE" "$FRONTEND_PORT" frontend_process_pid
  stop_one "Backend" "$PID_FILE" "$PORT" backend_process_pid
}

restart_all() {
  stop_all
  start_all
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      start|stop|restart|status|logs)
        ACTION="$1"
        ;;
      --no-tail)
        NO_TAIL="1"
        ;;
      --quiet)
        QUIET="1"
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  case "$ACTION" in
    start)
      start_all
      ;;
    stop)
      stop_all
      ;;
    restart)
      restart_all
      ;;
    status)
      show_status
      ;;
    logs)
      tail_logs
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
