import { FormEvent, MutableRefObject, useEffect, useMemo, useRef, useState } from 'react'

import { createSession, deleteSession, listMessages, listSessions, openStream, sendMessage, type ChatMessage, type ChatSession } from './api'

type MessageState = ChatMessage

function closeStream(streamRef: MutableRefObject<EventSource | null>) {
  streamRef.current?.close()
  streamRef.current = null
}

function updateSessionState(sessions: ChatSession[], sessionId: string, updater: (session: ChatSession) => ChatSession): ChatSession[] {
  return sessions.map((session) => (session.id === sessionId ? updater(session) : session))
}

function messageText(content: unknown, fallback: string): string {
  if (typeof content === 'string') {
    return content
  }

  if (Array.isArray(content)) {
    const text = content
      .filter((part): part is { type?: unknown; text?: unknown } => typeof part === 'object' && part !== null)
      .map((part) => (part.type === 'text' && typeof part.text === 'string' ? part.text : ''))
      .join('')

    if (text) {
      return text
    }
  }

  return fallback
}

function upsertOptimisticUserMessage(messages: MessageState[], content: string): MessageState[] {
  return [
    ...messages,
    {
      id: `draft-${messages.length + 1}`,
      role: 'user',
      content,
      created_at: new Date().toISOString(),
      citations: [],
    },
  ]
}

