# Capability: Agentic RAG Search Assistant

## Purpose

Enable the Seraph chat agent to decide when to perform vector search over indexed documents, return citable results, and answer without documents when appropriate.

## Requirements

### Requirement: Agent has a semantic search tool
The chat agent SHALL expose a tool named `search_knowledge_base` that performs vector search over the user's accessible indexed documents.

#### Scenario: Tool is registered on the agent
- **WHEN** `AgentFactory.create()` builds an agent for a user session
- **THEN** the returned agent toolkit contains a tool named `search_knowledge_base` with a `query` parameter

#### Scenario: Tool searches scoped to user access
- **WHEN** the `search_knowledge_base` tool is invoked for a user
- **THEN** it resolves the user's scopes and returns only chunks from documents inside those scopes

### Requirement: Tool returns retrievable citation metadata
The `search_knowledge_base` tool SHALL return each hit with `provider_id` and `path` so the assistant can cite sources.

#### Scenario: Tool result is a citable hit
- **WHEN** the tool returns a chunk
- **THEN** the result includes the chunk text, the document path, the document provider, and a unique chunk identifier

### Requirement: Retrieval is not performed automatically before every turn
The chat streaming layer SHALL NOT unconditionally retrieve documents before invoking the agent.

#### Scenario: Greeting receives no automatic retrieval
- **WHEN** the user sends a message such as "hello"
- **THEN** the agent is invoked without pre-loaded document chunks and without required citations

### Requirement: Agent may answer without documents
The agent SHALL be able to answer simple or off-document queries using only its system prompt and conversation memory.

#### Scenario: Greeting answer has no citations
- **WHEN** the user greets the assistant
- **THEN** the assistant replies without citing documents and the response contains no citations

### Requirement: Agent can search iteratively
The agent SHALL be allowed to call `search_knowledge_base` multiple times within a single turn to refine results or explore related topics.

#### Scenario: Follow-up search within the same turn
- **WHEN** the agent's first search does not provide enough information
- **THEN** the agent calls `search_knowledge_base` again with a refined query before producing the final answer

### Requirement: Citations reflect actually used documents
Citations attached to the assistant response SHALL include only sources the agent searched for or read, not every retrieved chunk.

#### Scenario: Search result citation is recorded
- **WHEN** the agent uses `search_knowledge_base` and includes information from a returned chunk in its final answer
- **THEN** the resulting message citations contain a `provider_id` and `path` for that chunk

### Requirement: System prompt guides tool and citation behavior
The agent system prompt SHALL instruct the model when to use `search_knowledge_base` and how to format citations.

#### Scenario: Prompt instructs optional retrieval
- **WHEN** the system prompt is rendered for the chat agent
- **THEN** it tells the model to use the search tool only when the user's question depends on indexed documents

### Requirement: Agent prefers recent documents over outdated information
When multiple indexed documents could answer the user's query, the agent SHALL prefer information from more recent documents and SHALL avoid answering from outdated information.

#### Scenario: Recent and stale documents match the query
- **WHEN** the agent retrieves multiple indexed document chunks that could answer the user
- **THEN** the assistant's answer is based on the more recent chunk(s) and explicitly avoids relying on stale information

#### Scenario: System prompt guides recency preference
- **WHEN** the system prompt is rendered for the chat agent
- **THEN** it instructs the model to prefer more recent documents and to avoid using outdated information when many documents match a user query
