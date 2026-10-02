"""备件领用接口：维护备件领用单，覆盖批准领用、确认发放、退回备件等动作。"""
from __future__ import annotations

from typing import Any

from fastapi import APIRouter, HTTPException, Query

from app.schemas import ActionResult, EntryPayload, PageResult
from app.services.spare import SpareService

router = APIRouter(prefix="/api/spare", tags=["备件领用"])

service = SpareService()

LIST_FIELDS = ["领用单号", "备件名称", "备件规格", "领用数量", "领用班组", "领用日期", "所属场站", "领用状态", "历史记录"]
STATUSES = ["待审批", "已批准", "已领用", "已退回"]


@router.get("", response_model=PageResult[dict])
def list_entries(
    keyword: str | None = Query(default=None, description="按领用单号检索"),
    status: str | None = Query(default=None, description="待审批、已批准、已领用、已退回"),
    page: int = 1,
    size: int = 20,
) -> PageResult[dict]:
    """按领用单号与状态过滤备件领用列表；没有数据时返回空页，不报错。"""
    if size > 200:
        raise HTTPException(status_code=400, detail="每页最多 200 条，请缩小分页范围")
    items, total = service.list_entries(keyword=keyword, status=status, page=page, size=size)
    return PageResult(items=items, total=total, page=page, size=size)


@router.get("/stats")
def entry_stats() -> dict[str, Any]:
    """领用单汇总卡片：与列表同源，卡片值和列表条数对得上。"""
    return service.stats()


@router.get("/export")
def export_entries() -> dict[str, Any]:
    """导出备件领用清单：返回当前过滤条件下的全量数据。"""
    items, total = service.list_entries(page=1, size=10000)
    return {"module": "spare", "total": total, "items": items}


@router.get("/{entry_id}", response_model=dict)
def get_entry(entry_id: int) -> dict:
    """读取单条备件领用单明细；不存在时给出可读的错误说明。"""
    entry = service.get_entry(entry_id)
    if entry is None:
        raise HTTPException(status_code=404, detail=f"备件领用单 {entry_id} 不存在或已归档")
    return entry


@router.post("", response_model=ActionResult)
def create_entry(payload: EntryPayload) -> ActionResult:
    """登记一条备件领用单，缺字段时说明原因而不是静默丢弃。"""
    entry, missing = service.create_entry(payload.values)
    if missing:
        return ActionResult(ok=False, message=f"缺少必填字段：{'、'.join(missing)}")
    return ActionResult(ok=True, message="备件领用单已登记", entry=entry)


@router.post("/{entry_id}/actions", response_model=ActionResult)
def run_action(entry_id: int, payload: EntryPayload) -> ActionResult:
    """对单条备件领用单执行批准领用、确认发放、退回备件；不允许的动作会被拦下并说明原因。"""
    action = str(payload.values.get("action") or "").strip()
    entry, message = service.run_action(entry_id, action)
    if entry is None:
        return ActionResult(ok=False, message=message)
    return ActionResult(ok=True, message=message, entry=entry)
