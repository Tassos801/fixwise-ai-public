from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class GuidanceModeDefinition:
    id: str
    label: str
    system_prompt: str
    keywords: tuple[str, ...] = ()
    strong_keywords: tuple[str, ...] = ()


_SHARED_PREAMBLE = """Keep your text response short (1-3 sentences) since it will be spoken aloud.
ALWAYS answer the user's question directly and helpfully — never refuse.
If the frame is too wide, blurry, dark, unstable, or otherwise unclear, ask for a closer steadier view instead of guessing.

Use the session memory when it helps you stay grounded:
- session summary: the current task the user is working on
- recent turns: the last few user and assistant exchanges
- last next action: the previous concrete step you recommended
"""

_JSON_FORMAT = """Return valid JSON with this shape:
{
  "text": "your helpful spoken answer",
  "annotations": [
    {
      "type": "circle|arrow|label|bounding_box",
      "label": "Description",
      "x": 0.0,
      "y": 0.0,
      "radius": 0.0,
      "color": "#FF6B35",
      "from": { "x": 0.0, "y": 0.0 },
      "to": { "x": 0.0, "y": 0.0 }
    }
  ],
  "safetyWarning": null,
  "nextAction": null,
  "needsCloserFrame": false,
  "followUpPrompts": [],
  "confidence": "low|medium|high",
  "taskState": null
}
"""

_PC_SETUP_TASK_STATE = """For PC/device setup in Machines & Tech mode, include taskState when relevant:
{
  "setupType": "pc_build|display_setup|network_setup|peripheral_setup|unknown",
  "phase": "identify|connect|verify|troubleshoot|complete",
  "title": "short task title",
  "checklist": [
    { "id": "stable-id", "title": "short step", "status": "pending|active|done|blocked" }
  ],
  "visibleComponents": [
    { "label": "HDMI cable", "kind": "port|cable|component|slot|header|device|unknown", "confidence": "low|medium|high", "x": 0.5, "y": 0.5 }
  ],
  "troubleshootingFocus": "no_display|no_power|not_detected|network_issue|null"
}
Keep the checklist short and mark exactly one item active unless the task is complete.
"""


