from __future__ import annotations


SAFETY_BLOCKED_TOPICS = (
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


def check_safety(text: str) -> str | None:
    lower = text.lower()
    for topic in SAFETY_BLOCKED_TOPICS:
        if topic in lower:
            return (
                f"This request appears to involve {topic}, which FixWise will not guide "
                "because it can require licensed professional handling."
            )
    return None