export function App() {
  const [sessions, setSessions] = useState<ChatSession[]>([])
  const [messages, setMessages] = useState<MessageState[]>([])
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const [appError, setAppError] = useState('')
  const [historyError, setHistoryError] = useState('')
  const [isLoadingSessions, setIsLoadingSessions] = useState(true)
  const [isSending, setIsSending] = useState(false)
  const streamRef = useRef<EventSource | null>(null)
  const activeSessionIdRef = useRef<string | null>(null)

  const activeSession = useMemo(
    () => sessions.find((session) => session.id === activeSessionId) ?? null,
    [sessions, activeSessionId],
  )

  useEffect(() => {
    activeSessionIdRef.current = activeSessionId
  }, [activeSessionId])

  const loadSessions = async (preserveSelection = true) => {
    try {
      setAppError('')
      const nextSessions = await listSessions()
      setSessions(nextSessions)
      if (!preserveSelection) {
        return
      }
      setActiveSessionId((current) => (current && nextSessions.some((session) => session.id === current) ? current : null))
    } catch {
      setAppError('Failed to load conversations.')
    } finally {
      setIsLoadingSessions(false)
    }
  }

  const loadMessages = async (sessionId: string) => {
    try {
      setHistoryError('')
      const nextMessages = await listMessages(sessionId)
      if (activeSessionIdRef.current === sessionId) {
        setMessages(nextMessages)
      }
    } catch {
      if (activeSessionIdRef.current === sessionId) {
        setHistoryError('Failed to load conversation history.')
      }
    }
  }

  useEffect(() => {
    void loadSessions()
    return () => {
      streamRef.current?.close()
    }
  }, [])

  useEffect(() => {
    if (!activeSessionId) {
      setMessages([])
      return
    }
    void loadMessages(activeSessionId)
  }, [activeSessionId])

  const handleCreateSession = async () => {
    try {
      const session = await createSession('New conversation')
      await loadSessions(false)
      setSessions((current) => {
        const deduped = current.filter((item) => item.id !== session.id)
        return [session, ...deduped]
      })
      setActiveSessionId(session.id)
      setMessages([])
      setDraft('')
    } catch {
      setAppError('Failed to create a conversation.')
    }
  }

  const handleDeleteSession = async (session: ChatSession) => {
    if (!window.confirm(`Delete ${session.headline}?`)) {
      return
    }
    try {
      await deleteSession(session.id)
      if (activeSessionId === session.id) {
        closeStream(streamRef)
      }
      setSessions((current) => current.filter((item) => item.id !== session.id))
      if (activeSessionId === session.id) {
        setActiveSessionId(null)
        setMessages([])
      }
    } catch {
      setAppError('Failed to delete the conversation.')
    }
  }

  const handleSelectSession = async (sessionId: string) => {
    if (activeSessionId && activeSessionId !== sessionId) {
      closeStream(streamRef)
    }
    setActiveSessionId(sessionId)
  }

  const refreshActiveConversation = async (sessionId: string) => {
    await Promise.all([loadMessages(sessionId), loadSessions()])
  }

  const handleSubmit = async (event: FormEvent) => {
    event.preventDefault()
    if (!activeSessionId) {
      return
    }

    const message = draft.trim()
    if (!message) {
      return
    }

    const sessionId = activeSessionId
    const now = new Date().toISOString()
    setIsSending(true)
    setHistoryError('')
    setMessages((current) => upsertOptimisticUserMessage(current, message))
    setSessions((current) => updateSessionState(current, sessionId, (session) => ({
      ...session,
      preview: message,
      status: 'running',
      last_message_at: now,
      updated_at: now,
    })))
    setDraft('')

    try {
      await sendMessage(sessionId, message)
      closeStream(streamRef)
      const stream = openStream(sessionId)
      streamRef.current = stream

      stream.onmessage = (eventMessage) => {
        const text = (() => {
          try {
            const payload = JSON.parse(eventMessage.data) as { content?: unknown }
            return messageText(payload.content, eventMessage.data)
          } catch {
            return eventMessage.data
          }
        })()

        setMessages((current) => {
          const lastMessage = current.at(-1)
          if (lastMessage?.role === 'assistant' && lastMessage.id === 'streaming-assistant') {
            return [...current.slice(0, -1), { ...lastMessage, content: text }]
          }
          return [
            ...current,
            {
              id: 'streaming-assistant',
              role: 'assistant',
              content: text,
              created_at: new Date().toISOString(),
              citations: [],
            },
          ]
        })
        setSessions((current) => updateSessionState(current, sessionId, (session) => ({
          ...session,
          preview: text,
          status: 'running',
        })))
      }

      stream.onerror = () => {
        stream.close()
        streamRef.current = null
        void refreshActiveConversation(sessionId).catch(() => {
          setHistoryError('Connection lost. Reopen the conversation to retry.')
        })
      }
    } catch {
      setDraft(message)
      setHistoryError('Failed to send message.')
      setMessages((current) => current.filter((item) => !(item.id.startsWith('draft-') && item.content === message)))
      void loadSessions().catch(() => undefined)
    } finally {
      setIsSending(false)
    }
  }

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="sidebar__header">
          <div>
            <p className="sidebar__eyebrow">Seraph Agents</p>
            <h1>Conversations</h1>
          </div>
          <button className="primary-button" type="button" onClick={handleCreateSession}>
            New chat
          </button>
        </div>
        {appError ? <div className="banner banner--error">{appError}</div> : null}
        <div className="session-list" aria-busy={isLoadingSessions}>
          {sessions.map((session) => {
            const selected = session.id === activeSessionId
            return (
              <div className={`session-row${selected ? ' session-row--active' : ''}`} data-session-id={session.id} data-testid={`session-row-${session.id}`} key={session.id}>
                <button className="session-row__button" type="button" onClick={() => void handleSelectSession(session.id)}>
                  <span className={`status-pill status-pill--${session.status}`}>{session.status === 'running' ? 'Running' : 'Finished'}</span>
                  <strong>{session.headline}</strong>
                  <span className="session-row__preview">{session.preview || 'No messages yet'}</span>
                </button>
                <button
                  aria-label={`Delete ${session.headline}`}
                  className="icon-button"
                  type="button"
                  onClick={() => void handleDeleteSession(session)}
                >
                  Delete
                </button>
              </div>
            )
          })}
          {!isLoadingSessions && sessions.length === 0 ? <p className="empty-copy">No conversations yet.</p> : null}
        </div>
      </aside>
      <main className="conversation-pane">
        {activeSession ? (
          <>
            <header className="conversation-pane__header">
              <div>
                <p className="sidebar__eyebrow">{activeSession.status === 'running' ? 'Agent replying' : 'Conversation ready'}</p>
                <h2>{activeSession.headline}</h2>
              </div>
            </header>
            {historyError ? <div className="banner banner--error">{historyError}</div> : null}
            <section className="message-list" aria-live="polite">
              {messages.map((message) => (
                <article className={`bubble bubble--${message.role}`} key={message.id}>
                  <p>{message.content}</p>
                  {message.citations.length > 0 ? (
                    <details className="citations">
                      <summary>Sources</summary>
                      <ul>
                        {message.citations.map((citation) => (
                          <li key={citation}>{citation}</li>
                        ))}
                      </ul>
                    </details>
                  ) : null}
                </article>
              ))}
            </section>
            <form className="composer" onSubmit={handleSubmit}>
              <input
                placeholder="Message Seraph"
                type="text"
                value={draft}
                onChange={(event) => setDraft(event.target.value)}
              />
              <button className="primary-button" disabled={isSending} type="submit">
                Send
              </button>
            </form>
          </>
        ) : (
          <section className="empty-state">
            <h2>Seraph Chat</h2>
            <p>Select a conversation to start chatting.</p>
          </section>
        )}
      </main>
    </div>
  )
}
