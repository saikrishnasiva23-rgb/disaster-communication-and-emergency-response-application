"""Emergency priority classification behind one swappable interface.

Real implementations, and what they actually are:
* RandomForestDemoClassifier -- the project's existing scikit-learn
  RandomForest (backend/ai/priority_model.py). It is trained at startup on
  24 hand-labelled examples using only (people, injured, type) for four
  types. It is a demonstration model, not one trained on real incident
  data, and it is only used for the types it was trained on.
* RuleBasedPriorityClassifier -- transparent rules over every input field;
  the fallback for untrained types and whenever the model fails.

A future model (e.g. trained on real data) only needs `supports()` and
`classify()`; the API does not change."""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from typing import Protocol

from starlette.concurrency import run_in_threadpool

from app.domain import emergency_types
from app.domain.enums import PriorityLevel

logger = logging.getLogger("app.priority")


@dataclass(frozen=True)
class PriorityInput:
    emergency_type: str
    people_count: int = 1
    injured: bool = False
    trapped: bool = False
    severity: int | None = None
    description: str | None = None
    injury_details: str | None = None
    available_rescue_teams: int | None = None
    environmental_risk: float | None = None


@dataclass
class PriorityOutput:
    priority: PriorityLevel
    score: float
    reason: str
    model: str
    factors: list[str] = field(default_factory=list)


class PriorityClassifier(Protocol):
    name: str

    def supports(self, data: PriorityInput) -> bool: ...

    def classify(self, data: PriorityInput) -> PriorityOutput: ...


_LIFE_THREAT_WORDS = (
    "trapped", "unconscious", "not breathing", "stopped breathing", "no pulse",
    "bleeding", "drowning", "collapsed", "heart attack", "stroke", "seizure",
    "chest pain", "crushed", "buried", "burning", "severe burn",
)
_NEGATORS = ("not ", "no ", "isn't ", "without ", "never ", "no longer ")


def _mentions_threat(text: str) -> bool:
    """True if a life-threat phrase appears without a negation just before
    it ("not bleeding" does not count; "nobody injured but trapped" does)."""
    for phrase in _LIFE_THREAT_WORDS:
        for match in re.finditer(re.escape(phrase), text):
            before = text[max(0, match.start() - 12) : match.start()]
            if not any(before.endswith(neg) for neg in _NEGATORS):
                return True
    return False


class RuleBasedPriorityClassifier:
    name = "rule_based_v1"

    def supports(self, data: PriorityInput) -> bool:
        return True

    def classify(self, data: PriorityInput) -> PriorityOutput:
        points = 0
        factors: list[str] = []
        info = emergency_types.info(data.emergency_type)

        if info.life_threatening:
            points += 2
            factors.append(f"life-threatening emergency type ({info.label})")
        elif data.emergency_type == "MEDICAL":
            points += 1
            factors.append("medical emergency")

        if data.injured:
            points += 2
            factors.append("injured person reported")
        if data.trapped:
            points += 3
            factors.append("person trapped")

        if data.people_count >= 10:
            points += 3
            factors.append(f"{data.people_count} people affected")
        elif data.people_count >= 5:
            points += 2
            factors.append(f"{data.people_count} people affected")
        elif data.people_count >= 2:
            points += 1
            factors.append(f"{data.people_count} people affected")

        if data.severity:
            points += data.severity - 1
            factors.append(f"reported severity {data.severity}/5")

        text = f"{data.description or ''} {data.injury_details or ''}".lower()
        if _mentions_threat(text):
            points += 2
            factors.append("life-threatening condition described")

        if data.environmental_risk:
            bump = round(data.environmental_risk * 2)
            if bump:
                points += bump
                factors.append(f"environmental risk {data.environmental_risk:.2f}")

        if data.available_rescue_teams == 0:
            points += 1
            factors.append("no rescue teams currently available")

        if points >= 9:
            level = PriorityLevel.CRITICAL
        elif points >= 6:
            level = PriorityLevel.HIGH
        elif points >= 3:
            level = PriorityLevel.MEDIUM
        else:
            level = PriorityLevel.LOW
            if not factors:
                factors.append("no high-risk factors reported")

        return PriorityOutput(
            priority=level,
            score=round(min(1.0, points / 12), 3),
            reason="Rule-based assessment: " + "; ".join(factors),
            model=self.name,
            factors=factors,
        )


