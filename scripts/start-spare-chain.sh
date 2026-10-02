#!/usr/bin/env bash
# 备件领用链路一键启动：装齐两端依赖 → 灌备件领用示例数据 → 拉起前后端 → 同一次执行里验通接口。
#
# 用法：
#   scripts/start-spare-chain.sh
#
# 特点：
#   - 可重复执行：每次运行用独立临时目录（退出即清理），端口动态挑选，
#     不与本机其它任务（包括团队手动起的 8000/5173）互相干扰。
#   - 哪一环没成就在该环节停下，说清缺什么，并自动再试一次；仍不成则退出。
#   - 不改写既有脚本：backend/run.sh、Makefile、docker-compose.yml 保持原样，
#     团队手动那套命令照常用。
#
# 可用环境变量覆盖端口（默认动态挑选空闲端口）：
#   SPARE_CHAIN_BACKEND_PORT   后端端口
#   SPARE_CHAIN_FRONTEND_PORT  前端端口
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$REPO_ROOT/backend"
FRONTEND_DIR="$REPO_ROOT/frontend"
VENV_DIR="$BACKEND_DIR/.venv"

# ---------------------------------------------------------------- 输出辅助
info() { printf '\033[36m[信息]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[通过]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[提醒]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[失败]\033[0m %s\n' "$*" >&2; }

# 每一步统一走这里：失败先说清缺什么，再自动重试一次，仍不成则停在这一步。
# 用法：run_step <步骤名> <缺什么/怎么办> <命令...>
run_step() {
  local name="$1" hint="$2"; shift 2
  info "开始：${name}"
  if "$@"; then
    ok "${name}"
    return 0
  fi
  warn "${name} 未成功。${hint}；3 秒后再试一次"
  sleep 3
  if "$@"; then
    ok "${name}（重试后）"
    return 0
  fi
  fail "${name} 仍未通过，停在这一步。${hint}"
  exit 1
}

# ---------------------------------------------------------------- 前置检查
preflight() {
  local missing=()
  command -v python3 >/dev/null 2>&1 || missing+=("python3（后端运行时，请安装 Python 3.9+）")
  command -v node    >/dev/null 2>&1 || missing+=("node（前端运行时，请安装 Node 18+）")
  command -v npm     >/dev/null 2>&1 || missing+=("npm（前端包管理器，随 Node 一起安装）")
  command -v curl    >/dev/null 2>&1 || missing+=("curl（健康检查与接口验证要用）")
  command -v setsid  >/dev/null 2>&1 || missing+=("setsid（util-linux，用于成组回收子进程）")
  if [ "${#missing[@]}" -gt 0 ]; then
    fail "前置检查未通过，缺以下工具："
    printf '  - %s\n' "${missing[@]}" >&2
    exit 1
  fi
  ok "前置检查：python3 / node / npm / curl / setsid 都在"
}

# ---------------------------------------------------------------- 临时目录
# 每次运行一个独立目录，退出即删；启动时顺手清掉历史遗留（进程已全部退出的）目录。
WORK_DIR=""
BACKEND_PID=""
FRONTEND_PID=""

cleanup() {
  trap - EXIT INT TERM
  local pid
  for pid in "$BACKEND_PID" "$FRONTEND_PID"; do
    [ -n "$pid" ] && kill -TERM -- "-$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  info "已停止前后端进程，临时目录已清理"
}

prepare_workdir() {
  local dir pid alive
  # 先清上一次的遗留：只动带 pids 标记且进程已全部退出的目录，不碰别人正在用的。
  for dir in /tmp/spare-chain.*; do
    [ -d "$dir" ] || continue
    [ -f "$dir/pids" ] || continue
    alive=0
    while read -r pid; do
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1 && break
    done < "$dir/pids"
    [ "$alive" -eq 0 ] && rm -rf "$dir"
  done
  WORK_DIR="$(mktemp -d /tmp/spare-chain.XXXXXX)"
  : > "$WORK_DIR/pids"
  trap cleanup EXIT INT TERM
  ok "临时目录：$WORK_DIR（退出时自动清理）"
}

# ---------------------------------------------------------------- 端口
free_port() {
  python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
}

