from __future__ import annotations

from .guidance_modes import normalize_guidance_mode
from .models import AIResponse, DetectedComponent, TaskChecklistItem, TaskState


def enrich_pc_setup_response(
    *,
    response: AIResponse,
    prompt: str,
    mode: str,
    existing_task_state: TaskState | None,
) -> AIResponse:
    """Attach a compact PC/device setup state for Machines & Tech sessions."""
    if normalize_guidance_mode(mode) != "machines":
        return response

    if response.taskState is not None:
        return response

    inferred = _infer_task_state(
        prompt=prompt,
        response_text=response.text,
        next_action=response.nextAction,
        existing_task_state=existing_task_state,
    )
    return response.model_copy(update={"taskState": inferred})


def _infer_task_state(
    *,
    prompt: str,
    response_text: str,
    next_action: str | None,
    existing_task_state: TaskState | None,
) -> TaskState:
    haystack = " ".join(
        part for part in (prompt, response_text, next_action or "") if part
    ).lower()

    focus = _troubleshooting_focus(haystack)
    setup_type = _setup_type(haystack, existing_task_state)
    if focus == "network_issue":
        setup_type = "network_setup"

    if focus is not None:
        phase = "troubleshoot"
    elif _contains_any(haystack, ("verify", "check", "test", "confirm", "detected")):
        phase = "verify"
    elif _contains_any(haystack, ("plug", "connect", "seat", "insert", "install", "cable")):
        phase = "connect"
    else:
        phase = existing_task_state.phase if existing_task_state else "identify"

    if existing_task_state and setup_type == "unknown" and focus is None:
        return existing_task_state

    return TaskState(
        setupType=setup_type,
        phase=phase,
        title=_title_for(setup_type, focus),
        checklist=_checklist_for(setup_type, phase, focus),
        visibleComponents=_visible_components(haystack),
        troubleshootingFocus=focus,
    )


def _setup_type(haystack: str, existing_task_state: TaskState | None) -> str:
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
    return existing_task_state.setupType if existing_task_state else "unknown"


def _troubleshooting_focus(haystack: str) -> str | None:
    if _contains_any(haystack, ("no display", "blank screen", "black screen", "no signal")):
        return "no_display"
    if _contains_any(haystack, ("won't turn on", "wont turn on", "no power", "dead pc")):
        return "no_power"
    if _contains_any(haystack, ("not detected", "not recognized", "not showing up")):
        return "not_detected"
    if _contains_any(haystack, ("no internet", "network not working", "router not working")):
        return "network_issue"
    return None


def _title_for(setup_type: str, focus: str | None) -> str:
    if focus == "no_display":
        return "Troubleshoot no display"
    if focus == "no_power":
        return "Troubleshoot no power"
    if focus == "not_detected":
        return "Troubleshoot device detection"
    if focus == "network_issue":
        return "Troubleshoot network setup"
    return {
        "display_setup": "Connect a display",
        "network_setup": "Connect network gear",
        "peripheral_setup": "Connect a device",
        "pc_build": "Build and verify PC setup",
    }.get(setup_type, "Machine setup")


def _checklist_for(
    setup_type: str,
    phase: str,
    focus: str | None,
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
    return _items(
        phase,
        [
            ("identify-part", "Identify the visible port, cable, or component"),
            ("choose-next-connection", "Choose the next safe connection step"),
            ("verify-result", "Verify the device responds correctly"),
        ],
    )


def _items(phase: str, items: list[tuple[str, str]]) -> list[TaskChecklistItem]:
    active_index = {
        "identify": 0,
        "connect": 1 if len(items) > 1 else 0,
        "verify": min(2, len(items) - 1),
        "troubleshoot": 0,
        "complete": len(items) - 1,
    }[phase]
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


def _visible_components(haystack: str) -> list[DetectedComponent]:
    components: list[DetectedComponent] = []
    if _contains_any(haystack, ("hdmi", "displayport")):
        components.append(
            DetectedComponent(
                label="HDMI/DisplayPort cable",
                kind="cable",
                confidence="medium",
            )
        )
    if "gpu" in haystack or "graphics card" in haystack:
        components.append(
            DetectedComponent(
                label="Graphics card output",
                kind="port",
                confidence="medium",
            )
        )
    if "usb-c" in haystack:
        components.append(DetectedComponent(label="USB-C port", kind="port", confidence="medium"))
    elif "usb" in haystack:
        components.append(DetectedComponent(label="USB port", kind="port", confidence="medium"))
    if "ethernet" in haystack:
        components.append(
            DetectedComponent(label="Ethernet cable or port", kind="cable", confidence="medium")
        )
    if "front panel" in haystack:
        components.append(
            DetectedComponent(label="Front-panel header", kind="header", confidence="low")
        )
    return components


def _contains_any(text: str, phrases: tuple[str, ...]) -> bool:
    return any(phrase in text for phrase in phrases)
