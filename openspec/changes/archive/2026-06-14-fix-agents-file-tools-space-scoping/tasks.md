## 1. Reproduce and inspect

- [x] 1.1 Confirm the running dev stack is reachable and the reported `stat_file` call still fails with the same error.
- [x] 1.2 Inspect the scopes returned by the spaces service for the test user/provider to understand the exact `path_prefix` values in play.

## 2. Fix authorization logic

- [x] 2.1 Update `agents/chat/file_access.py` `_authorize` to normalize the request path once and compare it against each scope using `_path_allowed` from `agents/spaces/access.py`.
- [x] 2.2 Ensure `list_directory`, `stat_file`, and `read_file_excerpt` all call the fixed `_authorize` and use the normalized path for subsequent file-provider calls.
- [x] 2.3 Verify `agents/spaces/access.py` `_normalize_path` and `_path_allowed` handle root scope (`/`), exact prefix, trailing slashes, and prefix-boundary escapes correctly; adjust only if a bug is found.

## 3. Add regression tests

- [x] 3.1 Add a test to `agents/tests/test_file_access.py` that reproduces the reported case: `stat_file(provider_id="test", path="/wallpaper/round_moons_nasa.jpg")` with scope `/wallpaper` succeeds.
- [x] 3.2 Add tests for `list_directory` and `read_file_excerpt` with nested scopes.
- [x] 3.3 Add tests for root scope, exact prefix match, trailing slash, relative path normalization, and prefix-boundary escape.
- [x] 3.4 Add or update tests in `agents/tests/test_spaces_access.py` if helper behavior changes.

## 4. Verify

- [x] 4.1 Run `uv run pytest agents/tests/test_file_access.py agents/tests/test_spaces_access.py` and ensure all tests pass.
- [x] 4.2 Run `uv run ruff check .` and fix any lint issues.
- [x] 4.3 Run `uv run mypy .` and fix any type issues.
- [x] 4.4 Run the full agents test suite (`uv run pytest`) and confirm no regressions.
