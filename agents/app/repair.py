import argparse
import asyncio
from dataclasses import dataclass

from fileprovider.nats_client import connect_nats_from_env
from ingestion.file_changed_consumer import FILE_CHANGED_STREAM, create_ingestion_service


@dataclass(frozen=True)
class BackfillResult:
    processed: int
    failed: int


async def backfill_documents_from_stream() -> BackfillResult:
    nc = await connect_nats_from_env()
    ingestion_service = create_ingestion_service()
    ingestion_service._nc = nc
    processed = 0
    failed = 0

    try:
        js = nc.jetstream()
        stream_info = await js.stream_info(FILE_CHANGED_STREAM)

        for seq in range(1, stream_info.state.last_seq + 1):
            msg = await js.get_msg(FILE_CHANGED_STREAM, seq=seq)
            try:
                outcome = await ingestion_service._handle_message(msg)
            except Exception:
                failed += 1
            else:
                if outcome == "indexed":
                    processed += 1
                elif outcome == "failed":
                    failed += 1
    finally:
        await nc.close()

    return BackfillResult(processed=processed, failed=failed)


async def _run_backfill_documents() -> int:
    result = await backfill_documents_from_stream()
    print(f"Backfill complete: processed={result.processed} failed={result.failed}")
    return 0 if result.failed == 0 else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Seraph agents repair commands")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("backfill-documents", help="Replay file-changed stream messages into canonical documents")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "backfill-documents":
        return asyncio.run(_run_backfill_documents())

    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
