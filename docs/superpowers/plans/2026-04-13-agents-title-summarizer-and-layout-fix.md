# Agents Title Summarizer And Layout Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add real LLM-based session title generation for new conversations and fix the React chat layout so the composer is visible at the bottom of the page by default.

**Architecture:** Keep title generation in the backend service layer with a deterministic fallback so chat submission remains robust, and keep the layout fix localized to the React app CSS with no unnecessary component churn. AgentScope built-ins are not used because it does not provide session-title generation.

**Tech Stack:** FastAPI, Python, AgentScope, React, Vite, Vitest

---

### Task 1: Add backend title summarization with fallback

**Files:**
- Modify: `agents/chat/session_service.py`
- Modify: `agents/api/chat.py`
- Modify: `agents/app/main.py` if dependency plumbing is needed
- Test: `agents/tests/test_chat_api.py`
- Test: `agents/tests/test_session_service.py`

- [ ] Write failing backend tests for successful LLM title generation and fallback-to-truncation behavior.
- [ ] Run the targeted backend tests and confirm they fail for the expected missing summarizer behavior.
- [ ] Implement a minimal summarizer helper that uses the configured model and only runs when the title is still `New conversation`.
- [ ] Re-run the targeted backend tests until they pass.

### Task 2: Fix the conversation layout so the composer stays visible

**Files:**
- Modify: `agents/ui/src/styles.css`
- Test: `agents/ui/src/app.test.tsx`

- [ ] Write a failing frontend regression test asserting the layout classes or CSS expectations for fixed-height shell and shrinkable panes.
- [ ] Run the frontend tests and confirm the new regression fails.
- [ ] Implement the smallest CSS change that keeps the composer visible and the transcript scrollable.
- [ ] Re-run the frontend tests until they pass.

### Task 3: Verify the combined change set

**Files:**
- No code changes required unless verification finds issues.

- [ ] Run the targeted Python tests for chat API and session service.
- [ ] Run the frontend test suite.
- [ ] Run the frontend build.
- [ ] Fix any issues and repeat verification until the results are clean.
