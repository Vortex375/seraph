# Chat Single-Request Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the split chat send/stream protocol with a single streamed POST that persists conversation state independently of the client connection.

**Architecture:** The backend will treat one streamed POST request as one assistant turn, persist the user message immediately, run assistant generation in a backend-owned turn runner, and persist success or failure even if the SSE client disconnects. The Flutter client will switch from `sendMessage()` plus `streamAssistantReply()` to one `sendMessageAndStreamReply()` streamed POST call while keeping optimistic local UI state.

**Tech Stack:** FastAPI, SQLAlchemy async session + AgentScope memory tables, Flutter/Dart, `package:http` streamed requests, pytest, flutter_test

---

## File Structure

- Modify: `agents/api/chat.py`
  - remove `PendingChatTurn` request-bridging flow
  - add single-request streamed POST endpoint
  - add backend-owned turn runner lifecycle
- Modify: `agents/api/models.py`
  - add request/response fields for persisted assistant message status/error as needed
- Modify: `agents/chat/session_service.py`
  - stop deriving running state from `PendingChatTurn`
  - read persisted assistant status/failure from message history instead
- Modify: `agents/documents/models.py`
  - remove `PendingChatTurn`
  - add persisted assistant turn status/error model if needed near existing chat persistence support
- Modify: `agents/tests/test_chat_streaming.py`
  - replace pending-turn claim tests with single-request stream lifecycle tests
- Modify: `agents/tests/test_session_service.py`
  - replace pending-turn sidebar status expectations with persisted assistant status expectations
- Modify: `app/seraph_app/lib/src/chat/chat_service.dart`
  - replace split send/stream API with one streamed POST method
- Modify: `app/seraph_app/lib/src/chat/chat_controller.dart`
  - switch to single streamed POST flow
- Modify: `app/seraph_app/test/chat/chat_service_test.dart`
  - update transport tests for streamed POST
- Modify: `app/seraph_app/test/chat/chat_controller_test.dart`
  - update controller tests for single-call send/stream lifecycle

### Task 1: Backend API Contract And Persistence Tests

**Files:**
- Modify: `agents/tests/test_chat_streaming.py`
- Modify: `agents/tests/test_session_service.py`
- Modify: `agents/api/models.py`

- [ ] **Step 1: Write failing backend tests for the new API contract**

Add tests covering:

```python
def test_message_stream_endpoint_accepts_post_body_and_returns_sse():
    response = client.post(
        "/api/v1/chat/sessions/session-1/messages/stream",
        json={"message": "hello"},
        headers={"X-Seraph-User": "alice"},
    )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/event-stream")


async def test_disconnect_after_first_chunk_still_persists_completed_assistant_message(...):
    ...


async def test_generation_failure_persists_failed_assistant_message_with_partial_content(...):
    ...


async def test_list_sessions_marks_running_from_persisted_assistant_status_not_pending_turns(...):
    ...
```

- [ ] **Step 2: Run backend tests to verify they fail for the expected reason**

Run:

```bash
cd /home/vortex/work/projects/seraph/.worktrees/chat-single-request-streaming/agents && pytest tests/test_chat_streaming.py tests/test_session_service.py -q
```

Expected:

- FAIL because `POST /sessions/{id}/messages/stream` does not exist yet
- FAIL because session status still depends on `PendingChatTurn`

- [ ] **Step 3: Add the minimal API model changes needed by those tests**

Update `agents/api/models.py` so chat history can represent persisted assistant state:

```python
class ChatMessageResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    role: str
    content: str
    created_at: datetime
    citations: list[FileCitationResponse]
    status: str = "finished"
    error: str | None = None
```

- [ ] **Step 4: Run the same backend tests again**

Run:

```bash
cd /home/vortex/work/projects/seraph/.worktrees/chat-single-request-streaming/agents && pytest tests/test_chat_streaming.py tests/test_session_service.py -q
```

Expected:

- still FAIL, now only on missing lifecycle/backend implementation