pick_ports() {
  BE_PORT="${SPARE_CHAIN_BACKEND_PORT:-$(free_port)}"
  FE_PORT="${SPARE_CHAIN_FRONTEND_PORT:-$(free_port)}"
  while [ "$FE_PORT" = "$BE_PORT" ]; do
    FE_PORT="$(free_port)"
  done
  ok "端口就绪：后端 $BE_PORT，前端 $FE_PORT（动态挑选，不占用固定端口）"
}

# ---------------------------------------------------------------- 后端依赖
prepare_venv() {
  if [ -x "$VENV_DIR/bin/python" ] && "$VENV_DIR/bin/python" -c 'pass' 2>/dev/null; then
    info "复用已有虚拟环境：$VENV_DIR"
  else
    if [ -d "$VENV_DIR" ]; then
      warn "已有 .venv 在这台机器上不可用（多半是在别的机器上创建的），重建"
      rm -rf "$VENV_DIR"
    fi
    # 有的机器缺 ensurepip（未装 python3-venv），venv 建出来也没有 pip，先建再说，
    # 输出收进临时日志，真失败时再倒出来看。
    if ! python3 -m venv "$VENV_DIR" >"$WORK_DIR/venv.log" 2>&1; then
      warn "python3 -m venv 未完全成功（常见于缺 python3-venv），继续检查解释器"
    fi
    if [ ! -x "$VENV_DIR/bin/python" ]; then
      fail "python3 -m venv 没能产出解释器，日志如下："
      tail -n 10 "$WORK_DIR/venv.log" >&2 || true
      return 1
    fi
  fi
  if ! "$VENV_DIR/bin/python" -m pip --version >/dev/null 2>&1; then
    warn "虚拟环境里没有 pip（这台机器缺 ensurepip/python3-venv），改用 get-pip 引导"
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$WORK_DIR/get-pip.py" || {
      fail "下载 get-pip.py 失败，请检查网络或手动安装 python3-venv"
      return 1
    }
    "$VENV_DIR/bin/python" "$WORK_DIR/get-pip.py" >/dev/null 2>&1 || {
      fail "get-pip 引导失败，请手动安装 python3-venv 后重试"
      return 1
    }
  fi
  "$VENV_DIR/bin/python" -m pip install -q -r "$BACKEND_DIR/requirements.txt"
}

# ---------------------------------------------------------------- 前端依赖
prepare_frontend() {
  cd "$FRONTEND_DIR"
  if [ -f package-lock.json ] && [ ! -d node_modules ]; then
    # 有锁文件且是全新目录：严格按锁文件装
    npm ci --no-audit --no-fund
  else
    # 已有 node_modules：增量装，版本仍以锁文件为准；没有锁文件时顺带生成
    [ -f package-lock.json ] || warn "缺少 package-lock.json，本次用 npm install 并生成锁文件"
    npm install --no-audit --no-fund
  fi
  # 装完探一下活：node_modules 若是从别的机器/平台搬来的，vite 根本起不来，
  # 这时按锁文件清掉重装，而不是带着一棵跑不起来的树继续走。
  if ! ./node_modules/.bin/vite --version >/dev/null 2>&1; then
    warn "node_modules 在这台机器上跑不起来（多半是从别的平台搬来的），按锁文件重装"
    rm -rf node_modules
    if [ -f package-lock.json ]; then
      npm ci --no-audit --no-fund
    else
      npm install --no-audit --no-fund
    fi
    ./node_modules/.bin/vite --version >/dev/null 2>&1 || {
      fail "重装后 vite 仍起不来：锁文件可能也是在别的平台上生成的，请删除 frontend/package-lock.json 与 node_modules 后重跑本脚本"
      return 1
    }
  fi
}

# ---------------------------------------------------------------- 启动服务
wait_url() {  # wait_url <地址> <秒数>
  local url="$1" tries="$2"
  while [ "$tries" -gt 0 ]; do
    curl -fsS "$url" >/dev/null 2>&1 && return 0
    sleep 1
    tries=$((tries - 1))
  done
  return 1
}

