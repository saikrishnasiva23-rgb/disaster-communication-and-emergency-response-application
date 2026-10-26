from __future__ import annotations

from app.domain.enums import PriorityLevel
from app.services.priority_service import (
    PriorityInput,
    PriorityOutput,
    PriorityService,
    RandomForestDemoClassifier,
    RuleBasedPriorityClassifier,
)

rules = RuleBasedPriorityClassifier()


def test_rules_escalate_with_risk_factors():
    minor = rules.classify(PriorityInput("OTHER", people_count=1))
    severe = rules.classify(PriorityInput("TRAPPED_PERSON", people_count=12, injured=True,
                                          trapped=True, severity=5))
    assert minor.priority == PriorityLevel.LOW
    assert severe.priority == PriorityLevel.CRITICAL
    assert 0 <= minor.score < severe.score <= 1
    assert "trapped" in severe.reason.lower()
    assert severe.factors


def test_rules_read_description_but_respect_negation():
    base = PriorityInput("MEDICAL", people_count=1)
    urgent = rules.classify(PriorityInput("MEDICAL", people_count=1, description="He is unconscious"))
    negated = rules.classify(PriorityInput("MEDICAL", people_count=1, description="not unconscious, talking"))
    assert urgent.priority.rank > rules.classify(base).priority.rank
    assert negated.priority == rules.classify(base).priority


def test_output_shape():
    result = rules.classify(PriorityInput("FLOOD", people_count=5, injured=True))
    assert isinstance(result, PriorityOutput)
    assert result.priority in set(PriorityLevel)
    assert isinstance(result.reason, str) and result.reason
    assert result.model == "rule_based_v1"


def test_demo_model_used_only_for_trained_types():
    service = PriorityService(model=RandomForestDemoClassifier())
    trained = service.classify_sync(PriorityInput("FIRE", people_count=3, injured=True))
    untrained = service.classify_sync(PriorityInput("EARTHQUAKE", people_count=3, injured=True))
    assert trained.model.startswith("random_forest_demo_v1")
    assert untrained.model == "rule_based_v1"
    assert "No trained model covers" in untrained.reason


class _FakeModel:
    name = "fake_model"
    available = True

    def __init__(self, level=PriorityLevel.LOW, fail=False):
        self.level, self.fail = level, fail

    def load(self):
        pass

    def supports(self, data):
        return True

    def classify(self, data):
        if self.fail:
            raise RuntimeError("model crashed")
        return PriorityOutput(self.level, 0.1, "fake", self.name, ["fake"])


def test_safety_floor_never_lets_the_model_downgrade_rules():
    service = PriorityService(model=_FakeModel(PriorityLevel.LOW))  # type: ignore[arg-type]
    result = service.classify_sync(PriorityInput("TRAPPED_PERSON", people_count=10, injured=True,
                                                 trapped=True, severity=5))
    assert result.priority == PriorityLevel.CRITICAL
    assert result.model == "fake_model+rule_based_v1" and "escalated" in result.reason


def test_model_failure_falls_back_to_rules():
    service = PriorityService(model=_FakeModel(fail=True))  # type: ignore[arg-type]
    result = service.classify_sync(PriorityInput("MEDICAL", people_count=2, injured=True))
    assert result.model == "rule_based_v1" and "fallback" in result.reason


def test_classify_endpoint(client, affected):
    response = client.post("/api/v1/priority/classify",
                           json={"emergency_type": "Flood Emergency", "people_count": 6,
                                 "injured": True, "environmental_risk": 0.8},
                           headers=affected.headers)
    assert response.status_code == 200
    data = response.json()["data"]
    assert set(data) >= {"priority", "score", "reason", "model"}
    info = client.get("/api/v1/priority/model", headers=affected.headers).json()["data"]
    assert "rule_based_v1" in info["classifier"]
    bad = client.post("/api/v1/priority/classify", json={"emergency_type": "FLOOD", "environmental_risk": 3},
                      headers=affected.headers)
    assert bad.status_code == 422
    assert client.post("/api/v1/priority/classify", json={"emergency_type": "FLOOD"}).status_code == 401


def test_negation_does_not_hide_other_threats():
    text = "Nobody is injured but we are trapped on the roof"
    result = rules.classify(PriorityInput("FLOOD", description=text))
    assert "life-threatening condition described" in result.factors


def test_scores_share_one_scale_across_classifiers():
    bands = {PriorityLevel.LOW: (0, 0.25), PriorityLevel.MEDIUM: (0.25, 0.5),
             PriorityLevel.HIGH: (0.5, 0.75), PriorityLevel.CRITICAL: (0.75, 1.0001)}
    service = PriorityService(model=RandomForestDemoClassifier())
    cases = [PriorityInput(t, people_count=n, injured=i, trapped=tr, severity=sv)
             for t in ("MEDICAL", "FIRE", "FLOOD", "TRAPPED_PERSON", "EARTHQUAKE", "OTHER")
             for n in (1, 4, 12) for i in (False, True) for tr in (False, True) for sv in (None, 5)]
    for data in cases:
        for result in (rules.classify(data), service.classify_sync(data)):
            low, high = bands[result.priority]
            assert low <= result.score < high, (data, result)