### Task 2: Backend Single-Request Stream Lifecycle

**Files:**
- Modify: `agents/api/chat.py`
- Modify: `agents/chat/session_service.py`
- Modify: `agents/documents/models.py`
- Modify: `agents/tests/test_chat_streaming.py`
- Modify: `agents/tests/test_session_service.py`

- [ ] **Step 1: Implement persisted assistant turn state and remove `PendingChatTurn` usage**

Update model/service code so session status is derived from persisted assistant message state instead of `PendingChatTurn` rows. A minimal direction is:

```python
@dataclass(frozen=True)
class ChatHistoryMessage:
    id: str
    role: str
    content: str
    created_at: datetime
    citations: list[dict[str, str]]
    status: str = "finished"
    error: str | None = None
```

and in `list_sessions()`:

```python
status_by_session: dict[str, str] = {}
for session_id, raw_msg, _index in agentscope_messages.all():
    if not isinstance(raw_msg, dict):
        continue
    if raw_msg.get("role") == "assistant" and raw_msg.get("status") == "running":
        status_by_session[session_id] = "running"
```

- [ ] **Step 2: Implement the new streamed POST endpoint and backend-owned runner**

In `agents/api/chat.py`, replace the split flow with a single endpoint like:

```python
@router.post("/sessions/{session_id}/messages/stream")
async def create_message_and_stream(...):
    await _get_owned_session(...)
    user_message_id = await _persist_user_message(...)
    assistant_message_id = await _persist_running_assistant_message(...)
    runner = _start_turn_runner(...)
    return StreamingResponse(_subscribe_turn_events(runner), media_type="text/event-stream")
```

The runner must:

- continue after client disconnect
- persist final assistant content on success
- persist failure and partial content on error

- [ ] **Step 3: Remove the old pending-turn claim/unclaim helpers and route usage**

Delete or stop using:

```python
_accept_pending_turn
_claim_pending_turn
_consume_pending_turn
_unclaim_pending_turn
PendingChatTurn
@router.post("/sessions/{session_id}/messages")
@router.get("/sessions/{session_id}/stream")
```

Adjust tests that referenced those flows.

- [ ] **Step 4: Run focused backend tests**

Run:

```bash
cd /home/vortex/work/projects/seraph/.worktrees/chat-single-request-streaming/agents && pytest tests/test_chat_streaming.py tests/test_session_service.py tests/test_chat_api.py -q
```

Expected:

- PASS for the updated single-request streaming lifecycle

### Task 3: Flutter Single-Request Streaming Transport Tests

**Files:**
- Modify: `app/seraph_app/test/chat/chat_service_test.dart`
- Modify: `app/seraph_app/test/chat/chat_controller_test.dart`

- [ ] **Step 1: Write failing Flutter tests for the new single streamed POST flow**

Update `chat_service_test.dart` to expect one streamed POST request:

```dart
test('sendMessageAndStreamReply sends streamed POST request', () async {
  httpClient.handler = (request) async {
    expect(request.method, 'POST');
    expect(request.url.toString(), 'https://seraph.test/api/v1/chat/sessions/session-1/messages/stream');
    expect(await request.finalize().bytesToString(), '{"message":"Hello there"}');
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable([
        utf8.encode('data: {"type":"delta","content":"Hello"}\n\n'),
        utf8.encode('data: {"type":"done"}\n\n'),
      ]),
      200,
      headers: const {'content-type': 'text/event-stream'},
    );
  };
});
```

Update controller tests to assert it no longer calls separate `sendMessage()` and `streamAssistantReply()` methods.

- [ ] **Step 2: Run Flutter tests to verify they fail**

Run:

```bash
cd /home/vortex/work/projects/seraph/.worktrees/chat-single-request-streaming/app/seraph_app && flutter test test/chat/chat_service_test.dart test/chat/chat_controller_test.dart
```

Expected:

- FAIL because the old split API is still present

- [ ] **Step 3: Keep only the minimal fake/test API surface needed for the new flow**

