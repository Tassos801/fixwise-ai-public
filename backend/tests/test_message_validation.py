from __future__ import annotations

import unittest

import test_support  # noqa: F401
from fixwise_backend.app import validate_message_payload
from fixwise_backend.models import EndSessionMessage, FrameMessage, PromptMessage


class MessageValidationTests(unittest.TestCase):
    def test_frame_message_validates(self):
        message = validate_message_payload(
            '{"type":"frame","sessionId":"session-1","timestamp":123.45,"frame":"ZmFrZS1qcGVn","frameMetadata":{"width":512,"height":512,"sceneDelta":0.12}}'
        )

        self.assertIsInstance(message, FrameMessage)
        self.assertEqual(message.frameMetadata.width, 512)

    def test_prompt_message_validates(self):
        message = validate_message_payload(
            '{"type":"prompt","sessionId":"session-1","timestamp":123.45,"text":"What should I do next?"}'
        )

        self.assertIsInstance(message, PromptMessage)
        self.assertEqual(message.mode, "general")

    def test_prompt_message_normalizes_mode(self):
        message = validate_message_payload(
            '{"type":"prompt","sessionId":"session-1","timestamp":123.45,"text":"What should I do next?","mode":"Car"}'
        )

        self.assertIsInstance(message, PromptMessage)
        self.assertEqual(message.mode, "car")

    def test_end_session_message_validates(self):
        message = validate_message_payload(
            '{"type":"end_session","sessionId":"session-1"}'
        )

        self.assertIsInstance(message, EndSessionMessage)

    def test_invalid_message_raises_value_error(self):
        with self.assertRaises(ValueError):
            validate_message_payload(
                '{"type":"frame","sessionId":"session-1","timestamp":123.45,"frameMetadata":{"width":512,"height":512,"sceneDelta":0.12}}'
            )

    def test_invalid_json_raises_value_error(self):
        with self.assertRaises(ValueError):
            validate_message_payload("not-json")


if __name__ == "__main__":
    unittest.main()
