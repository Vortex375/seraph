## ADDED Requirements

### Requirement: Documents agent has a current date/time tool
The documents agent SHALL expose a read-only tool named `get_current_datetime` that returns the current date and time.

#### Scenario: Tool is registered on the agent
- **WHEN** `AgentFactory.create()` builds an agent for a user session
- **THEN** the returned agent toolkit contains a tool named `get_current_datetime`

#### Scenario: Tool returns the current datetime
- **WHEN** the `get_current_datetime` tool is invoked
- **THEN** it returns the current system date and time as an ISO-8601 string with timezone offset

### Requirement: Current date/time is injected into the initial system prompt
The agent system prompt SHALL include the current date and time when a new conversation is created, and that same prompt value SHALL be persisted on the `ChatSession` and reused for subsequent turns in the same session.

#### Scenario: New session receives a datetime-injected prompt
- **WHEN** a chat session is created and the agent is constructed for the first time
- **THEN** the system prompt contains a current date/time line and is persisted on the chat session

#### Scenario: Existing session reuses the previously injected prompt
- **WHEN** the agent is reconstructed for an existing chat session
- **THEN** the system prompt uses the prompt previously persisted on the chat session, not the current wall-clock time

### Requirement: System prompt guides recency-oriented answering
The agent system prompt SHALL instruct the model to prefer more recent documents and to avoid relying on outdated information when multiple indexed documents match the user's query.

#### Scenario: Prompt contains recency guidance
- **WHEN** the system prompt is rendered for the documents agent
- **THEN** it tells the model to prefer recent information and to avoid outdated information when many documents match
