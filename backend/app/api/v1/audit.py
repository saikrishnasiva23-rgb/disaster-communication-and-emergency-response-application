from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query
from sqlalchemy import func, select

from app.api.deps import AdminUser, DbSession, PaginationDep, RescuerUser
from app.db.models import AuditLog
from app.db.types import utcnow
from app.schemas.audit import AuditEntryPublic, AuditVerifyResult
from app.schemas.common import ApiResponse, error_responses
from app.services import audit_service

router = APIRouter(prefix="/audit", tags=["Audit Log"])


@router.get(
    "",
    response_model=ApiResponse[list[AuditEntryPublic]],
    response_model_by_alias=True,
    summary="Audit log entries, newest first (admin)",
    responses=error_responses(401, 403),
)
async def list_audit(
    _: AdminUser,
    session: DbSession,
    pagination: PaginationDep,
    action: Annotated[str | None, Query(max_length=64)] = None,
    entity_type: Annotated[str | None, Query(max_length=40)] = None,
    entity_id: Annotated[str | None, Query(max_length=64)] = None,
) -> ApiResponse[list[AuditEntryPublic]]:
    query = select(AuditLog)
    if action:
        query = query.where(AuditLog.action == action.upper())
    if entity_type:
        query = query.where(AuditLog.entity_type == entity_type)
    if entity_id:
        query = query.where(AuditLog.entity_id == entity_id)
    total = int(await session.scalar(select(func.count()).select_from(query.subquery())) or 0)
    rows = (
        await session.scalars(
            query.order_by(AuditLog.sequence.desc())
            .offset((pagination.page - 1) * pagination.page_size)
            .limit(pagination.page_size)
        )
    ).all()
    return ApiResponse(
        data=[AuditEntryPublic.model_validate(r) for r in rows], meta=pagination.meta(total)
    )


@router.get(
    "/verify",
    response_model=ApiResponse[AuditVerifyResult],
    summary="Verify the tamper-evident hash chain (Rescue Team / Admin)",
    responses=error_responses(401, 403),
)
async def verify(_: RescuerUser, session: DbSession) -> ApiResponse[AuditVerifyResult]:
    """Recomputes every entry's SHA-256 hash and checks each link to the
    previous entry and the stored chain head. `valid: false` names the first
    entry that was modified, deleted or reordered.

    This is a tamper-evident hash chain inside this server's database, not a
    decentralized blockchain network."""
    result = await audit_service.verify_chain(session)
    return ApiResponse(
        data=AuditVerifyResult(**result, verified_at=utcnow()),
        message="Audit chain intact." if result["valid"] else "Audit chain BROKEN.",
    )
