from __future__ import annotations

from dataclasses import dataclass


BLOCKED_TOPICS = (
    "breaker panel",
    "mains wiring",
    "240v",
    "high voltage",
    "gas line",
    "natural gas",
    "propane",
    "load-bearing wall",
    "structural support",
    "asbestos",
    "lead paint",
)


@dataclass(frozen=True)
class SafetyDecision:
    blocked: bool
    reason: str | None = None
    recommendation: str | None = None


def evaluate_prompt(text: str) -> SafetyDecision:
    normalized = text.lower()
    for topic in BLOCKED_TOPICS:
        if topic in normalized:
            return SafetyDecision(
                blocked=True,
                reason=(
                    f"This task appears to involve {topic}, which requires a licensed professional. "
                    "FixWise cannot guide this safely."
                ),
                recommendation="Contact a licensed professional for this kind of work.",
            )
    return SafetyDecision(blocked=False)
