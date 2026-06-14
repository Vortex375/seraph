## Why

The search-assistant currently feeds the agent a fixed set of retrieved document chunks for every user message. This blanket retrieval confuses the model on greetings, simple factual questions, or out-of-scope prompts, and prevents exploratory, iterative research. Moving to true agentic RAG lets the assistant decide when, what, and how many documents to retrieve through its own tool, improving answer quality and reducing noise.

## What Changes

- Remove automatic per-turn document retrieval from the chat streaming path.
- Give the `ReActAgent` a new `search_knowledge_base` tool that performs scoped semantic search over the document embeddings.
- Let the agent return citations from both knowledge searches and existing file-access tools using a shared citation model.
- Update the agent system prompt to explain the new tool, its limits, and citation expectations.
- Add tests covering no-retrieval greetings, single-tool retrieval, multi-step retrieval, and citation tracking.

## Capabilities

### New Capabilities

- `agentic-rag-search-assistant`: Agent-controlled semantic search over the user's indexed documents, replacing unconditional RAG so the model can answer without documents, explore iteratively, and cite sources.

### Modified Capabilities

- None (no existing spec-level capability definitions are changing).

## Impact

- `agents/chat/agent_factory.py`: registers the new `search_knowledge_base` tool and stops pre-loading knowledge.
- `agents/chat/search_client.py` / `agents/retrieval/service.py`: reused as the semantic search backend via a thin agent-facing adapter.
- `agents/api/chat.py`: removes `_retrieve_turn_sources` call so the agent is not auto-fed retrieval results; citation assembly stays for tool results.
- `agents/knowledge/seraph_knowledge.py`: becomes the agent-facing search surface rather than an always-on knowledge base.
- Unit and integration tests in `agents/tests/` need new agentic-RAG cases.

