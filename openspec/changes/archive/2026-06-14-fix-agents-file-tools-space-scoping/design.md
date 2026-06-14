## Context

The agents service exposes file tools to the LLM via `agents/chat/tools.py`. The actual access checks and file operations live in `agents/chat/file_access.py`, which relies on `agents/spaces/access.py` for path normalization and prefix matching. The spaces client (`agents/spaces/client.py`) fetches a user's accessible scopes from the Go `spaces` microservice over NATS.

Currently, `search_files` and `search_knowledge_base` return correctly scoped results, but `list_directory`, `stat_file`, and `read_file_excerpt` raise `PermissionError` for paths that are clearly inside an accessible scope. The reported example is `stat_file(path="/wallpaper/round_moons_nasa.jpg", provider_id="test")` returning "requested path is outside accessible scopes".

The bug appears to be in how `_authorize` in `file_access.py` compares the normalized request path against the scope prefix. The helper `_path_allowed` in `spaces/access.py` looks correct on its own, but the interaction between `_normalize_path`, the scope prefix stored by `SpacesClient`, and the comparison in `_authorize` may be inconsistent (for example, double normalization, trailing-slash handling, or a mismatch between a scope prefix and an exact file path).

## Goals / Non-Goals

**Goals:**
- Make `list_directory`, `stat_file`, and `read_file_excerpt` consistently allow paths that fall within the user's spaces.
- Keep `search_files` and `search_knowledge_base` behavior unchanged.
- Reject path-traversal and out-of-scope access attempts as before.
- Add regression tests that exercise the exact reported case and related edge cases.
- Keep the fix localized to the agents Python code; no changes to Go microservices.

**Non-Goals:**
- Redesigning the spaces permission model.
- Changing the file-provider protocol or NATS messages.
- Adding new agent tools.
- Performance optimization of search or file reads.

## Decisions

1. **Single source of truth for path normalization and prefix checks**
   - `spaces/access.py` already provides `_normalize_path` and `_path_allowed`. We will keep these as the canonical helpers and ensure every file tool uses them consistently.
   - Rationale: avoids divergent logic between search and direct file tools.

2. **Fix `_authorize` to avoid double-normalization and to handle exact-prefix matches correctly**
   - `_authorize` should normalize the request path once, fetch scopes, and compare each scope's `path_prefix` against the request path using `_path_allowed`.
   - Rationale: the current code re-normalizes the scope prefix inside the loop, which is harmless but masks the real comparison. We will simplify the logic so the intent is obvious and testable.

3. **Preserve existing error contract**
   - Out-of-scope paths continue to raise `PermissionError("requested path is outside accessible scopes")`.
   - Rationale: callers (tools and tests) depend on this message and exception type.

4. **Regression tests live next to existing tests**
   - Add cases to `agents/tests/test_file_access.py` and, if needed, `agents/tests/test_spaces_access.py`.
   - Rationale: keeps the test suite cohesive and makes the failure visible in the same module.

## Risks / Trade-offs

- [Risk] The reported failure could be caused by the spaces service returning an unexpected scope format rather than by the Python comparison logic. → Mitigation: reproduce against the running Docker dev stack and inspect the actual scopes returned for the test user before finalizing the fix.
- [Risk] Fixing the comparison could inadvertently allow paths that were previously correctly rejected (e.g., prefix boundary escapes like `/team-private` when scope is `/team`). → Mitigation: add explicit tests for boundary escapes and path traversal, and ensure `_path_allowed` keeps its strict prefix semantics.
- [Risk] Existing tests may encode the buggy behavior. → Mitigation: review all `test_file_access.py` assertions after the fix and update only tests that were asserting the bug.

## Migration Plan

No migration needed. This is a code-only bugfix. After merging, redeploy the `agents` service container.

## Open Questions

- What exact `path_prefix` does the spaces service return for the `test` provider in the reported example? (To be confirmed against the running dev stack during implementation.)
