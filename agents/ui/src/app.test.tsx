import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'

import { App } from './App'
import * as api from './api'

vi.mock('./api', async () => {
  const actual = await vi.importActual<typeof import('./api')>('./api')
  return {
    ...actual,
    listSessions: vi.fn(),
    createSession: vi.fn(),
    listMessages: vi.fn(),
    sendMessageAndStreamReply: vi.fn(),
    deleteSession: vi.fn(),
  }
})

const mockedApi = vi.mocked(api)

function streamFrom(events: Array<Promise<unknown> | unknown>, signal?: AbortSignal): AsyncIterable<unknown> {
  return {
    async *[Symbol.asyncIterator]() {
      for (const event of events) {
        if (signal?.aborted) {
          return
        }
        yield await event
      }
    },
  }
}

describe('App', () => {
  const streamSignals: AbortSignal[] = []

  beforeEach(() => {
    streamSignals.length = 0
    mockedApi.listSessions.mockResolvedValue([])
    mockedApi.createSession.mockResolvedValue({
      id: 'new-session',
      user_id: 'alice',
      title: 'New conversation',
      headline: 'New conversation',
      preview: '',
      status: 'finished',
      created_at: '2026-04-12T00:00:00Z',
      updated_at: '2026-04-12T00:00:00Z',
      last_message_at: '2026-04-12T00:00:00Z',
    })
    mockedApi.listMessages.mockResolvedValue([])
    mockedApi.sendMessageAndStreamReply.mockImplementation((_sessionId, _message, signal) => {
      if (signal) {
        streamSignals.push(signal)
      }
      return streamFrom([], signal)
    })
    mockedApi.deleteSession.mockResolvedValue()
    vi.stubGlobal('confirm', vi.fn(() => true))
  })

  afterEach(() => {
    cleanup()
    vi.unstubAllGlobals()
    vi.clearAllMocks()
  })

  it('renders sidebar sessions with status, headline, preview and delete action', async () => {
    mockedApi.listSessions.mockResolvedValue([
      {
        id: 'session-1',
        user_id: 'alice',
        title: 'Roadmap Review',
        headline: 'Roadmap Review',
        preview: 'Last preview line',
        status: 'running',
        created_at: '2026-04-12T00:00:00Z',
        updated_at: '2026-04-12T00:00:00Z',
        last_message_at: '2026-04-12T00:00:00Z',
      },
    ])

    render(<App />)

    const item = await screen.findByRole('button', { name: /running roadmap review last preview line/i })
    const row = item.closest('[data-session-id="session-1"]')
    expect(row).not.toBeNull()
    expect(within(row as HTMLElement).getByText('Running')).toBeInTheDocument()
    expect(within(row as HTMLElement).getByText('Last preview line')).toBeInTheDocument()
    expect(within(row as HTMLElement).getByRole('button', { name: /delete roadmap review/i })).toBeInTheDocument()
  })

  it('loads and renders conversation bubbles with expandable citations', async () => {
    mockedApi.listSessions.mockResolvedValue([
      {
        id: 'session-1',
        user_id: 'alice',
        title: 'Inbox',
        headline: 'Inbox',
        preview: 'I found these documents.',
        status: 'finished',
        created_at: '2026-04-12T00:00:00Z',
        updated_at: '2026-04-12T00:00:00Z',
        last_message_at: '2026-04-12T00:00:00Z',
      },
    ])
    mockedApi.listMessages.mockResolvedValue([
      {
        id: 'user-1',
        role: 'user',
        content: 'Find documents related to music',
        created_at: '2026-04-12T00:00:00Z',
        citations: [],
      },
      {
        id: 'assistant-1',
        role: 'assistant',
        content: 'I found these documents related to music.',
        created_at: '2026-04-12T00:00:01Z',
        citations: ['/Music/example-a.url', '/Music/example-b.url'],
      },
    ])

    render(<App />)

    fireEvent.click(await screen.findByRole('button', { name: /finished inbox i found these documents\./i }))

    expect(await screen.findByText('Find documents related to music')).toBeInTheDocument()
    expect(screen.getByText('I found these documents related to music.')).toBeInTheDocument()
    expect(screen.getByText('Sources')).toBeInTheDocument()
    expect(screen.getByText('/Music/example-a.url')).toBeInTheDocument()
    expect(screen.getByText('/Music/example-b.url')).toBeInTheDocument()
  })

  it('deletes a conversation and clears the active pane when confirmed', async () => {
    mockedApi.listSessions
      .mockResolvedValueOnce([
        {
          id: 'session-1',
          user_id: 'alice',
          title: 'Inbox',
          headline: 'Inbox',
          preview: 'hello',
          status: 'finished',
          created_at: '2026-04-12T00:00:00Z',
          updated_at: '2026-04-12T00:00:00Z',
          last_message_at: '2026-04-12T00:00:00Z',
        },
      ])
      .mockResolvedValueOnce([])
    mockedApi.listMessages.mockResolvedValue([])

    render(<App />)

    fireEvent.click(await screen.findByRole('button', { name: /finished inbox hello/i }))
    fireEvent.click(screen.getByRole('button', { name: /delete inbox/i }))

    await waitFor(() => expect(mockedApi.deleteSession).toHaveBeenCalledWith('session-1'))
    await screen.findByText('Select a conversation to start chatting.')
  })

  it('marks the active session as running immediately after sending a message', async () => {
    render(<App />)

    fireEvent.click(screen.getByRole('button', { name: /new chat/i }))
    await waitFor(() => expect(mockedApi.createSession).toHaveBeenCalledWith('New conversation'))

    fireEvent.change(screen.getByPlaceholderText(/message seraph/i), {
      target: { value: 'Draft roadmap for distributed search rollout' },
    })
    fireEvent.click(screen.getByRole('button', { name: /send/i }))

    await waitFor(() => expect(mockedApi.sendMessageAndStreamReply).toHaveBeenCalledWith('new-session', 'Draft roadmap for distributed search rollout', expect.any(AbortSignal)))
    const row = await screen.findByTestId('session-row-new-session')
    expect(within(row).getByText('Running')).toBeInTheDocument()
    expect(within(row).getByText('Draft roadmap for distributed search rollout')).toBeInTheDocument()
  })

  it('closes the active stream when switching to another session', async () => {
    mockedApi.listSessions.mockResolvedValue([
      {
        id: 'session-1',
        user_id: 'alice',
        title: 'Inbox',
        headline: 'Inbox',
        preview: 'hello',
        status: 'finished',
        created_at: '2026-04-12T00:00:00Z',
        updated_at: '2026-04-12T00:00:00Z',
        last_message_at: '2026-04-12T00:00:00Z',
      },
      {
        id: 'session-2',
        user_id: 'alice',
        title: 'Roadmap',
        headline: 'Roadmap',
        preview: 'status update',
        status: 'finished',
        created_at: '2026-04-12T00:00:00Z',
        updated_at: '2026-04-12T00:00:00Z',
        last_message_at: '2026-04-12T00:00:01Z',
      },
    ])
    mockedApi.listMessages.mockResolvedValue([])

    render(<App />)

    fireEvent.click(await screen.findByRole('button', { name: /finished inbox hello/i }))
    fireEvent.change(screen.getByPlaceholderText(/message seraph/i), {
      target: { value: 'hello world' },
    })
    fireEvent.click(screen.getByRole('button', { name: /send/i }))

    await waitFor(() => expect(mockedApi.sendMessageAndStreamReply).toHaveBeenCalledWith('session-1', 'hello world', expect.any(AbortSignal)))
    fireEvent.click(screen.getByRole('button', { name: /finished roadmap status update/i }))

    expect(streamSignals[0].aborted).toBe(true)
  })

  it('keeps the active stream open when deleting a different session', async () => {
    mockedApi.listSessions.mockResolvedValue([
      {
        id: 'session-1',
        user_id: 'alice',
        title: 'Inbox',
        headline: 'Inbox',
        preview: 'hello',
        status: 'finished',
        created_at: '2026-04-12T00:00:00Z',
        updated_at: '2026-04-12T00:00:00Z',
        last_message_at: '2026-04-12T00:00:00Z',
      },
      {
        id: 'session-2',
        user_id: 'alice',
        title: 'Roadmap',
        headline: 'Roadmap',
        preview: 'status update',
        status: 'finished',
        created_at: '2026-04-12T00:00:00Z',
        updated_at: '2026-04-12T00:00:00Z',
        last_message_at: '2026-04-12T00:00:01Z',
      },
    ])
    mockedApi.listMessages.mockResolvedValue([])

    render(<App />)

    fireEvent.click(await screen.findByRole('button', { name: /finished inbox hello/i }))
    fireEvent.change(screen.getByPlaceholderText(/message seraph/i), {
      target: { value: 'hello world' },
    })
    fireEvent.click(screen.getByRole('button', { name: /send/i }))

    await waitFor(() => expect(mockedApi.sendMessageAndStreamReply).toHaveBeenCalledWith('session-1', 'hello world', expect.any(AbortSignal)))
    fireEvent.click(screen.getByRole('button', { name: /delete roadmap/i }))

    expect(streamSignals[0].aborted).toBe(false)
  })

  it('ignores stale history results after switching sessions', async () => {
    let resolveSessionOne: ((messages: api.ChatMessage[]) => void) | undefined
    let resolveSessionTwo: ((messages: api.ChatMessage[]) => void) | undefined
    mockedApi.listSessions.mockResolvedValue([
      {
        id: 'session-1',
        user_id: 'alice',
        title: 'Inbox',
        headline: 'Inbox',
        preview: 'hello',
        status: 'finished',
        created_at: '2026-04-12T00:00:00Z',
        updated_at: '2026-04-12T00:00:00Z',
        last_message_at: '2026-04-12T00:00:00Z',
      },
      {
        id: 'session-2',
        user_id: 'alice',
        title: 'Roadmap',
        headline: 'Roadmap',
        preview: 'status update',
        status: 'finished',
        created_at: '2026-04-12T00:00:00Z',
        updated_at: '2026-04-12T00:00:00Z',
        last_message_at: '2026-04-12T00:00:01Z',
      },
    ])
    mockedApi.listMessages.mockImplementation((sessionId: string) => {
      if (sessionId === 'session-1') {
        return new Promise((resolve) => {
          resolveSessionOne = resolve
        })
      }
      return new Promise((resolve) => {
        resolveSessionTwo = resolve
      })
    })

    render(<App />)

    fireEvent.click(await screen.findByRole('button', { name: /finished inbox hello/i }))
    fireEvent.click(screen.getByRole('button', { name: /finished roadmap status update/i }))

    resolveSessionTwo?.([
      {
        id: 'assistant-2',
        role: 'assistant',
        content: 'Roadmap answer',
        created_at: '2026-04-12T00:00:01Z',
        citations: [],
      },
    ])

    const messageList = document.querySelector('.message-list') as HTMLElement
    expect(await within(messageList).findByText('Roadmap answer')).toBeInTheDocument()

    resolveSessionOne?.([
      {
        id: 'assistant-1',
        role: 'assistant',
        content: 'Inbox answer',
        created_at: '2026-04-12T00:00:00Z',
        citations: [],
      },
    ])

    await waitFor(() => expect(within(messageList).queryByText('Inbox answer')).not.toBeInTheDocument())
    expect(within(messageList).getByText('Roadmap answer')).toBeInTheDocument()
  })

  it('sends a message, opens a stream, and refreshes history when the stream finishes', async () => {
    mockedApi.sendMessageAndStreamReply.mockImplementation((_sessionId, _message, signal) => {
      if (signal) {
        streamSignals.push(signal)
      }
      return streamFrom([
        { content: [{ type: 'text', text: 'I found these documents related to music.' }] },
      ], signal)
    })
    mockedApi.listMessages
      .mockResolvedValueOnce([])
      .mockResolvedValueOnce([
        {
          id: 'user-1',
          role: 'user',
          content: 'Find documents related to music',
          created_at: '2026-04-12T00:00:00Z',
          citations: [],
        },
        {
          id: 'assistant-1',
          role: 'assistant',
          content: 'I found these documents related to music.',
          created_at: '2026-04-12T00:00:01Z',
          citations: ['/Music/example.url'],
        },
      ])
    
    render(<App />)

    fireEvent.click(screen.getByRole('button', { name: /new chat/i }))
    await waitFor(() => expect(mockedApi.createSession).toHaveBeenCalledWith('New conversation'))
    fireEvent.change(screen.getByPlaceholderText(/message seraph/i), {
      target: { value: 'Find documents related to music' },
    })
    fireEvent.click(screen.getByRole('button', { name: /send/i }))

    await waitFor(() => expect(mockedApi.sendMessageAndStreamReply).toHaveBeenCalledWith('new-session', 'Find documents related to music', expect.any(AbortSignal)))
    const messageList = document.querySelector('.message-list') as HTMLElement
    expect(await within(messageList).findByText('I found these documents related to music.')).toBeInTheDocument()

    await waitFor(() => expect(mockedApi.listMessages).toHaveBeenCalledTimes(2))
    expect(mockedApi.listMessages).toHaveBeenLastCalledWith('new-session')
  })

  it('uses a viewport-height shell so the composer can stay visible by default', () => {
    render(<App />)

    expect(document.querySelector('.app-shell')).toBeInTheDocument()
    expect(document.querySelector('.conversation-pane')).toBeInTheDocument()
    expect(document.querySelector('.composer')).toBeNull()
  })
})
