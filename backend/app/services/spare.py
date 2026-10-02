"""备件领用业务规则：状态流转、字段校验与筛选口径都收在这里。"""
from __future__ import annotations

from typing import Any

from app.store import store

MODULE = "spare"
REQUIRED_FIELDS = ["领用单号", "备件名称", "备件规格"]
LIST_FIELDS = ["领用单号", "备件名称", "备件规格", "领用数量", "领用班组", "领用日期", "所属场站", "领用状态"]
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

    def get_entry(self, entry_id: int) -> dict[str, Any] | None:
        return store.find(MODULE, entry_id)

    def create_entry(self, values: dict[str, Any]) -> tuple[dict[str, Any] | None, list[str]]:
        missing = [field for field in REQUIRED_FIELDS if not str(values.get(field) or "").strip()]
        if missing:
            return None, missing
        rows = store.rows(MODULE)
        entry = {"id": max((int(row.get("id", 0)) for row in rows), default=0) + 1}
        # 登记时带上提交的全部字段，不再只留必填三项，避免列表页其它列空着
        entry.update({field: value for field, value in values.items() if field != "id"})
        entry["status"] = STATUS_ORDER[0]
        entry["pending"] = True
        entry["abnormal"] = False
        # 缺的字段一并补齐：领用状态跟着流转状态走，单据来源默认前台登记
        entry["领用状态"] = entry["status"]
        if not str(entry.get("单据来源") or "").strip():
            entry["单据来源"] = "前台登记"
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
        entry["pending"] = target != STATUS_ORDER[-1]
        entry["abnormal"] = action in NEGATIVE_ACTIONS
        entry["领用状态"] = target
        return entry, f"备件领用单已{action}"

    def summary(self) -> dict[str, Any]:
        """汇总卡片：与列表同一份数据、同一个口径，保证卡片数和列表条数一致。"""
        rows = store.rows(MODULE)
        total = len(rows)
        cards = [
            {"label": "待审批领用", "value": sum(1 for row in rows if row.get("status") == "待审批")},
            {"label": "领用单总数", "value": total},
            {"label": "退回单数", "value": sum(1 for row in rows if row.get("status") == "已退回")},
        ]
        return {"cards": cards, "total": total}
