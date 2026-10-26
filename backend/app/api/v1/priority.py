from __future__ import annotations

from fastapi import APIRouter

from app.api.deps import CurrentUser, PriorityDep
from app.schemas.common import ApiResponse, error_responses
from app.schemas.priority import PriorityRequest, PriorityResult
from app.services.priority_service import PriorityInput

router = APIRouter(prefix="/priority", tags=["Priority"])


@router.post(
    "/classify",
    response_model=ApiResponse[PriorityResult],
    summary="Classify an emergency's priority without saving anything",
    responses=error_responses(401, 422),
)
async def classify(
    body: PriorityRequest, _: CurrentUser, priority: PriorityDep
) -> ApiResponse[PriorityResult]:
    """Returns `{priority, score, reason, model}`. `model` says which
    classifier answered -- see `GET /priority/model` for what each one is."""
    result = await priority.classify(
        PriorityInput(
            emergency_type=body.emergency_type,
            people_count=body.people_count,
            injured=body.injured,
            trapped=body.trapped,
            severity=body.severity,
            description=body.description,
            injury_details=body.injury_details,
            available_rescue_teams=body.available_rescue_teams,
            environmental_risk=body.environmental_risk,
        )
    )
    return ApiResponse(
        data=PriorityResult(
            priority=result.priority, score=result.score, reason=result.reason,
            model=result.model, factors=result.factors,
        )
    )


@router.get(
    "/model",
    response_model=ApiResponse[dict[str, str]],
    summary="Which priority classifiers are active",
)
async def model_info(_: CurrentUser, priority: PriorityDep) -> ApiResponse[dict[str, str]]:
    return ApiResponse(data=priority.describe())
