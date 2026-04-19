from __future__ import annotations

from dataclasses import dataclass

from .guidance_modes import normalize_guidance_mode
from .models import AIResponse, DetectedComponent, TaskChecklistItem, TaskState


@dataclass(frozen=True)
class TaskProfile:
    setup_type: str
    title: str
    checklist: tuple[tuple[str, str], ...]


MODE_PROFILES: dict[str, TaskProfile] = {
    "general": TaskProfile(
        setup_type="general_task",
        title="General guidance",
        checklist=(
            ("identify-target", "Identify the visible target"),
            ("choose-next-step", "Choose the next safe step"),
            ("verify-result", "Verify the result"),
        ),
    ),
    "home_repair": TaskProfile(
        setup_type="home_repair",
        title="Home repair",
        checklist=(
            ("identify-fixture", "Identify the part, fastener, or connection"),
            ("make-area-safe", "Make the area safe before touching it"),
            ("adjust-or-repair", "Adjust, tighten, clean, or replace the issue"),
            ("verify-repair", "Verify the repair holds"),
        ),
    ),
    "gardening": TaskProfile(
        setup_type="plant_care",
        title="Plant care",
        checklist=(
            ("inspect-plant", "Inspect leaves, stems, soil, and light"),
            ("adjust-care", "Adjust water, light, soil, or pruning"),
            ("treat-issue", "Treat pests, disease, or stress if present"),
            ("monitor-recovery", "Monitor for recovery"),
        ),
    ),
    "gym": TaskProfile(
        setup_type="exercise_form",
        title="Exercise form",
        checklist=(
            ("check-setup", "Check stance, equipment, and starting position"),
            ("adjust-form", "Adjust posture and range of motion"),
            ("perform-controlled-rep", "Perform the movement under control"),
            ("verify-safety", "Stop or reduce load if form breaks down"),
        ),
    ),
    "cooking": TaskProfile(
        setup_type="cooking_task",
        title="Cooking guidance",
        checklist=(
            ("identify-food-state", "Identify ingredient, heat, and doneness"),
            ("adjust-technique", "Adjust heat, timing, seasoning, or cut"),
            ("cook-next-step", "Cook, flip, stir, cut, or plate the next step"),
            ("verify-food-safety", "Verify doneness and food safety"),
        ),
    ),
    "car": TaskProfile(
        setup_type="car_maintenance",
        title="Car maintenance",
        checklist=(
            ("make-vehicle-safe", "Park safely and avoid hot or moving parts"),
            ("identify-service-point", "Identify the fluid, connector, or part"),
            ("perform-check", "Check, connect, refill, replace, or reseat"),
            ("verify-vehicle-result", "Verify the warning, sound, leak, or reading"),
        ),
    ),
    "machines": TaskProfile(
        setup_type="machine_setup",
        title="Machine setup",
        checklist=(
            ("identify-part", "Identify the visible port, cable, or component"),
            ("choose-next-connection", "Choose the next safe connection step"),
            ("verify-result", "Verify the device responds correctly"),
        ),
    ),
}


def enrich_task_response(
    *,
    response: AIResponse,
    prompt: str,
    mode: str,
    existing_task_state: TaskState | None,
) -> AIResponse:
    """Attach compact mode-aware task state when the model did not provide one."""
    if response.taskState is not None:
        return response

    inferred = _infer_task_state(
        prompt=prompt,
        response_text=response.text,
        next_action=response.nextAction,
        mode=mode,
        existing_task_state=existing_task_state,
    )
    return response.model_copy(update={"taskState": inferred})


def _infer_task_state(
    *,
    prompt: str,
    response_text: str,
    next_action: str | None,
    mode: str,
    existing_task_state: TaskState | None,
) -> TaskState:
    normalized_mode = normalize_guidance_mode(mode)
    haystack = " ".join(
        part for part in (prompt, response_text, next_action or "") if part
    ).lower()

    setup_type = _setup_type(haystack, normalized_mode, existing_task_state)
    detected_focus = _troubleshooting_focus(haystack, normalized_mode)
    phase = _phase(haystack, detected_focus, setup_type, existing_task_state)
    focus = detected_focus
    if (
        focus is None
        and existing_task_state is not None
        and existing_task_state.setupType == setup_type
    ):
        focus = existing_task_state.troubleshootingFocus

    return TaskState(
        setupType=setup_type,
        phase=phase,
        title=_title_for(setup_type, focus, normalized_mode),
        checklist=_checklist_for(setup_type, phase, focus, normalized_mode),
        visibleComponents=_visible_components(haystack, normalized_mode),
        troubleshootingFocus=focus,
    )


