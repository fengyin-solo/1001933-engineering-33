#!/usr/bin/env python3
"""备件领用链路验收：只依赖标准库，所有请求都走前端 dev server 的 /api 代理。

验通项（同一次执行内完成）：
1. GET  /api/health            后端在线、示例数据就绪
2. GET  /api/spare             领用单列表页接口（经前端代理）
3. POST /api/spare             登记备件名称、备件规格（含缺字段反例）
4. GET  /api/spare/stats       汇总卡片与列表条数一致、新登记单进列表
"""
from __future__ import annotations

import datetime as _dt
import json
import sys
import urllib.error
import urllib.request

BASE = sys.argv[1].rstrip("/")
FAILURES: list[str] = []


def call(method: str, path: str, body: object | None = None) -> tuple[int, object]:
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        BASE + path,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8") or "null")
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8") or "null")


def check(name: str, ok: bool, detail: str = "") -> None:
    mark = "PASS" if ok else "FAIL"
    print(f"[{mark}] {name}" + (f" —— {detail}" if detail else ""))
    if not ok:
        FAILURES.append(name)


# 1. 健康检查（经前端代理，顺带验通两端地址已经对上）
status, health = call("GET", "/api/health")
check("健康检查 GET /api/health（经前端代理）", status == 200 and isinstance(health, dict) and health.get("ok") is True,
      f"HTTP {status}: {health}")

# 2. 领用单列表页接口
status, before = call("GET", "/api/spare?page=1&size=200")
items_before = before.get("items", []) if isinstance(before, dict) else []
total_before = before.get("total") if isinstance(before, dict) else None
check("领用单列表 GET /api/spare", status == 200 and isinstance(items_before, list) and total_before == len(items_before),
      f"HTTP {status}, total={total_before}, 实际条数={len(items_before)}")
seeded = [row for row in items_before if str(row.get("领用单号", "")).startswith("SPAR-")]
check("备件领用示例数据已灌入", len(seeded) >= 3, f"SPAR-* 样例单 {len(seeded)} 条")
backfilled = all(
    str(row.get("备件名称", "")).strip()
    and str(row.get("备件规格", "")).strip()
    and str(row.get("领用班组", "")).strip()
    and str(row.get("所属场站", "")).strip()
    and str(row.get("领用日期", "")).strip()
    and row.get("历史记录") is True
    for row in seeded
)
check("早先导入的领用单已回填为历史记录且字段补齐", backfilled)

# 3. 登记接口：缺备件名称/备件规格应被明确拦下
status, bad = call("POST", "/api/spare", {"values": {"领用单号": "SPAR-CHECK-BAD"}})
check("登记缺字段时给出明确提示", status == 200 and isinstance(bad, dict) and bad.get("ok") is False
      and "备件名称" in str(bad.get("message", "")) and "备件规格" in str(bad.get("message", "")),
      f"HTTP {status}: {bad}")

# 4. 正常登记一条（备件名称、备件规格两项一起验）
code = _dt.date.today().strftime("%m%d")
payload = {
    "values": {
        "领用单号": f"SPAR-CHECK-{code}",
        "备件名称": "链路验收_偏航减速器油封",
        "备件规格": "TC-85×105×10 氟橡胶",
        "领用数量": 2,
        "领用班组": "启动脚本验收组",
        "所属场站": "苍屿风电场",
    }
}
status, created = call("POST", "/api/spare", payload)
entry = created.get("entry") if isinstance(created, dict) else None
check("登记备件名称、备件规格 POST /api/spare", status == 200 and isinstance(created, dict)
      and created.get("ok") is True and isinstance(entry, dict)
      and entry.get("备件名称") == payload["values"]["备件名称"]
      and entry.get("备件规格") == payload["values"]["备件规格"],
      f"HTTP {status}: {created}")
if isinstance(entry, dict):
    new_id = entry.get("id")
    filled_defaults = entry.get("领用状态") == "待审批" and entry.get("领用日期") and entry.get("历史记录") is False
    check("新登记单缺失字段已自动补齐", bool(filled_defaults),
          f"领用状态={entry.get('领用状态')}, 领用日期={entry.get('领用日期')}, 历史记录={entry.get('历史记录')}")

# 5. 新登记单要出现在列表里
status, after = call("GET", "/api/spare?page=1&size=200")
items_after = after.get("items", []) if isinstance(after, dict) else []
visible = any(isinstance(row, dict) and row.get("id") == new_id for row in items_after) if isinstance(entry, dict) else False
check("新登记单出现在领用单列表", status == 200 and visible and after.get("total") == total_before + 1,
      f"登记前 total={total_before}，登记后 total={after.get('total') if isinstance(after, dict) else 'N/A'}")

# 6. 汇总卡片口径与列表一致
status, stats = call("GET", "/api/spare/stats")
cards = {c.get("label"): c.get("value") for c in stats.get("cards", [])} if isinstance(stats, dict) else {}
month_prefix = _dt.date.today().strftime("%Y-%m")
expect = {
    "待审批领用": sum(1 for r in items_after if r.get("status") == "待审批"),
    "本月领用单": sum(1 for r in items_after if str(r.get("领用日期", "")).startswith(month_prefix)),
    "退回单数": sum(1 for r in items_after if r.get("status") == "已退回"),
    "历史领用单": sum(1 for r in items_after if r.get("历史记录") is True),
}
check("汇总卡片与列表条数一致", status == 200 and all(cards.get(k) == v for k, v in expect.items()),
      f"卡片={cards}，列表核算={expect}")
check("汇总 total 等于列表 total", isinstance(stats, dict) and stats.get("total") == len(items_after),
      f"stats.total={stats.get('total') if isinstance(stats, dict) else 'N/A'}, 列表条数={len(items_after)}")

print()
if FAILURES:
    print(f"验收未通过：{len(FAILURES)} 项 —— " + "、".join(FAILURES))
    sys.exit(1)
print("备件领用链路全部验通：列表页、登记（备件名称/备件规格）、汇总卡片一致。")
