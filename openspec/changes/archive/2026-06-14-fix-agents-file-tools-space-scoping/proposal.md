## Why

The agent's file tools (`list_directory`, `stat_file`, and `read_file_excerpt`) are incorrectly denying access to files that should be within the user's accessible spaces. `search_files` and `search_knowledge_base` already return correctly scoped results, so the access-control model itself is sound, but the path-authorization logic used by the direct file tools is inconsistent and rejects valid paths. This breaks the agent's ability to inspect or read files it should legitimately be able to access.

## What Changes

- Fix path normalization and prefix matching in the agent file-access layer so that scoped paths are consistently allowed.
- Ensure `list_directory`, `stat_file`, and `read_file_excerpt` use the same authorization rules as `search_files`.
- Add regression tests covering the reported failure case and other common path forms (root scope, nested scope, trailing slashes, exact prefix match).
- Update existing tests if their expectations were based on the buggy behavior.

## Capabilities

### New Capabilities
- `agent-file-tool-space-scoping`: Consistent space-aware authorization for all agent file tools.

### Modified Capabilities
- (none)

## Impact

- Affected code: `agents/chat/file_access.py`, `agents/spaces/access.py`, `agents/tests/test_file_access.py`, and possibly `agents/tests/test_spaces_access.py`.
- No API or schema changes; purely a bugfix in authorization logic.
- Backend services (spaces, file-indexer) are unchanged.