def _setup_type(
    haystack: str,
    mode: str,
    existing_task_state: TaskState | None,
) -> str:
    if mode == "machines":
        if _contains_any(haystack, ("hdmi", "displayport", "monitor", "display", "gpu output")):
            return "display_setup"
        if _contains_any(haystack, ("ethernet", "router", "modem", "wan", "lan", "network")):
            return "network_setup"
        if _contains_any(haystack, ("keyboard", "mouse", "printer", "usb", "usb-c", "device")):
            return "peripheral_setup"
        if _contains_any(
            haystack,
            (
                "motherboard",
                "ram",
                "cpu",
                "gpu",
                "pcie",
                "psu",
                "front panel",
                "fan header",
                "sata",
                "m.2",
                "power supply",
            ),
        ):
            return "pc_build"

    if mode == "home_repair":
        if _contains_any(haystack, ("outlet", "switch", "breaker", "wire", "electrical")):
            return "electrical_repair"
        if _contains_any(haystack, ("leak", "pipe", "valve", "faucet", "sink", "toilet")):
            return "plumbing_repair"
        return "home_repair"
    if mode == "gardening":
        return "plant_care"
    if mode == "gym":
        return "exercise_form"
    if mode == "cooking":
        return "cooking_task"
    if mode == "car":
        return "car_maintenance"
    if mode == "general":
        return "general_task"

    return existing_task_state.setupType if existing_task_state else "unknown"


def _phase(
    haystack: str,
    focus: str | None,
    setup_type: str,
    existing_task_state: TaskState | None,
) -> str:
    if focus is not None:
        return "troubleshoot"
    if _contains_any(haystack, ("plug", "connect", "seat", "insert", "install", "cable", "clamp")):
        return "connect"
    if _contains_any(
        haystack,
        (
            "tighten",
            "loosen",
            "prune",
            "water",
            "flip",
            "stir",
            "season",
            "cut",
            "adjust",
            "refill",
            "replace",
            "clean",
        ),
    ):
        return "act"
    if _contains_any(haystack, ("done", "ready", "verify", "check", "test", "confirm", "detected", "safe")):
        return "verify"
    if existing_task_state and existing_task_state.setupType == setup_type:
        return existing_task_state.phase
    return "identify"


def _troubleshooting_focus(haystack: str, mode: str) -> str | None:
    if _contains_any(haystack, ("unsafe", "danger", "shock", "burn", "hot", "pain")):
        return "safety_check"
    if mode == "machines":
        if _contains_any(haystack, ("no display", "blank screen", "black screen", "no signal")):
            return "no_display"
        if _contains_any(haystack, ("won't turn on", "wont turn on", "no power", "dead pc")):
            return "no_power"
        if _contains_any(haystack, ("not detected", "not recognized", "not showing up")):
            return "not_detected"
        if _contains_any(haystack, ("no internet", "network not working", "router not working")):
            return "network_issue"
    if mode == "gardening" and _contains_any(haystack, ("yellow", "brown", "spots", "wilting", "pest", "disease")):
        return "plant_health"
    if mode == "gym" and _contains_any(haystack, ("pain", "rounded", "knee", "back", "injury", "form")):
        return "form_risk"
    if mode == "cooking" and _contains_any(haystack, ("raw", "done", "ready", "temperature", "temp", "pink")):
        return "doneness"
    if mode == "car" and _contains_any(haystack, ("warning", "leak", "dead", "won't start", "wont start")):
        return "diagnosis"
    if mode == "home_repair" and _contains_any(haystack, ("leak", "loose", "stuck", "broken", "cracked")):
        return "repair_issue"
    return None


def _title_for(setup_type: str, focus: str | None, mode: str) -> str:
    if focus == "no_display":
        return "Troubleshoot no display"
    if focus == "no_power":
        return "Troubleshoot no power"
    if focus == "not_detected":
        return "Troubleshoot device detection"
    if focus == "network_issue":
        return "Troubleshoot network setup"
    if focus == "plant_health":
        return "Check plant health"
    if focus == "form_risk":
        return "Correct exercise form"
    if focus == "doneness":
        return "Check cooking doneness"
    if focus == "diagnosis":
        return "Diagnose car issue"
    if focus == "repair_issue":
        return "Repair visible issue"
    if focus == "safety_check":
        return "Safety check"

    titles = {
        "general_task": "Guided task",
        "home_repair": "Home repair",
        "plumbing_repair": "Plumbing repair",
        "electrical_repair": "Electrical repair",
        "plant_care": "Plant care",
        "exercise_form": "Exercise form",
        "cooking_task": "Cooking guidance",
        "car_maintenance": "Car maintenance",
        "display_setup": "Connect a display",
        "network_setup": "Connect network gear",
        "peripheral_setup": "Connect a device",
        "pc_build": "Build and verify PC setup",
        "machine_setup": "Machine setup",
    }
    return titles.get(setup_type, MODE_PROFILES[mode].title)


