import sys
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parents[1]))

from documents.chunking import chunk_text


def test_chunk_text_preserves_order_and_offsets() -> None:
    chunks = chunk_text("alpha beta gamma delta", chunk_size=10, overlap=2)

    assert [chunk.index for chunk in chunks] == [0, 1, 2]
    assert [(chunk.start_offset, chunk.end_offset) for chunk in chunks] == [(0, 10), (8, 18), (16, 22)]
    assert chunks[0].text == "alpha beta"
    assert chunks[-1].text.endswith("delta")
