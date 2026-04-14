# Agents Title Summarizer And Layout Fix Design

**Date:** 2026-04-13

**Status:** Approved by standing user approval

## Goal

Replace the current first-message truncation logic with real LLM-based conversation title generation, preferring AgentScope built-ins if they exist, and fix the chat layout so the composer is visible at first render and remains anchored at the bottom of the conversation pane.

## Findings

- AgentScope does not provide built-in conversation or session title generation.
- AgentScope does provide memory compression and long-term memory summary features, but those are for memory context, not persisted chat titles.
- The chat composer bug is caused by CSS sizing: both the app shell and conversation pane use viewport `min-height`, which allows the grid row to grow taller than the screen and pushes the composer below the fold.

## Design

### Title Summarization

Seraph will implement its own LLM title summarizer in the agents backend.

- New helper code will live in the chat service layer rather than inside the API router.
- The summarizer will use the same configured chat model provider already used by the agent runtime.
- It will generate a short conversation title from the first user message.
- The generation prompt will explicitly ask for a concise headline, suitable for a session list item.
- If title generation fails, Seraph will fall back to the current deterministic truncation behavior so message acceptance never breaks.
- The title will still only be promoted when the session title is the default `New conversation`, preserving user-edited or previously stored titles.

### Layout Fix

The frontend fix is purely structural CSS.

- The app shell should use a fixed viewport height instead of a viewport minimum height.
- The sidebar and conversation pane should allow their internal scroll containers to shrink by setting `min-height: 0`.
- The conversation pane keeps a column layout where the transcript scrolls and the composer remains visible at the bottom.
- No markup change is required unless a test reveals a need for a wrapper element.

## Testing

- Python tests will verify that AgentScope built-ins are not relied on and that the backend stores an LLM-generated title when summarization succeeds.
- Python tests will verify fallback behavior when summarization fails.
- Frontend tests will verify the composer container class remains present and that the CSS sets a fixed-height shell plus shrinkable pane behavior.

## Non-Goals

- Renaming sessions after every turn.
- Generating titles from full transcript history.
- Adding client-side resize or draggable pane behavior.