def _checklist_for(
    setup_type: str,
    phase: str,
    focus: str | None,
    mode: str,
) -> list[TaskChecklistItem]:
    if focus == "no_display":
        return _items(
            phase,
            [
                ("check-display-cable", "Confirm the display cable is fully seated"),
                ("check-gpu-output", "Use the graphics card output if a GPU is installed"),
                ("check-monitor-input", "Set the monitor to the matching input"),
                ("reseat-gpu-ram", "Reseat GPU and RAM if there is still no signal"),
            ],
        )
    if focus == "no_power":
        return _items(
            phase,
            [
                ("check-psu-switch", "Confirm the PSU switch and wall power are on"),
                ("check-24pin", "Verify the 24-pin motherboard power connector"),
                ("check-cpu-power", "Verify CPU power near the top of the motherboard"),
                ("check-front-panel", "Check the case power-button header"),
            ],
        )
    if setup_type == "display_setup":
        return _items(
            phase,
            [
                ("identify-display-output", "Identify the GPU display output"),
                ("connect-display-cable", "Connect the monitor cable to the GPU"),
                ("verify-monitor-input", "Set monitor input and verify signal"),
            ],
        )
    if setup_type == "network_setup":
        return _items(
            phase,
            [
                ("identify-wan-lan", "Identify WAN and LAN ports"),
                ("connect-ethernet", "Connect Ethernet to the correct port"),
                ("verify-link-light", "Check link lights and internet status"),
            ],
        )
    if setup_type == "peripheral_setup":
        return _items(
            phase,
            [
                ("identify-device-port", "Identify the matching device port"),
                ("connect-device-cable", "Connect the device cable securely"),
                ("verify-detection", "Confirm the device is detected"),
            ],
        )
    if setup_type == "pc_build":
        return _items(
            phase,
            [
                ("power-off", "Power off and avoid touching live components"),
                ("seat-component", "Seat the visible component fully"),
                ("connect-power-data", "Connect required power or data cables"),
                ("verify-first-boot", "Verify first boot or device detection"),
            ],
        )
    return _items(phase, MODE_PROFILES[mode].checklist)


def _items(phase: str, items: tuple[tuple[str, str], ...] | list[tuple[str, str]]) -> list[TaskChecklistItem]:
    active_index = {
        "identify": 0,
        "inspect": 0,
        "prepare": 0,
        "connect": 1 if len(items) > 1 else 0,
        "act": 1 if len(items) > 1 else 0,
        "adjust": 1 if len(items) > 1 else 0,
        "verify": min(2, len(items) - 1),
        "troubleshoot": 0,
        "complete": len(items) - 1,
    }.get(phase, 0)
    result: list[TaskChecklistItem] = []
    for index, (item_id, title) in enumerate(items):
        if phase == "complete":
            status = "done"
        elif phase != "troubleshoot" and index < active_index:
            status = "done"
        elif index == active_index:
            status = "active"
        else:
            status = "pending"
        result.append(TaskChecklistItem(id=item_id, title=title, status=status))
    return result


def _visible_components(haystack: str, mode: str) -> list[DetectedComponent]:
    components: list[DetectedComponent] = []

    if _contains_any(haystack, ("hdmi", "displayport")):
        components.append(DetectedComponent(label="HDMI/DisplayPort cable", kind="cable", confidence="medium"))
    if "gpu" in haystack or "graphics card" in haystack:
        components.append(DetectedComponent(label="Graphics card output", kind="port", confidence="medium"))
    if "usb-c" in haystack:
        components.append(DetectedComponent(label="USB-C port", kind="port", confidence="medium"))
    elif "usb" in haystack:
        components.append(DetectedComponent(label="USB port", kind="port", confidence="medium"))
    if "ethernet" in haystack:
        components.append(DetectedComponent(label="Ethernet cable or port", kind="cable", confidence="medium"))
    if "front panel" in haystack:
        components.append(DetectedComponent(label="Front-panel header", kind="header", confidence="low"))

    mode_components: dict[str, tuple[tuple[tuple[str, ...], str, str], ...]] = {
        "home_repair": (
            (("hinge",), "Cabinet hinge", "fastener"),
            (("screw", "bolt"), "Fastener", "fastener"),
            (("pipe", "valve", "faucet"), "Plumbing part", "fixture"),
            (("outlet", "switch", "breaker"), "Electrical fixture", "fixture"),
        ),
        "gardening": (
            (("leaf", "leaves"), "Leaves", "plant"),
            (("soil",), "Soil", "soil"),
            (("stem", "branch"), "Stem or branch", "plant"),
        ),
        "gym": (
            (("squat", "knee", "foot", "feet"), "Lower-body alignment", "body_position"),
            (("back", "shoulder", "elbow"), "Upper-body alignment", "body_position"),
            (("dumbbell", "barbell", "kettlebell"), "Training equipment", "equipment"),
        ),
        "cooking": (
            (("chicken", "steak", "fish", "meat"), "Protein", "food"),
            (("pan", "pot", "skillet"), "Cookware", "equipment"),
            (("knife", "cut"), "Knife work", "tool"),
        ),
        "car": (
            (("battery", "clamp", "terminal"), "Battery terminal", "vehicle_part"),
            (("tire", "wheel"), "Wheel or tire", "vehicle_part"),
            (("oil", "coolant", "fluid"), "Fluid service point", "vehicle_part"),
        ),
    }
    for keywords, label, kind in mode_components.get(mode, ()):
        if _contains_any(haystack, keywords):
            components.append(DetectedComponent(label=label, kind=kind, confidence="medium"))

    return components


def _contains_any(text: str, phrases: tuple[str, ...]) -> bool:
    return any(phrase in text for phrase in phrases)