start_backend() {
  cd "$BACKEND_DIR"
  setsid "$VENV_DIR/bin/python" -m uvicorn app.main:app \
    --host 127.0.0.1 --port "$BE_PORT" \
    >"$WORK_DIR/backend.log" 2>&1 < /dev/null &
  BACKEND_PID=$!
  echo "$BACKEND_PID" >> "$WORK_DIR/pids"
  if ! wait_url "http://127.0.0.1:$BE_PORT/api/health" 30; then
    fail "后端 30 秒内未就绪，日志末尾如下："
    tail -n 20 "$WORK_DIR/backend.log" >&2 || true
    return 1
  fi
  info "后端已监听 http://127.0.0.1:$BE_PORT（日志在临时目录，退出即删）"
}

start_frontend() {
  cd "$FRONTEND_DIR"
  # VITE_PROXY_TARGET 把 /api 代理指向本次拉起的后端，两端地址在这一步对齐
  setsid env VITE_PROXY_TARGET="http://127.0.0.1:$BE_PORT" \
    npm run dev -- --host 127.0.0.1 --port "$FE_PORT" --strictPort \
    >"$WORK_DIR/frontend.log" 2>&1 < /dev/null &
  FRONTEND_PID=$!
  echo "$FRONTEND_PID" >> "$WORK_DIR/pids"
  if ! wait_url "http://127.0.0.1:$FE_PORT/" 60; then
    fail "前端 60 秒内未就绪，日志末尾如下："
    tail -n 20 "$WORK_DIR/frontend.log" >&2 || true
    return 1
  fi
  info "前端已监听 http://127.0.0.1:$FE_PORT（/api 已代理到后端 $BE_PORT）"
}

# ---------------------------------------------------------------- 灌示例数据
write_seed_script() {
  cat > "$WORK_DIR/seed_spare.py" <<'PY'
"""把备件领用的示例数据灌进运行中的后端：已存在的跳过，缺的补齐，可重复执行。"""
import json
import sys
import urllib.request

BASE = sys.argv[1].rstrip("/")

SAMPLE_ORDERS = [
    {"领用单号": "SPAR-0001", "备件名称": "备件领用样例1", "备件规格": "备件领用样例1",
     "领用数量": 10, "领用班组": "备件领用样例1", "领用日期": "2026-09-01",
     "所属场站": "备件领用样例1", "单据来源": "历史导入"},
    {"领用单号": "SPAR-0002", "备件名称": "备件领用样例2", "备件规格": "备件领用样例2",
     "领用数量": 20, "领用班组": "备件领用样例2", "领用日期": "2026-09-02",
     "所属场站": "备件领用样例2", "单据来源": "历史导入"},
    {"领用单号": "SPAR-0003", "备件名称": "备件领用样例3", "备件规格": "备件领用样例3",
     "领用数量": 30, "领用班组": "备件领用样例3", "领用日期": "2026-09-03",
     "所属场站": "备件领用样例3", "单据来源": "历史导入"},
]


def call(path, payload=None):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))


created, skipped = 0, 0
for order in SAMPLE_ORDERS:
    code = order["领用单号"]
    existing = call(f"/api/spare?keyword={code}&size=1")
    if existing["total"] > 0:
        skipped += 1
        continue
    result = call("/api/spare", {"values": order})
    if not result.get("ok"):
        print(f"灌入 {code} 失败：{result.get('message')}", file=sys.stderr)
        sys.exit(1)
    created += 1

total = call("/api/spare?size=1")["total"]
print(f"示例数据就绪：新灌 {created} 条，已存在跳过 {skipped} 条，当前共 {total} 条")
PY
}

seed_spare() {
  write_seed_script
  python3 "$WORK_DIR/seed_spare.py" "http://127.0.0.1:$BE_PORT"
}

# ---------------------------------------------------------------- 接口验证
write_verify_script() {
  cat > "$WORK_DIR/verify_spare.py" <<'PY'
"""备件领用链路验证：全部走前端 dev server 的 /api 代理，验证两端地址对得上。

验三件事：
  1. 领用单列表页接口：能读到数据，且每条记录的列表字段齐全（历史数据已回填）；
  2. 登记接口：备件名称、备件规格提交后能落库并回显；
  3. 汇总卡片：卡片上的领用单总数与列表条数一致。
"""
import json
import sys
import urllib.request

BASE = sys.argv[1].rstrip("/")
LIST_FIELDS = ["领用单号", "备件名称", "备件规格", "领用数量", "领用班组", "领用日期", "所属场站", "领用状态"]
HISTORY_CODES = {"SPAR-0001", "SPAR-0002", "SPAR-0003"}

failures = []


def check(name, fn):
    try:
        fn()
    except Exception as exc:  # noqa: BLE001 - 把失败原因攒起来一起报
        failures.append(f"{name}：{exc}")
        print(f"  ✗ {name}：{exc}")
    else:
        print(f"  ✓ {name}")


def call(path, payload=None):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))


