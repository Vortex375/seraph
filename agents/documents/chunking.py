from dataclasses import dataclass


@dataclass(frozen=True)
class TextChunk:
    index: int
    text: str
    start_offset: int
    end_offset: int


def chunk_text(text: str, chunk_size: int = 1200, overlap: int = 150) -> list[TextChunk]:
    if not text:
        return []

    if chunk_size <= 0:
        raise ValueError("chunk_size must be positive")

    if overlap < 0:
        raise ValueError("overlap must be non-negative")

    chunks: list[TextChunk] = []
    start = 0
    index = 0
    while start < len(text):
        end = min(len(text), start + chunk_size)

        chunks.append(
            TextChunk(
                index=index,
                text=text[start:end],
                start_offset=start,
                end_offset=end,
            )
        )

        if end == len(text):
            break

        start = max(end - overlap, start + 1)
        index += 1

    return chunks
