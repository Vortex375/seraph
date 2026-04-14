# Agents React Chat UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the debug chat SPA in `agents/ui` with a production-grade React/Vite app and extend the chat API so the sidebar can show session status, headline, preview, and delete actions.

**Architecture:** Keep FastAPI as the same-origin host for both JSON/SSE chat endpoints and static assets. Move session-summary logic into `chat/session_service.py`, add a delete endpoint in `api/chat.py`, and swap the `esbuild` frontend for a React/Vite app that consumes the existing API plus the new session metadata.

**Tech Stack:** FastAPI, SQLAlchemy async, AgentScope SQLAlchemy memory, React, Vite, TypeScript, Vitest

---

### Task 1: Extend chat session summaries and deletion in the backend

**Files:**
- Modify: `agents/api/models.py`
- Modify: `agents/chat/session_service.py`
- Modify: `agents/api/chat.py`
- Test: `agents/tests/test_chat_api.py`
- Test: `agents/tests/test_session_service.py`

- [ ] Write failing tests for enriched session summaries, auto-generated headlines, and session deletion.
- [ ] Run the targeted Python tests and confirm they fail for the expected missing fields or routes.
- [ ] Implement summary aggregation, default titles, first-message headline promotion, and delete behavior.
- [ ] Re-run the targeted Python tests and confirm they pass.

### Task 2: Replace the debug UI toolchain with React/Vite

**Files:**
- Modify: `agents/ui/package.json`
- Create: `agents/ui/vite.config.ts`
- Modify: `agents/ui/index.html`
- Modify: `agents/app/main.py`
- Test: `agents/tests/test_ui_static.py`

- [ ] Write failing static-serving tests for the Vite-built app.
- [ ] Run the static-serving test and confirm it fails against the old bundle assumptions.
- [ ] Implement the Vite build configuration and FastAPI static serving adjustments.
- [ ] Build the UI and re-run the static-serving test until it passes.

### Task 3: Build the React split-pane chat application

**Files:**
- Replace: `agents/ui/src/main.ts`
- Replace: `agents/ui/src/api.ts`
- Create: `agents/ui/src/App.tsx`
- Create: `agents/ui/src/styles.css`
- Test: `agents/ui/src/app.test.tsx`
- Delete: `agents/ui/src/app.ts`
- Delete: `agents/ui/tests/app.test.mjs`

- [ ] Write failing frontend tests for the session sidebar, delete action, transcript bubbles, citations, and streaming refresh behavior.
- [ ] Run the frontend test suite and confirm the new tests fail.
- [ ] Implement the React app and styling with minimal stateful components.
- [ ] Re-run the frontend tests until they pass.

### Task 4: Verify end-to-end build and targeted regressions

**Files:**
- No code changes required unless verification finds issues.

- [ ] Run the targeted Python backend tests covering chat API, session service, chat streaming, and static serving.
- [ ] Run the frontend test suite.
- [ ] Run the frontend production build.
- [ ] Fix any failures and repeat verification until the results are clean.