def check_list():
    page = call("/api/spare?page=1&size=50")
    total = page["total"]
    assert total >= 3, f"列表只有 {total} 条，示例数据没灌进去"
    for row in page["items"]:
        missing = [f for f in LIST_FIELDS if row.get(f) in (None, "")]
        assert not missing, f"领用单 {row.get('领用单号')} 缺字段：{'、'.join(missing)}"
        assert str(row.get("单据来源") or "").strip(), f"领用单 {row.get('领用单号')} 缺单据来源"
        if row.get("领用单号") in HISTORY_CODES:
            assert row["单据来源"] == "历史导入", \
                f"早先导入的 {row['领用单号']} 未回填成历史记录（单据来源={row['单据来源']}）"


def check_create():
    payload = {"values": {"领用单号": "SPAR-VERIFY-CHAIN",
                          "备件名称": "链式验证备件",
                          "备件规格": "VERIFY-SPEC-10kV"}}
    result = call("/api/spare", payload)
    assert result.get("ok"), f"登记被拒：{result.get('message')}"
    entry = result.get("entry") or {}
    assert entry.get("备件名称") == "链式验证备件", f"备件名称未落库：{entry.get('备件名称')}"
    assert entry.get("备件规格") == "VERIFY-SPEC-10kV", f"备件规格未落库：{entry.get('备件规格')}"
    assert entry.get("领用状态") == "待审批", f"新单领用状态应为待审批，实际 {entry.get('领用状态')}"


def check_summary():
    summary = call("/api/spare/summary")
    cards = {card["label"]: card["value"] for card in summary.get("cards", [])}
    assert "领用单总数" in cards, f"汇总卡片缺「领用单总数」：{list(cards)}"
    list_total = call("/api/spare?size=1")["total"]
    assert cards["领用单总数"] == list_total, \
        f"汇总卡片 {cards['领用单总数']} 条 ≠ 列表 {list_total} 条"


print(f"通过前端代理 {BASE} 验证备件领用链路：")
check("领用单列表页接口（字段齐全、历史单已回填）", check_list)
check("登记接口（备件名称、备件规格落库回显）", check_create)
check("汇总卡片与列表条数一致", check_summary)

if failures:
    print("验证未通过：", file=sys.stderr)
    for item in failures:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)
print("三处接口全部验通")
PY
}

verify_chain() {
  write_verify_script
  python3 "$WORK_DIR/verify_spare.py" "http://127.0.0.1:$FE_PORT"
}

# ---------------------------------------------------------------- 主流程
main() {
  preflight
  prepare_workdir

  run_step "后端虚拟环境与依赖（按 requirements.txt 装齐）" \
    "缺可用的 python3 venv 或 pip 装包失败，请确认 python3 完整、能访问 PyPI" \
    prepare_venv

  run_step "前端依赖（按 package-lock.json 装齐）" \
    "缺 node_modules 或 npm 装包失败，请确认 Node 18+、能访问 npm 仓库" \
    prepare_frontend

  pick_ports

  run_step "启动后端" \
    "后端没能起来，通常是端口被占或依赖没装齐" \
    start_backend

  run_step "灌备件领用示例数据" \
    "示例数据没灌进去，请确认后端 /api/spare 可写" \
    seed_spare

  run_step "启动前端" \
    "前端没能起来，请确认 npm 依赖装齐、端口空闲" \
    start_frontend

  run_step "验证备件领用接口（列表页 / 登记 / 汇总卡片）" \
    "接口没验通，请确认前端代理已指向本次后端" \
    verify_chain

  echo
  ok "备件领用链路已就绪"
  info "前端页面：http://127.0.0.1:$FE_PORT/ （dev server 不会自动打开浏览器）"
  info "后端接口：http://127.0.0.1:$BE_PORT/api/spare"
  info "按 Ctrl+C 停止两端进程并清理临时目录"
  wait
}

main "$@"
