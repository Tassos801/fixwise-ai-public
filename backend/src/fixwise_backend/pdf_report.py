"""
PDF Fix Report generator.
Compiles session steps (frames + AI guidance) into a downloadable PDF report.
Uses reportlab for lightweight PDF generation without system dependencies.
"""
from __future__ import annotations

import base64
import io
import logging
from datetime import UTC, datetime
from pathlib import Path
from re import sub

from .database import SessionRow, SessionStepRow


logger = logging.getLogger("fixwise.pdf")


def _decode_thumbnail(frame_thumbnail: str) -> bytes:
    """Decode a stored thumbnail, accepting either raw base64 or a data URI."""
    normalized = frame_thumbnail.strip()
    if normalized.startswith("data:") and "," in normalized:
        normalized = normalized.split(",", 1)[1]

    # Remove whitespace that may have been introduced by transport or storage.
    normalized = sub(r"\s+", "", normalized)
    return base64.b64decode(normalized, validate=False)


def generate_fix_report(
    session: SessionRow,
    steps: list[SessionStepRow],
    output_path: Path | None = None,
) -> bytes:
    """
    Generate a PDF fix report for a completed session.
    Returns the PDF as bytes. Optionally writes to output_path.
    """
    try:
        from reportlab.lib.pagesizes import letter
        from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
        from reportlab.lib.units import inch
        from reportlab.lib.colors import HexColor
        from reportlab.platypus import (
            SimpleDocTemplate,
            Paragraph,
            Spacer,
            Table,
            TableStyle,
            Image,
            HRFlowable,
        )
    except ImportError:
        logger.warning("reportlab not installed. Generating plain text fallback.")
        return _generate_text_fallback(session, steps)

    buffer = io.BytesIO()
    doc = SimpleDocTemplate(
        buffer,
        pagesize=letter,
        rightMargin=0.75 * inch,
        leftMargin=0.75 * inch,
        topMargin=0.75 * inch,
        bottomMargin=0.75 * inch,
    )

    styles = getSampleStyleSheet()

    # Custom styles
    title_style = ParagraphStyle(
        "FixWiseTitle",
        parent=styles["Title"],
        fontSize=24,
        textColor=HexColor("#1a1a2e"),
        spaceAfter=6,
    )
    subtitle_style = ParagraphStyle(
        "FixWiseSubtitle",
        parent=styles["Normal"],
        fontSize=11,
        textColor=HexColor("#666666"),
        spaceAfter=20,
    )
    step_header_style = ParagraphStyle(
        "StepHeader",
        parent=styles["Heading2"],
        fontSize=14,
        textColor=HexColor("#FF6B35"),
        spaceBefore=16,
        spaceAfter=8,
    )
    body_style = ParagraphStyle(
        "StepBody",
        parent=styles["Normal"],
        fontSize=11,
        textColor=HexColor("#333333"),
        spaceAfter=8,
        leading=15,
    )
    warning_style = ParagraphStyle(
        "Warning",
        parent=styles["Normal"],
        fontSize=10,
        textColor=HexColor("#cc0000"),
        backColor=HexColor("#fff3f3"),
        borderPadding=8,
        spaceAfter=8,
    )
    disclaimer_style = ParagraphStyle(
        "Disclaimer",
        parent=styles["Normal"],
        fontSize=8,
        textColor=HexColor("#999999"),
        spaceBefore=20,
    )

    elements: list = []

    # ── Header ──
    elements.append(Paragraph("FixWise AI - Fix Report", title_style))

    started = session.started_at[:19] if session.started_at else "Unknown"
    ended = session.ended_at[:19] if session.ended_at else "In progress"
    elements.append(Paragraph(
        f"Session: {session.id[:8]}... &nbsp;|&nbsp; "
        f"Started: {started} &nbsp;|&nbsp; "
        f"Ended: {ended} &nbsp;|&nbsp; "
        f"Steps: {session.step_count}",
        subtitle_style,
    ))

    elements.append(HRFlowable(width="100%", thickness=1, color=HexColor("#e0e0e0")))
    elements.append(Spacer(1, 12))

    # ── Steps ──
    if not steps:
        elements.append(Paragraph("No steps were recorded for this session.", body_style))
    else:
        for step in steps:
            elements.append(Paragraph(f"Step {step.step_number}", step_header_style))

            # Frame thumbnail (if available)
            if step.frame_thumbnail:
                try:
                    img_data = _decode_thumbnail(step.frame_thumbnail)
                    img_buffer = io.BytesIO(img_data)
                    img = Image(img_buffer, width=3 * inch, height=3 * inch)
                    img.hAlign = "LEFT"
                    elements.append(img)
                    elements.append(Spacer(1, 8))
                except Exception:
                    pass  # Skip corrupted thumbnails

            # AI guidance text
            elements.append(Paragraph(step.ai_response_text, body_style))

            # Safety warning
            if step.safety_warning:
                elements.append(Paragraph(
                    f"&#x26A0; Safety Warning: {step.safety_warning}",
                    warning_style,
                ))

            # Timestamp
            elements.append(Paragraph(
                f"<i>Recorded at: {step.created_at}</i>",
                ParagraphStyle("Timestamp", parent=styles["Normal"], fontSize=9, textColor=HexColor("#aaaaaa")),
            ))
            elements.append(Spacer(1, 8))

    # ── Footer / Disclaimer ──
    elements.append(Spacer(1, 24))
    elements.append(HRFlowable(width="100%", thickness=1, color=HexColor("#e0e0e0")))
    elements.append(Paragraph(
        "DISCLAIMER: FixWise AI provides general guidance only. It is not a substitute "
        "for a licensed professional. You assume all responsibility for actions taken "
        "based on AI guidance. Generated on " + datetime.now(UTC).strftime("%Y-%m-%d %H:%M UTC"),
        disclaimer_style,
    ))

    doc.build(elements)
    pdf_bytes = buffer.getvalue()

    if output_path:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(pdf_bytes)
        logger.info("Fix report written to %s (%d bytes)", output_path, len(pdf_bytes))

    return pdf_bytes


def _generate_text_fallback(session: SessionRow, steps: list[SessionStepRow]) -> bytes:
    """Plain text fallback when reportlab is not available."""
    lines = [
        "=" * 60,
        "FIXWISE AI - FIX REPORT",
        "=" * 60,
        f"Session: {session.id}",
        f"Started: {session.started_at}",
        f"Ended: {session.ended_at or 'In progress'}",
        f"Steps: {session.step_count}",
        "-" * 60,
        "",
    ]

    for step in steps:
        lines.append(f"--- Step {step.step_number} ---")
        lines.append(step.ai_response_text)
        if step.safety_warning:
            lines.append(f"  WARNING: {step.safety_warning}")
        lines.append(f"  Time: {step.created_at}")
        lines.append("")

    lines.append("-" * 60)
    lines.append(
        "DISCLAIMER: FixWise AI provides general guidance only. "
        "It is not a substitute for a licensed professional."
    )

    return "\n".join(lines).encode("utf-8")
