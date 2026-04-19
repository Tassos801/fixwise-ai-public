from __future__ import annotations

import unittest

import test_support  # noqa: F401
from fixwise_backend.models import AIResponse, TaskChecklistItem, TaskState
from fixwise_backend.pc_setup_brain import enrich_pc_setup_response


class PCSetupBrainTests(unittest.TestCase):
    def test_machines_prompt_gets_fallback_display_setup_task_state(self):
        response = AIResponse(
            text="Use the HDMI or DisplayPort output on the graphics card.",
            annotations=[],
            nextAction="Connect the monitor cable to the graphics card, not the motherboard.",
            confidence="medium",
        )

        enriched = enrich_pc_setup_response(
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

    def test_non_machines_prompt_keeps_response_unchanged(self):
        response = AIResponse(text="Keep the camera steady.", annotations=[])

        enriched = enrich_pc_setup_response(
            response=response,
            prompt="What should I do next?",
            mode="general",
            existing_task_state=None,
        )

        self.assertIs(enriched, response)

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

        enriched = enrich_pc_setup_response(
            response=response,
            prompt="Is my RAM installed?",
            mode="machines",
            existing_task_state=None,
        )

        self.assertEqual(enriched.taskState.setupType, "pc_build")
        self.assertEqual(enriched.taskState.phase, "verify")


if __name__ == "__main__":
    unittest.main()
