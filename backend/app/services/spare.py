"""备件领用业务规则：状态流转、字段校验与筛选口径都收在这里。"""
from __future__ import annotations

from datetime import date
from typing import Any

from app.store import store

MODULE = "spare"
REQUIRED_FIELDS = ["领用单号", "备件名称", "备件规格"]
# 列表/登记时需要保证齐全的业务字段；早先只登记了必填项的单子按默认值补齐。
ALL_FIELDS = REQUIRED_FIELDS + ["领用数量", "领用班组", "领用日期", "所属场站", "领用状态"]
FIELD_DEFAULTS: dict[str, Any] = {
    "领用数量": 0,
    "领用班组": "",
    "所属场站": "",
}
STATUS_ORDER = ["待审批", "已批准", "已领用", "已退回"]
ACTION_RULES = {"批准领用": "已批准", "确认发放": "已领用", "退回备件": "已退回"}
NEGATIVE_ACTIONS = []


class SpareService:
    def list_entries(
        self,
        *,
        keyword: str | None = None,
        status: str | None = None,
        page: int = 1,
        size: int = 20,
    ) -> tuple[list[dict[str, Any]], int]:
        rows = store.rows(MODULE)
        if keyword:
            rows = [row for row in rows if keyword in str(row.get("领用单号", ""))]
        if status:
            rows = [row for row in rows if row.get("status") == status]
        total = len(rows)
        start = max(page - 1, 0) * size
        return rows[start:start + size], total

    def stats(self) -> dict[str, Any]:
        """汇总卡片：和列表读同一份数据，卡片口径与列表条数始终一致。"""
        rows = store.rows(MODULE)
        month_prefix = date.today().strftime("%Y-%m")
        pending_approval = sum(1 for row in rows if row.get("status") == "待审批")
        returned = sum(1 for row in rows if row.get("status") == "已退回")
        month_created = sum(1 for row in rows if str(row.get("领用日期", "")).startswith(month_prefix))
        history = sum(1 for row in rows if row.get("历史记录"))
        return {
            "total": len(rows),
            "cards": [
                {"label": "待审批领用", "value": pending_approval},
                {"label": "本月领用单", "value": month_created},
                {"label": "退回单数", "value": returned},
                {"label": "历史领用单", "value": history},
            ],
        }

    def get_entry(self, entry_id: int) -> dict[str, Any] | None:
        return store.find(MODULE, entry_id)

    def create_entry(self, values: dict[str, Any]) -> tuple[dict[str, Any] | None, list[str]]:
        missing = [field for field in REQUIRED_FIELDS if not str(values.get(field) or "").strip()]
        if missing:
            return None, missing
        rows = store.rows(MODULE)
        entry = {"id": max((int(row.get("id", 0)) for row in rows), default=0) + 1}
        for field in ALL_FIELDS:
            if field in REQUIRED_FIELDS:
                entry[field] = values.get(field)
            elif field == "领用日期":
                entry[field] = str(values.get(field) or "").strip() or date.today().isoformat()
            elif field == "领用状态":
                entry[field] = STATUS_ORDER[0]
            else:
                entry[field] = values.get(field) if str(values.get(field) or "").strip() else FIELD_DEFAULTS[field]
        entry["status"] = STATUS_ORDER[0]
        entry["pending"] = True
        entry["abnormal"] = False
        entry["历史记录"] = False
        rows.append(entry)
        return entry, []

    def run_action(self, entry_id: int, action: str) -> tuple[dict[str, Any] | None, str]:
        entry = store.find(MODULE, entry_id)
        if entry is None:
            return None, f"备件领用单 {entry_id} 不存在或已归档"
        if action not in ACTION_RULES:
            return None, f"动作「{action}」不属于备件领用可执行范围"
        target = ACTION_RULES[action]
        if target not in STATUS_ORDER:
            return None, f"目标状态「{target}」不在允许的状态序列里"
        entry["status"] = target
        entry["领用状态"] = target
        entry["pending"] = target != STATUS_ORDER[-1]
        entry["abnormal"] = action in NEGATIVE_ACTIONS
        return entry, f"备件领用单已{action}"