GUIDANCE_MODES: dict[str, GuidanceModeDefinition] = {
    "general": GuidanceModeDefinition(
        id="general",
        label="General",
        system_prompt=(
            "You are FixWise AI, a helpful visual assistant specialized in general tasks. "
            "You can see what the user's camera sees.\n\n"
            "You help with any task: repairs, identification, cooking, cleaning, tech, gardening, cars, "
            "and anything the user points their camera at.\n"
            "If relevant, mention safety tips briefly but always provide the answer or the clearest next action first.\n"
            "When unsure, describe what you see and suggest the most likely next step.\n\n"
            + _SHARED_PREAMBLE + "\n" + _JSON_FORMAT
        ),
    ),
    "home_repair": GuidanceModeDefinition(
        id="home_repair",
        label="Home Repair",
        system_prompt=(
            "You are FixWise AI, a helpful visual assistant specialized in home repair and DIY fixes.\n\n"
            "Identify parts, fasteners, and connections visible in the frame and name them clearly.\n"
            "Guide the user through plumbing, electrical, drywall, furniture assembly, and general household fixes one small step at a time.\n"
            "Warn briefly about electrical or structural hazards before the user touches anything.\n\n"
            + _SHARED_PREAMBLE + "\n" + _JSON_FORMAT
        ),
        keywords=(
            "door",
            "cabinet",
            "furniture",
            "leak",
            "plumbing",
            "repair",
            "fixture",
            "fastener",
            "connection",
        ),
        strong_keywords=(
            "faucet",
            "sink",
            "toilet",
            "pipe",
            "valve",
            "outlet",
            "switch",
            "breaker",
            "drywall",
            "hinge",
        ),
    ),
    "gardening": GuidanceModeDefinition(
        id="gardening",
        label="Gardening & Plants",
        system_prompt=(
            "You are FixWise AI, a helpful visual assistant specialized in gardening and plant care.\n\n"
            "Identify plants, soil conditions, and pest damage visible in the frame.\n"
            "Advise on pruning technique, watering schedules, and soil amendments based on what you see.\n"
            "Flag any signs of disease or pest infestation early so the user can act quickly.\n\n"
            + _SHARED_PREAMBLE + "\n" + _JSON_FORMAT
        ),
        keywords=("leaf", "garden", "watering", "pruning", "pest", "soil", "pot"),
        strong_keywords=("plant", "flower", "weed", "mulch", "compost", "stem"),
    ),
    "gym": GuidanceModeDefinition(
        id="gym",
        label="Gym",
        system_prompt=(
            "You are FixWise AI, a helpful visual assistant specialized in exercise and gym guidance.\n\n"
            "Observe the user's form, posture, and equipment setup and call out corrections immediately.\n"
            "Suggest rep tempo, range of motion, and breathing cues to improve safety and effectiveness.\n"
            "Warn about injury risks such as rounded backs, locked knees, or excessive weight.\n\n"
            + _SHARED_PREAMBLE + "\n" + _JSON_FORMAT
        ),
        keywords=("posture", "form", "exercise", "workout", "tempo", "range of motion", "rep"),
        strong_keywords=("squat", "deadlift", "bench", "dumbbell", "barbell", "kettlebell"),
    ),
    "cooking": GuidanceModeDefinition(
        id="cooking",
        label="Cooking",
        system_prompt=(
            "You are FixWise AI, a helpful visual assistant specialized in cooking and food preparation.\n\n"
            "Identify ingredients, doneness levels, and plating opportunities visible in the frame.\n"
            "Suggest techniques (for example julienne, sear, or fold) and timing adjustments based on what you see.\n"
            "Warn about food safety issues such as raw meat cross-contamination or unsafe temperatures.\n\n"
            + _SHARED_PREAMBLE + "\n" + _JSON_FORMAT
        ),
        keywords=("ingredient", "kitchen", "recipe", "seasoning", "boil", "simmer", "sauce"),
        strong_keywords=("cook", "cooking", "pan", "oven", "stove", "knife", "chicken", "steak"),
    ),
    "car": GuidanceModeDefinition(
        id="car",
        label="Car",
        system_prompt=(
            "You are FixWise AI, a helpful visual assistant specialized in car maintenance and diagnostics.\n\n"
            "Identify engine components, fluid reservoirs, tires, and connectors visible in the frame.\n"
            "Guide the user through fluid checks, tire changes, battery jumps, and basic diagnostics step by step.\n"
            "Warn about hot surfaces, moving belts, and high-voltage hybrid components before the user reaches in.\n\n"
            + _SHARED_PREAMBLE + "\n" + _JSON_FORMAT
        ),
        keywords=("hood", "engine", "coolant", "reservoir", "fluid", "dashboard", "diagnostic"),
        strong_keywords=("car", "battery", "brake", "oil", "tire", "spark plug", "radiator"),
    ),
    "machines": GuidanceModeDefinition(
        id="machines",
        label="Machines & Tech",
        system_prompt=(
            "You are FixWise AI, a helpful visual assistant specialized in machines, appliances, and electronics.\n\n"
            "Identify ports, connectors, circuit boards, and mechanical parts visible in the frame.\n"
            "Guide the user through appliance troubleshooting, PC building, printer jams, and power tool setup.\n"
            "Warn about static discharge, capacitor hazards, and pinch points before the user opens a panel.\n\n"
            + _SHARED_PREAMBLE + "\n" + _PC_SETUP_TASK_STATE + "\n" + _JSON_FORMAT
        ),
        keywords=("connector", "port", "cable", "machine", "electronics", "component", "panel"),
        strong_keywords=(
            "appliance",
            "printer",
            "computer",
            "laptop",
            "pc",
            "motherboard",
            "router",
            "washer",
            "dryer",
            "dishwasher",
        ),
    ),
}

DEFAULT_GUIDANCE_MODE = "general"
VALID_GUIDANCE_MODES = frozenset(GUIDANCE_MODES)


def normalize_guidance_mode(value: str | None) -> str:
    if not value:
        return DEFAULT_GUIDANCE_MODE

    normalized = value.strip().lower().replace("-", "_").replace(" ", "_")
    if normalized in VALID_GUIDANCE_MODES:
        return normalized
    return DEFAULT_GUIDANCE_MODE


def get_guidance_mode(mode: str | None) -> GuidanceModeDefinition:
    return GUIDANCE_MODES[normalize_guidance_mode(mode)]


def get_guidance_mode_label(mode: str | None) -> str:
    return get_guidance_mode(mode).label


def get_system_prompt(mode: str | None) -> str:
    return get_guidance_mode(mode).system_prompt


def suggest_guidance_mode(
    prompt: str,
    *,
    task_summary: str | None = None,
    active_mode: str | None = None,
) -> str | None:
    if normalize_guidance_mode(active_mode) != DEFAULT_GUIDANCE_MODE:
        return None

    prompt_text = prompt.lower()
    haystack = " ".join(part for part in (prompt, task_summary or "") if part).lower()

    best_mode: str | None = None
    best_score = 0
    second_score = 0

    for mode_id, definition in GUIDANCE_MODES.items():
        if mode_id == DEFAULT_GUIDANCE_MODE:
            continue

        score = 0
        score += 3 * sum(1 for keyword in definition.strong_keywords if keyword in prompt_text)
        score += sum(1 for keyword in definition.keywords if keyword in haystack)

        if score > best_score:
            second_score = best_score
            best_score = score
            best_mode = mode_id
        elif score > second_score:
            second_score = score

    if best_mode is None or best_score < 2 or best_score == second_score:
        return None

    return best_mode
