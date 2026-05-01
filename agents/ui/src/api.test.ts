import { afterEach, describe, expect, it, vi } from 'vitest'

import { StreamOpenError, sendMessageAndStreamReply } from './api'

describe('sendMessageAndStreamReply', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('posts to the streaming endpoint and yields parsed SSE payloads', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      body: new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new TextEncoder().encode('event: reply\n'))
          controller.enqueue(new TextEncoder().encode('data: {"type":"delta","content":"Hello"}\n\n'))
          controller.enqueue(new TextEncoder().encode('data: {"type":"done"}\n\n'))
          controller.close()
        },
      }),
    })
    vi.stubGlobal('fetch', fetchMock)

    const events = []
    for await (const event of sendMessageAndStreamReply('session-1', 'Hello there')) {
      events.push(event)
    }

    expect(fetchMock).toHaveBeenCalledWith('/api/v1/chat/sessions/session-1/messages/stream', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', Accept: 'text/event-stream' },
      body: JSON.stringify({ message: 'Hello there' }),
      signal: undefined,
    })
    expect(events).toEqual([
      { type: 'delta', content: 'Hello' },
      { type: 'done' },
    ])
  })

  it('throws a dedicated open error for non-success responses', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: false,
      status: 404,
      body: null,
    }))

    await expect(async () => {
      for await (const _ of sendMessageAndStreamReply('session-1', 'Hello there')) {
        // Exhaust the stream to trigger the request.
      }
    }).rejects.toBeInstanceOf(StreamOpenError)
  })
})
