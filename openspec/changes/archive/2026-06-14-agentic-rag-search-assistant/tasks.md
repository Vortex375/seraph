## 1. Upgrade AgentScope to 2.0.1

- [x] 1.1 Pin `agentscope==2.0.1` in `agents/pyproject.toml` and `agents/requirements.txt`, regenerate `agents/uv.lock`, and install the new version.
- [x] 1.2 Fix import-level breakage in `agents/chat/agent_factory.py`, `agents/chat/streaming.py`, `agents/api/chat.py`, `agents/app/main.py`, and `agents/documents/models.py` caused by removed v1 APIs (`ReActAgent`, `AsyncSQLAlchemyMemory`, `KnowledgeBase`, `register_tool_function`, `stream_printing_messages`, `DeepSeekChatFormatter`).

## 2. Replace v1 Memory and Agent Lifecycle

- [x] 2.1 Add an `agent_state: Mapped[dict]` JSON column to `ChatSession` in `agents/documents/models.py`.
- [x] 2.2 Implement `agents/chat/agent_state_store.py` to load and save `AgentState` for a `(user_id, session_id)` pair.
- [x] 2.3 Remove `AsyncSQLAlchemyMemory` usage from `agents/chat/agent_factory.py` and `agents/api/chat.py`.
- [x] 2.4 Remove `agentscope.memory._working_memory._sqlalchemy_memory` table creation from `agents/app/main.py`.

## 3. Refactor Agent, Model, and Tools for AgentScope v2

- [x] 3.1 Replace `ReActAgent` with v2 `Agent` and use `reply_stream()` in `agents/chat/agent_factory.py` and `agents/chat/streaming.py`.
- [x] 3.2 Migrate `OpenAIChatModel` construction to use `OpenAICredential(api_key, base_url)` in both `agents/chat/agent_factory.py` and `agents/app/main.py`.
- [x] 3.3 Convert existing file-access tools (`search_files`, `list_directory`, `stat_file`, `read_file_excerpt`) from `register_tool_function` closures into `ToolBase` subclasses and wire them into `Toolkit(tools=[...])`.
- [x] 3.4 Implement `SearchKnowledgeBaseTool` as a v2 `ToolBase` tool that runs scoped semantic search and returns citation metadata.
- [x] 3.5 Ensure all read-only tools return `PermissionDecision(behavior=PermissionBehavior.ALLOW)` from `check_permissions()`.

## 4. Implement Agentic RAG

- [x] 4.1 Remove the eager `_retrieve_turn_sources()` call and automatic knowledge pre-loading from `agents/api/chat.py`.
- [x] 4.2 Update `agents/api/chat.py` streaming logic to consume v2 events (`ReplyStartEvent`, `TextBlockDeltaEvent`, `ToolResultEndEvent`, `ReplyEndEvent`) and assemble citations from tool metadata.
- [x] 4.3 Update `DOCUMENT_CHAT_PROMPT` in `agents/chat/prompts.py` to describe optional `search_knowledge_base` use and citation behavior.
- [x] 4.4 Ensure citations are only recorded for sources the agent actually searched or read.

## 5. Update History / Session Listing (if required by v2 migration)

- [x] 5.1 Verify `agents/chat/session_service.py` can reconstruct the visible message list from persisted `AgentState` (or keep the existing citation tables while messages come from state).
- [x] 5.2 Update `SessionService.list_sessions()` preview logic if it depended on the removed v1 memory table.

## 6. Testing and Verification

- [x] 6.1 Update `agents/tests/test_agent_factory.py` stubs for v2 `Toolkit`, `ToolBase`, and `Agent`, and verify all five tools are registered.
- [x] 6.2 Update `agents/tests/test_chat_streaming.py` to assert on v2 event-based SSE output and no-citation greeting behavior.
- [x] 6.3 Update `agents/tests/test_app_bootstrap.py` to remove v1 agentscope memory table assumptions.
- [x] 6.4 Update `agents/tests/test_seraph_knowledge.py` since `agentscope.rag` is removed; validate the new plain search adapter or direct `RetrievalService` usage.
- [x] 6.5 Add tests for iterative `search_knowledge_base` calls and citation recording.
- [x] 6.6 Run `ruff check .` and `mypy .` in the `agents/` directory and fix reported issues.
