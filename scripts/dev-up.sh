#!/usr/bin/env bash
# 备件领用链路一键启动（可重复执行，与本机其它任务隔离）。
#
# 流程：前置检查 → 按锁文件装后端依赖 → 按锁文件装前端依赖
#       → 启动后端（自动灌入备件领用示例数据）→ 启动前端（代理指向本次后端端口）
#       → 同一次执行内验通：领用单列表、登记备件名称/备件规格、汇总卡片一致
#
# 设计约定：
#   * 每一步失败后自动重试 1 次；仍失败立即停下，打印缺什么并保留日志与临时目录。
#   * 每次执行用独立临时目录、动态空闲端口，不碰 8000/5173，不影响本机其它任务。
#   * 既有 Makefile / run.sh / npm run dev 保持不动，本地开发照旧手动跑。
#   * Ctrl-C 或验收失败会停掉本次拉起的进程并清理临时目录；失败现场保留在临时目录。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_BASE="${TMPDIR:-/tmp}/windfarm-om-dev"
RUN_DIR=""
BACKEND_PORT=""
FRONTEND_PORT=""
BACKEND_PID=""
FRONTEND_PID=""
PIP_BIN=""

log()  { printf '\033[1;36m[dev-up]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[dev-up 警告]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[dev-up 失败]\033[0m %s\n' "$*" >&2; exit 1; }
export -f log warn || true

