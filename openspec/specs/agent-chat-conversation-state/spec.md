# Capability: Agent Chat Conversation State

## Purpose

Ensure the Flutter chat UI consistently and accurately reflects whether the assistant is currently generating a response, across both the conversation list and the active conversation view, while streaming chunks and refreshing the final state.

## Requirements

### Requirement: Chat generation state is authoritative
The active chat controller SHALL maintain a single observable generation state that is `running` while an assistant response is being generated and `finished` when no response is being generated.

#### Scenario: User sends a message
- **WHEN** the user submits a new message
- **THEN** the chat controller SHALL set the generation state to `running`

#### Scenario: Response stream completes
- **WHEN** the assistant response stream succeeds, fails, or is cancelled
- **THEN** the chat controller SHALL set the generation state to `finished`

### Requirement: Conversation list status reflects generation state
The conversation list item that corresponds to the active chat SHALL display a `running` status while the generation state is `running` and a `finished` status when the generation state is `finished`.

#### Scenario: Active conversation generating
- **WHEN** the active chat generation state is `running`
- **THEN** the conversation list item SHALL show the `running` status

#### Scenario: Active conversation done
- **WHEN** the active chat generation state transitions to `finished`
- **THEN** the conversation list item SHALL show the `finished` status

### Requirement: Assistant bubble shows a loading indicator while generating
The assistant message bubble for the response currently being generated SHALL display a loading/typing indicator while the assistant is still generating. The indicator SHALL remain visible as streamed tokens arrive so the user knows more content is coming, and SHALL be removed only when the response finishes, fails, or is cancelled.

#### Scenario: Waiting for first token
- **WHEN** the user sends a message and no token has arrived yet
- **THEN** the assistant message bubble SHALL show a loading/typing indicator

#### Scenario: Streaming tokens while generating
- **WHEN** the assistant is streaming response tokens
- **THEN** the assistant message bubble SHALL render the streamed content and also show the loading/typing indicator

#### Scenario: Response finishes
- **WHEN** the assistant response finishes generating
- **THEN** the loading/typing indicator SHALL be removed

### Requirement: Assistant responses are streamed and rendered incrementally
The chat controller SHALL request the assistant response as a stream and the chat UI SHALL render each received chunk in the active assistant message bubble as it is generated.

#### Scenario: Chunk arrives during generation
- **WHEN** a response chunk is received from the stream
- **THEN** the chunk SHALL be appended to the active assistant message bubble

#### Scenario: Multiple chunks stream in sequence
- **WHEN** multiple response chunks are received in sequence
- **THEN** each chunk SHALL be appended to the previous chunks in order

### Requirement: Conversation is refreshed when streaming ends
When the assistant response stream ends, the application SHALL refresh the current conversation and the corresponding conversation list item so the final displayed content matches the persisted state.

#### Scenario: Stream ends successfully
- **WHEN** the assistant response stream completes successfully
- **THEN** the chat controller SHALL fetch/refresh the conversation and the list item SHALL show the final state

#### Scenario: Stream ends with error or cancellation
- **WHEN** the assistant response stream ends due to an error or cancellation
- **THEN** the generation state SHALL become `finished`, the conversation SHALL be refreshed, and the list item SHALL show the final state

### Requirement: User input is disabled while generating
The chat message input send control SHALL be disabled while the generation state is `running` and SHALL be re-enabled when the generation state becomes `finished`.

#### Scenario: Send during generation
- **WHEN** the user attempts to send another message while the assistant is generating
- **THEN** the send control SHALL be disabled and no second request SHALL be issued

#### Scenario: Send after completion
- **WHEN** the assistant generation state transitions to `finished`
- **THEN** the send control SHALL be enabled
