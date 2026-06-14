## ADDED Requirements

### Requirement: Agent prefers recent documents over outdated information
When multiple indexed documents could answer the user's query, the agent SHALL prefer information from more recent documents and SHALL avoid answering from outdated information.

#### Scenario: Recent and stale documents match the query
- **WHEN** the agent retrieves multiple indexed document chunks that could answer the user
- **THEN** the assistant's answer is based on the more recent chunk(s) and explicitly avoids relying on stale information

#### Scenario: System prompt guides recency preference
- **WHEN** the system prompt is rendered for the chat agent
- **THEN** it instructs the model to prefer more recent documents and to avoid using outdated information when many documents match a user query
