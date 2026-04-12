# Durable Chat Citations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add durable assistant citations plus a reloadable full chat-history API and show citation file paths in the debugging SPA.

**Architecture:** Expose a new session-history read path in the FastAPI chat API that reconstructs visible conversation messages from persisted AgentScope memory rows and joins `chat_turn_sources` for assistant citations. Update the SPA to load that history on session selection and render assistant citations under the restored message text.

**Tech Stack:** FastAPI, SQLAlchemy async ORM, AgentScope message persistence tables, TypeScript SPA, node:test

---

### Task 1: Add History API Models And Read Path

**Files:**
- Modify: `agents/api/models.py`
- Modify: `agents/chat/session_service.py`
- Modify: `agents/api/chat.py`
- Test: `agents/tests/test_chat_api.py`

- [ ] **Step 1: Write the failing API history tests**

Add tests for:
- `GET /api/v1/chat/sessions/{session_id}/messages` returns ordered visible conversation messages
- assistant messages include `citations`
- retrieval helper messages are filtered out

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_chat_api.py -v -k messages`
Expected: FAIL because no messages endpoint/model exists yet.

- [ ] **Step 3: Add response models and session-service history query**

Implement compact chat-message response models in `agents/api/models.py` and a history loader in `agents/chat/session_service.py` that reads stored conversation rows and assistant citation rows.

- [ ] **Step 4: Add the messages endpoint**

Implement `GET /api/v1/chat/sessions/{session_id}/messages` in `agents/api/chat.py` using the new session-service history loader.

- [ ] **Step 5: Run tests to verify they pass**

Run: `uv run pytest tests/test_chat_api.py -v -k messages`
Expected: PASS.

### Task 2: Update SPA API Client And Rendering

**Files:**
- Modify: `agents/ui/src/api.ts`
- Modify: `agents/ui/src/app.ts`
- Test: `agents/ui/tests/app.test.mjs`

- [ ] **Step 1: Write the failing SPA tests**

Add tests for:
- selecting a session loads and renders full history
- assistant messages render citation file paths under the message text

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --test ui/tests/app.test.mjs`
Expected: FAIL because the SPA clears messages on selection and has no history fetch/citation rendering.

- [ ] **Step 3: Add history fetch client**

Extend `agents/ui/src/api.ts` with a typed history request.

- [ ] **Step 4: Update SPA session selection and rendering**

Make `agents/ui/src/app.ts` load full history on session click and render assistant citations as a simple file-path list beneath assistant messages.

- [ ] **Step 5: Run tests to verify they pass**

Run: `node --test ui/tests/app.test.mjs`
Expected: PASS.

### Task 3: Verify Integrated Behavior

**Files:**
- Modify: `agents/tests/test_chat_streaming.py` if needed for source-persistence coverage only
- Verify: `agents/api/chat.py`, `agents/chat/citations.py`, `agents/ui/src/app.ts`

- [ ] **Step 1: Run focused Python suite**

Run: `uv run pytest tests/test_chat_api.py tests/test_chat_streaming.py tests/test_seraph_knowledge.py -v`
Expected: PASS.

- [ ] **Step 2: Run SPA tests**

Run: `node --test ui/tests/app.test.mjs`
Expected: PASS.

- [ ] **Step 3: Rebuild live agents image and verify manually**

Run:

```bash
docker build --no-cache -t seraph-agents .
docker compose -f docker-compose.dev.yml up -d --force-recreate agents-api
docker exec -w /app agentscope-refactor-agents-api-1 uv run python -m app.repair backfill-documents
```

Expected: agents API is running and canonical documents exist.

- [ ] **Step 4: Verify history and citations through the live API**

Run a real session/message/stream flow, then call `GET /api/v1/chat/sessions/{session_id}/messages`.
Expected: returned assistant message includes citation file paths.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-04-12-durable-chat-citations-design.md docs/superpowers/plans/2026-04-12-durable-chat-citations.md agents/api/models.py agents/chat/session_service.py agents/api/chat.py agents/tests/test_chat_api.py agents/ui/src/api.ts agents/ui/src/app.ts agents/ui/tests/app.test.mjs
git commit -m "feat: add durable chat citations history"
```
