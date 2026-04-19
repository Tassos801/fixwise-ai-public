from __future__ import annotations

import unittest

import test_support  # noqa: F401
from fixwise_backend.models import AIResponse, DetectedComponent, TaskChecklistItem, TaskState
from fixwise_backend.task_brain import enrich_task_response


class TaskBrainTests(unittest.TestCase):
    def test_all_modes_get_fallback_task_state(self):
        cases = [
            ("general", "Which part should I focus on next?", "general_task"),
            ("home_repair", "The cabinet hinge screws are loose. What next?", "home_repair"),
            ("gardening", "These tomato leaves are yellowing. What should I do?", "plant_care"),
            ("gym", "How is my squat form and foot setup?", "exercise_form"),
            ("cooking", "Is this chicken ready to flip in the pan?", "cooking_task"),
            ("car", "Where do I connect the battery clamp?", "car_maintenance"),
            ("machines", "I am plugging HDMI into my GPU for a monitor. What next?", "display_setup"),
        ]

        for mode, prompt, expected_setup_type in cases:
            with self.subTest(mode=mode):
                response = AIResponse(
                    text="Focus on the visible target and do the next small step.",
                    annotations=[],
                    nextAction="Check the main visible item, then verify the result.",
                    confidence="medium",
                )

                enriched = enrich_task_response(
                    response=response,
                    prompt=prompt,
                    mode=mode,
                    existing_task_state=None,
                )

                self.assertIsNotNone(enriched.taskState)
                self.assertEqual(enriched.taskState.setupType, expected_setup_type)
                self.assertTrue(enriched.taskState.checklist)
                self.assertEqual(
                    sum(1 for item in enriched.taskState.checklist if item.status == "active"),
                    1,
                )

    def test_machines_prompt_gets_fallback_display_setup_task_state(self):
        response = AIResponse(
            text="Use the HDMI or DisplayPort output on the graphics card.",
            annotations=[],
            nextAction="Connect the monitor cable to the graphics card, not the motherboard.",
            confidence="medium",
        )

        enriched = enrich_task_response(
            response=response,
            prompt="I am plugging HDMI into my GPU for a monitor. What next?",
            mode="machines",
            existing_task_state=None,
        )

        self.assertIsNotNone(enriched.taskState)
        self.assertEqual(enriched.taskState.setupType, "display_setup")
        self.assertEqual(enriched.taskState.phase, "connect")
        self.assertTrue(
            any(item.status == "active" for item in enriched.taskState.checklist)
        )
        self.assertTrue(
            any(component.kind == "cable" for component in enriched.taskState.visibleComponents)
        )

    def test_general_prompt_gets_lightweight_task_state(self):
        response = AIResponse(text="Keep the camera steady.", annotations=[])

        enriched = enrich_task_response(
            response=response,
            prompt="What should I do next?",
            mode="general",
            existing_task_state=None,
        )

        self.assertIsNotNone(enriched.taskState)
        self.assertEqual(enriched.taskState.setupType, "general_task")
        self.assertEqual(enriched.taskState.phase, "identify")

    def test_mode_specific_focus_and_components_are_inferred(self):
        cases = [
            (
                "home_repair",
                "There is a leak under the sink at this valve.",
                "plumbing_repair",
                "repair_issue",
                "fixture",
            ),
            (
                "gardening",
                "These tomato leaves are yellow and the soil looks dry.",
                "plant_care",
                "plant_health",
                "plant",
            ),
            (
                "gym",
                "My knee hurts during this squat form check with a barbell.",
                "exercise_form",
                "form_risk",
                "body_position",
            ),
            (
                "cooking",
                "This chicken is still pink in the pan. Is it done?",
                "cooking_task",
                "doneness",
                "food",
            ),
            (
                "car",
                "The battery warning is on and I see the terminal clamp.",
                "car_maintenance",
                "diagnosis",
                "vehicle_part",
            ),
        ]

        for mode, prompt, expected_setup_type, expected_focus, expected_component in cases:
            with self.subTest(mode=mode):
                enriched = enrich_task_response(
                    response=AIResponse(
                        text="Check the visible item before taking the next step.",
                        annotations=[],
                    ),
                    prompt=prompt,
                    mode=mode,
                    existing_task_state=None,
                )

                self.assertEqual(enriched.taskState.setupType, expected_setup_type)
                self.assertEqual(enriched.taskState.troubleshootingFocus, expected_focus)
                self.assertTrue(
                    any(
                        component.kind == expected_component
                        for component in enriched.taskState.visibleComponents
                    )
                )

    def test_follow_up_preserves_existing_mode_specific_task_state(self):
        existing = TaskState(
            setupType="plumbing_repair",
            phase="act",
            title="Plumbing repair",
            checklist=[
                TaskChecklistItem(
                    id="adjust-or-repair",
                    title="Tighten the leaking valve",
                    status="active",
                )
            ],
            visibleComponents=[
                DetectedComponent(label="Plumbing valve", kind="fixture", confidence="medium")
            ],
            troubleshootingFocus="repair_issue",
        )

        enriched = enrich_task_response(
            response=AIResponse(text="Tighten the valve a quarter turn, then check for drips.", annotations=[]),
            prompt="What should I do next?",
            mode="home_repair",
            existing_task_state=existing,
        )

        self.assertEqual(enriched.taskState.setupType, "plumbing_repair")
        self.assertEqual(enriched.taskState.phase, "act")
        self.assertEqual(enriched.taskState.troubleshootingFocus, "repair_issue")

    def test_model_task_state_is_preserved(self):
        response = AIResponse(
            text="Seat the RAM in slot A2.",
            annotations=[],
            taskState=TaskState(
                setupType="pc_build",
                phase="verify",
                title="Verify memory installation",
                checklist=[
                    TaskChecklistItem(
                        id="seat-ram",
                        title="Seat RAM until both clips latch",
                        status="active",
                    )
                ],
            ),
        )

        enriched = enrich_task_response(
            response=response,
            prompt="Is my RAM installed?",
            mode="machines",
            existing_task_state=None,
        )

        self.assertEqual(enriched.taskState.setupType, "pc_build")
        self.assertEqual(enriched.taskState.phase, "verify")


if __name__ == "__main__":
    unittest.main()
