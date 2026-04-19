from __future__ import annotations

import base64
import io
import unittest

from PIL import Image

import test_support  # noqa: F401
from fixwise_backend.database import SessionRow, SessionStepRow
from fixwise_backend.pdf_report import generate_fix_report


def build_thumbnail_base64() -> str:
    image = Image.new("RGB", (1, 1), color=(255, 0, 0))
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG")
    return base64.b64encode(buffer.getvalue()).decode("ascii")


class PdfReportTests(unittest.TestCase):
    def test_generate_fix_report_embeds_full_thumbnail(self):
        session = SessionRow(
            id="session-1",
            user_id="user-1",
            status="completed",
            step_count=1,
            selected_mode="home_repair",
            started_at="2026-04-11T12:00:00Z",
            ended_at="2026-04-11T12:05:00Z",
            report_url=None,
        )
        steps = [
            SessionStepRow(
                id=1,
                session_id="session-1",
                step_number=1,
                frame_thumbnail=build_thumbnail_base64(),
                ai_response_text="Turn the valve slowly.",
                annotations_json=None,
                safety_warning=None,
                mode="home_repair",
                created_at="2026-04-11T12:01:00Z",
            )
        ]

        pdf_bytes = generate_fix_report(session, steps)

        self.assertTrue(pdf_bytes.startswith(b"%PDF"))
        self.assertIn(b"/Subtype /Image", pdf_bytes)


if __name__ == "__main__":
    unittest.main()