class RandomForestDemoClassifier:
    name = "random_forest_demo_v1"

    # The only types (and label strings) the model was trained on.
    TRAINED_TYPES = {
        "MEDICAL": "Medical Emergency",
        "FIRE": "Fire Emergency",
        "FLOOD": "Flood Emergency",
        "TRAPPED_PERSON": "Trapped Person",
    }

    def __init__(self) -> None:
        self._predict = None
        self.load_error: str | None = None
        self.load_attempted = False

    def load(self) -> None:
        self.load_attempted = True
        try:
            from ai.priority_model import predict_priority  # trains the model

            self._predict = predict_priority
            self.load_error = None
        except Exception as exc:  # scikit-learn/pandas missing or failing
            self._predict = None
            self.load_error = f"{type(exc).__name__}: {exc}"
            logger.warning("priority_model_unavailable", extra={"error": self.load_error})

    @property
    def available(self) -> bool:
        return self._predict is not None

    def supports(self, data: PriorityInput) -> bool:
        return self.available and data.emergency_type in self.TRAINED_TYPES

    def classify(self, data: PriorityInput) -> PriorityOutput:
        assert self._predict is not None
        result = self._predict(
            people=data.people_count,
            injured="Yes" if data.injured else "No",
            emergency_type=self.TRAINED_TYPES[data.emergency_type],
        )
        level = PriorityLevel(str(result["priority"]).upper())
        share = float(result["confidence"]) / 100
        return PriorityOutput(
            priority=level,
            # Same urgency scale as the rules: each level owns a quarter of
            # 0..1 (LOW <0.25 ... CRITICAL >=0.75); confidence places it
            # within the band, so scores stay comparable across classifiers.
            score=round(min(1.0, (level.rank - 1 + share) / 4), 3),
            reason=(
                f"Demo RandomForest (24 hand-labelled examples; inputs: people, "
                f"injured, type) predicted {level} with {share:.0%} of trees agreeing."
            ),
            model=self.name,
            factors=[
                f"people={data.people_count}",
                f"injured={'yes' if data.injured else 'no'}",
                f"type={data.emergency_type}",
            ],
        )


class PriorityService:
    def __init__(
        self,
        model: RandomForestDemoClassifier | None = None,
        rules: RuleBasedPriorityClassifier | None = None,
    ) -> None:
        self.model = model
        self.rules = rules or RuleBasedPriorityClassifier()

    async def warm_up(self) -> None:
        if self.model is not None:
            await run_in_threadpool(self.model.load)

    async def classify(self, data: PriorityInput) -> PriorityOutput:
        return await run_in_threadpool(self.classify_sync, data)

    def classify_sync(self, data: PriorityInput) -> PriorityOutput:
        if self.model is not None and not getattr(self.model, "load_attempted", True):
            self.model.load()  # normally done once by warm_up() at startup
        rule_result = self.rules.classify(data)

        if self.model is None or not self.model.supports(data):
            if self.model is not None and self.model.available:
                rule_result.reason = (
                    "No trained model covers this emergency type. " + rule_result.reason
                )
            return rule_result

        try:
            model_result = self.model.classify(data)
        except Exception as exc:
            logger.exception("priority_model_failed")
            rule_result.reason = (
                f"Model failed ({type(exc).__name__}); rule-based fallback. "
                + rule_result.reason
            )
            return rule_result

        # Safety floor: the demo model ignores trapped/severity/description,
        # so it may never *lower* what the transparent rules conclude.
        if rule_result.priority.rank > model_result.priority.rank:
            return PriorityOutput(
                priority=rule_result.priority,
                score=max(rule_result.score, model_result.score),
                reason=(
                    f"Demo RandomForest predicted {model_result.priority}; escalated to "
                    f"{rule_result.priority} by safety rules. {rule_result.reason}"
                ),
                model=f"{model_result.model}+{rule_result.model}",
                factors=model_result.factors + rule_result.factors,
            )
        return model_result

    def describe(self) -> dict[str, str]:
        if self.model is None:
            return {"classifier": "rule_based_v1", "model": "not_configured"}
        return {
            "classifier": "random_forest_demo_v1 + rule_based_v1",
            "model": "loaded" if self.model.available else "unavailable (rule-based only)",
        }
