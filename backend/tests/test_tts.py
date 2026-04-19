from __future__ import annotations

import asyncio
import base64
import unittest
from unittest.mock import patch

import httpx

import test_support  # noqa: F401
from fixwise_backend.config import Settings
from fixwise_backend.tts import generate_tts_audio_base64, get_tts_runtime_status


class TTSTests(unittest.TestCase):
    def _response(self, payload: dict) -> httpx.Response:
        return httpx.Response(
            200,
            json=payload,
            request=httpx.Request(
                "POST",
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent",
            ),
        )

    def test_generate_tts_wraps_transcript_and_retries_missing_audio(self):
        pcm_bytes = b"\x00\x00\x01\x00" * 16
        missing_audio = self._response({"candidates": [{"content": {"parts": [{"text": "oops"}]}}]})
        audio_response = self._response(
            {
                "candidates": [
                    {
                        "content": {
                            "parts": [
                                {
                                    "inlineData": {
                                        "mimeType": "audio/pcm",
                                        "data": base64.b64encode(pcm_bytes).decode("ascii"),
                                    }
                                }
                            ]
                        }
                    }
                ]
            }
        )

        settings = Settings(gemma_api_key="google-test-key")

        with patch("fixwise_backend.tts.httpx.AsyncClient") as async_client:
            post = async_client.return_value.__aenter__.return_value.post
            post.side_effect = [missing_audio, audio_response]

            audio = asyncio.run(
                generate_tts_audio_base64(
                    settings=settings,
                    text="Connect the HDMI cable to the GPU.",
                )
            )

        self.assertIsInstance(audio, str)
        self.assertTrue(base64.b64decode(audio).startswith(b"RIFF"))
        self.assertEqual(post.call_count, 2)
        request_json = post.call_args_list[0].kwargs["json"]
        prompt = request_json["contents"][0]["parts"][0]["text"]
        self.assertIn("Synthesize natural single-speaker speech", prompt)
        self.assertIn("TRANSCRIPT:", prompt)
        self.assertIn("Connect the HDMI cable to the GPU.", prompt)
        self.assertTrue(get_tts_runtime_status(settings)["ok"])

    def test_tts_runtime_status_does_not_expose_api_key(self):
        settings = Settings(gemma_api_key="google-test-key", gemini_tts_voice="Kore")

        status = get_tts_runtime_status(settings)

        self.assertTrue(status["enabled"])
        self.assertTrue(status["configured"])
        self.assertEqual(status["voice"], "Kore")
        self.assertNotIn("google-test-key", str(status))


if __name__ == "__main__":
    unittest.main()