# ---------------------------------------------------------------------------
# 清理：只杀本次脚本拉起的进程组，只删本次的临时目录
# ---------------------------------------------------------------------------
cleanup() {
  local code=$?
  trap - EXIT INT TERM
  if [ -n "$FRONTEND_PID" ] && kill -0 "$FRONTEND_PID" 2>/dev/null; then
    kill -- -"$FRONTEND_PID" 2>/dev/null || kill "$FRONTEND_PID" 2>/dev/null || true
  fi
  if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
    kill -- -"$BACKEND_PID" 2>/dev/null || kill "$BACKEND_PID" 2>/dev/null || true
  fi
  wait 2>/dev/null || true
  # 失败退出码 2 时保留现场（run_step 会先打印路径）；正常结束和 Ctrl-C 都清理
  if [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] && [ "$code" -ne 2 ]; then
    rm -rf "$RUN_DIR"
  fi
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

# run_step <步骤名> <尝试次数> -- <命令...>
# 每步失败重试 1 次（共 2 次尝试），仍失败则停下说清缺什么。
run_step() {
  local name="$1"; shift
  local tries="$1"; shift
  [ "$1" = "--" ] && shift
  local attempt logfile
  logfile="$RUN_DIR/step.log"
  for attempt in $(seq 1 "$tries"); do
    log "${name}（第 ${attempt}/${tries} 次）"
    if "$@" >"$logfile" 2>&1; then
      log "${name}：完成"
      return 0
    fi
    warn "${name} 未成功，末尾输出："
    tail -n 15 "$logfile" | sed 's/^/    /' >&2
    if [ "$attempt" -lt "$tries" ]; then
      log "稍后重试一次：${name}"
      sleep 2
    fi
  done
  printf '\033[1;31m[dev-up 失败]\033[0m 步骤「%s」两次尝试均未成功，已停下。\n' "${name}" >&2
  echo "  日志：$logfile" >&2
  echo "  现场目录（保留供排查）：$RUN_DIR" >&2
  KEEP_RUN_DIR=1
  exit 2
}

wait_url() {
  # $1=URL $2=最多等待秒数
  local url="$1" deadline=$(( $(date +%s) + $2 ))
  until curl -fsS --max-time 3 "$url" -o /dev/null 2>&1; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 1
  done
}
export -f wait_url

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# ---------------------------------------------------------------------------
# 0. 前置检查 + 隔离的临时目录（重跑先清上一次的残留）
# ---------------------------------------------------------------------------
log "仓库根目录：$REPO_ROOT"

# 同一仓库同一时刻只允许一个 dev-up：npm ci 会重建仓库内 node_modules，
# 两个实例并发会互相踩。锁只锁本仓库（按仓库路径区分），不影响机器上其它任务。
LOCK_FILE="$REPO_ROOT/.git/dev-up.lock"
if [ ! -d "$REPO_ROOT/.git" ]; then
  LOCK_FILE="${TMPDIR:-/tmp}/windfarm-om-dev.$(printf '%s' "$REPO_ROOT" | md5sum | cut -c1-12).lock"
fi
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  die "该仓库已有一个 dev-up 在运行（同一仓库不能并发：npm ci 会共用 node_modules）。等它结束（或 Ctrl-C）后再重跑。"
fi

[ -f "$REPO_ROOT/backend/requirements.lock" ] || die "缺少 backend/requirements.lock（后端锁文件），无法按锁文件安装。"
[ -f "$REPO_ROOT/frontend/package-lock.json" ] || die "缺少 frontend/package-lock.json（前端锁文件），无法按锁文件安装。"

command -v python3 >/dev/null || die "缺少 python3，请先安装 Python 3.10+。"
command -v npm >/dev/null     || die "缺少 npm，请先安装 Node.js 18+（含 npm）。"
command -v curl >/dev/null    || die "缺少 curl，健康检查与验收需要它。"
command -v setsid >/dev/null  || die "缺少 setsid（util-linux），脚本用它隔离本次拉起的进程组。"
PY_VER=$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')
python3 -c 'import sys;raise SystemExit(0 if sys.version_info>=(3,10) else 1)' \
  || die "Python 版本为 ${PY_VER}，需要 3.10 及以上。"

# 清掉上一次（或中断后残留）的临时目录；只认本脚本前缀。
# 属主 PID 还活着且确实是本脚本时才保留（防止 PID 被系统回收后误判）。
shopt -s nullglob
for stale in "$RUN_BASE".run*; do
  [ -d "$stale" ] || continue
  owner_pid="$(basename "$stale" | sed -n 's/^.*\.run\([0-9][0-9]*\)\..*$/\1/p')"
  in_use=0
  if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
    if [ -r "/proc/$owner_pid/cmdline" ]; then
      tr '\0' ' ' < "/proc/$owner_pid/cmdline" | grep -q "dev-up.sh" && in_use=1
    else
      in_use=1
    fi
  fi
  if [ "$in_use" -eq 0 ]; then
    rm -rf "$stale" && warn "已清理上次残留临时目录：$stale"
  fi
done
shopt -u nullglob
RUN_DIR="$(mktemp -d "${RUN_BASE}.run$$.XXXXXXXX")"
mkdir -p "$RUN_DIR/pip-cache" "$RUN_DIR/npm-cache"
log "本次临时目录：$RUN_DIR"

BACKEND_PORT="$(free_port)"
FRONTEND_PORT="$(free_port)"
[ -n "$BACKEND_PORT" ] && [ -n "$FRONTEND_PORT" ] || die "无法申请到空闲端口。"
log "本次端口：后端 ${BACKEND_PORT} / 前端 ${FRONTEND_PORT}（不占用 8000、5173）"

# ---------------------------------------------------------------------------
# 1. 后端依赖：独立 venv，严格按 requirements.lock 安装
#    系统 Python 没有 venv/pip 时，自动下载 uv 到本次临时目录引导（不写系统目录）
# ---------------------------------------------------------------------------
VENV_DIR="$RUN_DIR/backend-venv"
setup_python() {
  if python3 -m venv "$VENV_DIR" && [ -x "$VENV_DIR/bin/pip" ]; then
    PIP_BIN="$VENV_DIR/bin/pip"
    return 0
  fi
  warn "系统 Python 无法创建 venv（通常是缺 python3-venv / pip），改用临时 uv 引导。"
  # 清掉标准库 venv 失败后留下的半成品目录，uv 不会覆盖已存在的目录
  rm -rf "$VENV_DIR"
  local uv="$RUN_DIR/bin/uv"
  mkdir -p "$RUN_DIR/bin"
  curl -LsSf https://astral.sh/uv/install.sh -o "$RUN_DIR/uv-install.sh"
  UV_INSTALL_DIR="$RUN_DIR/bin" sh "$RUN_DIR/uv-install.sh" >/dev/null
  "$uv" venv "$VENV_DIR" --python "$(command -v python3)" || return 1
  echo "$uv" > "$VENV_DIR/UV_BIN"
  PIP_BIN="$uv"
}
run_step "准备后端虚拟环境" 2 -- bash -c "$(declare -f setup_python); VENV_DIR='$VENV_DIR' RUN_DIR='$RUN_DIR'; setup_python && echo \$PIP_BIN > '$RUN_DIR/pip.path'"
PIP_BIN="$(cat "$RUN_DIR/pip.path")"
[ -x "$VENV_DIR/bin/python" ] || die "后端虚拟环境未建成，缺少可用的 Python venv 支持（可手动安装 python3-venv 后重跑）。"

install_backend() {
  if [ -f "$VENV_DIR/UV_BIN" ]; then
    "$PIP_BIN" pip install --python "$VENV_DIR/bin/python" --no-deps \
      --cache-dir "$RUN_DIR/pip-cache" -r "$REPO_ROOT/backend/requirements.lock"
  else
    "$PIP_BIN" install --no-deps --cache-dir "$RUN_DIR/pip-cache" \
      -r "$REPO_ROOT/backend/requirements.lock"
  fi
  "$VENV_DIR/bin/python" -c "import fastapi, uvicorn, pydantic"
}
run_step "按锁文件安装后端依赖（requirements.lock）" 2 -- bash -c "$(declare -f install_backend); PIP_BIN='$PIP_BIN' VENV_DIR='$VENV_DIR' RUN_DIR='$RUN_DIR' REPO_ROOT='$REPO_ROOT'; install_backend"

# ---------------------------------------------------------------------------
# 2. 前端依赖：严格按 package-lock.json 安装（npm ci 会清装，不更新锁文件）
# ---------------------------------------------------------------------------
install_frontend() {
  cd "$REPO_ROOT/frontend"
  npm ci --cache "$RUN_DIR/npm-cache" --no-audit --no-fund
}
run_step "按锁文件安装前端依赖（package-lock.json / npm ci）" 2 -- bash -c "$(declare -f install_frontend); RUN_DIR='$RUN_DIR' REPO_ROOT='$REPO_ROOT'; install_frontend"

# ---------------------------------------------------------------------------
# 3. 启动后端（备件领用示例数据随服务启动自动灌入内存仓库）
# ---------------------------------------------------------------------------
log "启动后端：127.0.0.1:${BACKEND_PORT}"
(
  cd "$REPO_ROOT/backend"
  exec setsid "$VENV_DIR/bin/python" -m uvicorn app.main:app \
    --host 127.0.0.1 --port "$BACKEND_PORT"
) >"$RUN_DIR/backend.log" 2>&1 &
BACKEND_PID=$!
run_step "等待后端就绪并灌入备件领用示例数据" 2 -- wait_url "http://127.0.0.1:${BACKEND_PORT}/api/health" 30

# ---------------------------------------------------------------------------
# 4. 启动前端：代理目标显式指向本次后端，接口地址天然对齐
# ---------------------------------------------------------------------------
log "启动前端：127.0.0.1:${FRONTEND_PORT}（/api 代理到 ${BACKEND_PORT}）"
(
  cd "$REPO_ROOT/frontend"
  exec setsid env VITE_PROXY_TARGET="http://127.0.0.1:${BACKEND_PORT}" \
    npm run dev -- --port "$FRONTEND_PORT" --strictPort
) >"$RUN_DIR/frontend.log" 2>&1 &
FRONTEND_PID=$!
run_step "等待前端 dev server 就绪" 2 -- wait_url "http://127.0.0.1:${FRONTEND_PORT}/" 60

# ---------------------------------------------------------------------------
# 5. 一次执行内验通三处接口（全部经前端代理，验的就是浏览器真实链路）
# ---------------------------------------------------------------------------
run_step "验通备件领用链路（列表 / 登记备件名称、备件规格 / 汇总一致）" 2 -- \
  "$VENV_DIR/bin/python" "$REPO_ROOT/scripts/verify_spare.py" "http://127.0.0.1:${FRONTEND_PORT}"

cat <<EOF

$(printf '\033[1;32m%s\033[0m' '备件领用链路已就绪，接口验收全部通过。')
  前端页面：  http://127.0.0.1:${FRONTEND_PORT}/spare
  后端健康：  http://127.0.0.1:${BACKEND_PORT}/api/health
  接口代理：  /api -> http://127.0.0.1:${BACKEND_PORT}
  运行日志：  $RUN_DIR/backend.log , $RUN_DIR/frontend.log
  停止服务：  Ctrl-C（会自动停掉本次进程并清理临时目录）
EOF

# 前台等待，Ctrl-C 后由 cleanup 收尾
wait