Update test doubles from:

```dart
Future<void> sendMessage(String sessionId, String message)
Stream<Map<String, dynamic>> streamAssistantReply(String sessionId)
```

to:

```dart
Stream<Map<String, dynamic>> sendMessageAndStreamReply(String sessionId, String message)
```

- [ ] **Step 4: Re-run the same Flutter tests**

Run:

```bash
cd /home/vortex/work/projects/seraph/.worktrees/chat-single-request-streaming/app/seraph_app && flutter test test/chat/chat_service_test.dart test/chat/chat_controller_test.dart
```

Expected:

- still FAIL, now only on production implementation

### Task 4: Flutter Implementation

**Files:**
- Modify: `app/seraph_app/lib/src/chat/chat_service.dart`
- Modify: `app/seraph_app/lib/src/chat/chat_controller.dart`
- Modify: `app/seraph_app/test/chat/chat_service_test.dart`
- Modify: `app/seraph_app/test/chat/chat_controller_test.dart`

- [ ] **Step 1: Implement one streamed POST method in `ChatService`**

Replace the split methods with:

```dart
Stream<Map<String, dynamic>> sendMessageAndStreamReply(String sessionId, String message) async* {
  final request = http.Request(
    'POST',
    Uri.parse('${settingsController.serverUrl.value}/api/v1/chat/sessions/$sessionId/messages/stream'),
  );
  request.headers.addAll({
    'Content-Type': 'application/json',
    'Accept': 'text/event-stream',
    ...await _getRequestHeaders(),
  });
  request.body = jsonEncode({'message': message});
  final response = await httpClient.send(request);
  ...
}
```

- [ ] **Step 2: Update `ChatController.sendCurrentMessage()` to use the single call**

Replace:

```dart
await chatService.sendMessage(sessionId, draft);
_replySubscription = chatService.streamAssistantReply(sessionId).listen(...)
```

with:

```dart
_replySubscription = chatService.sendMessageAndStreamReply(sessionId, draft).listen(...)
```

Keep optimistic user/assistant bubbles and existing stream-content handling.

- [ ] **Step 3: Run focused Flutter tests**

Run:

```bash
cd /home/vortex/work/projects/seraph/.worktrees/chat-single-request-streaming/app/seraph_app && flutter test test/chat/chat_service_test.dart test/chat/chat_controller_test.dart test/chat/chat_view_test.dart
```

Expected:

- PASS for updated single-call flow

### Task 5: Verification

**Files:**
- Modify: `agents/tests/test_chat_streaming.py`
- Modify: `app/seraph_app/test/chat/chat_controller_test.dart`

- [ ] **Step 1: Add one end-to-end style backend regression test for disconnect persistence**

Add a focused backend test that proves:

```python
async def test_started_turn_persists_completion_after_stream_subscriber_disconnect(...):
    ...
```

- [ ] **Step 2: Run targeted backend verification**

Run:

```bash
cd /home/vortex/work/projects/seraph/.worktrees/chat-single-request-streaming/agents && pytest tests/test_chat_streaming.py tests/test_session_service.py tests/test_chat_api.py -q
```

Expected:

- PASS

- [ ] **Step 3: Run targeted Flutter verification**

Run:

```bash
cd /home/vortex/work/projects/seraph/.worktrees/chat-single-request-streaming/app/seraph_app && flutter test test/chat/chat_service_test.dart test/chat/chat_controller_test.dart test/chat/chat_view_test.dart
```

Expected:

- PASS

- [ ] **Step 4: Run a live integration check through the docker-served app**

Run after rebuilding the served app:

```bash
cd /home/vortex/work/projects/seraph && docker compose -f docker-compose.dev.yml build api-gateway && docker compose -f docker-compose.dev.yml up -d api-gateway
```

Verify in the browser:

- sending a message performs one streamed POST
- stream updates appear incrementally
- refreshing after a completed turn shows the persisted assistant reply
- a forced disconnect scenario still leaves a completed reply visible after reload
