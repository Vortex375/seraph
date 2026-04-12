from io import BytesIO

from pypdf import PdfReader


def extract_text(payload: bytes, mime: str) -> str:
    if mime == "application/pdf":
        reader = PdfReader(BytesIO(payload))
        return "\n".join(page.extract_text() or "" for page in reader.pages).strip()
    return payload.decode("utf-8", errors="replace")
