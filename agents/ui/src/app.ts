import { createSession, listMessages, listSessions, openStream, sendMessage, type ChatMessage, type ChatSession } from './api'

function messageNode(text: string, role: string, citations: string[] = []): HTMLDivElement {
  const node = document.createElement('div')
  node.dataset.role = role
  node.textContent = `${role}: ${text}`
  if (citations.length > 0) {
    const citationsNode = document.createElement('div')
    citationsNode.textContent = `Sources: ${citations.join(', ')}`
    node.appendChild(citationsNode)
  }
  return node
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

export function mountApp(root: HTMLElement): void {
  let activeSessionId = ''
  let stream: EventSource | null = null

  root.innerHTML = `
    <main>
      <h1>Seraph Chat</h1>
      <div id="status" role="status" aria-live="polite"></div>
      <button id="new-session" type="button">New Session</button>
      <ul id="sessions"></ul>
      <section>
        <div id="messages"></div>
        <form id="composer">
          <input id="message-input" name="message" type="text" placeholder="Ask about your documents" />
          <button type="submit">Send</button>
        </form>
      </section>
    </main>
  `

  const sessionsList = root.querySelector<HTMLUListElement>('#sessions')
  const messages = root.querySelector<HTMLDivElement>('#messages')
  const status = root.querySelector<HTMLDivElement>('#status')
  const composer = root.querySelector<HTMLFormElement>('#composer')
  const input = root.querySelector<HTMLInputElement>('#message-input')
  const newSessionButton = root.querySelector<HTMLButtonElement>('#new-session')

  if (!sessionsList || !messages || !status || !composer || !input || !newSessionButton) {
    throw new Error('ui failed to initialize')
  }

  const clearStatus = () => {
    status.textContent = ''
  }

  const showError = (message: string) => {
    status.textContent = message
  }

  const refreshHistory = async (sessionId: string) => {
    renderMessages(await listMessages(sessionId))
  }

  const connectStream = (sessionId: string) => {
    stream?.close()
    stream = openStream(sessionId)
    stream.onerror = async () => {
      try {
        await refreshHistory(sessionId)
        clearStatus()
      } catch {
        showError('Connection lost. Try reopening the session.')
      }
      stream?.close()
    }
    stream.onmessage = (event) => {
      try {
        const payload = JSON.parse(event.data) as { content?: unknown }
        clearStatus()
        messages.appendChild(messageNode(messageText(payload.content, event.data), 'assistant'))
      } catch {
        clearStatus()
        messages.appendChild(messageNode(event.data, 'assistant'))
      }
    }
  }

  const renderMessages = (history: ChatMessage[]) => {
    messages.innerHTML = ''
    for (const item of history) {
      messages.appendChild(messageNode(item.content, item.role, item.role === 'assistant' ? item.citations : []))
    }
  }

  const renderSessions = (sessions: ChatSession[]) => {
    sessionsList.innerHTML = ''
    for (const session of sessions) {
      const item = document.createElement('li')
      const button = document.createElement('button')
      button.type = 'button'
      button.textContent = session.title
      button.addEventListener('click', async () => {
        activeSessionId = session.id
        try {
          clearStatus()
          await refreshHistory(session.id)
        } catch {
          showError('Failed to load message history.')
        }
      })
      item.appendChild(button)
      sessionsList.appendChild(item)
    }
  }

  const refreshSessions = async () => {
    try {
      renderSessions(await listSessions())
    } catch {
      showError('Failed to load sessions.')
    }
  }

  newSessionButton.addEventListener('click', async () => {
    try {
      clearStatus()
      const session = await createSession(`Session ${new Date().toLocaleTimeString()}`)
      activeSessionId = session.id
      await refreshSessions()
      messages.innerHTML = ''
    } catch {
      showError('Failed to create a session.')
    }
  })

  composer.addEventListener('submit', async (event) => {
    event.preventDefault()
    const message = input.value.trim()
    if (!activeSessionId || !message) {
      return
    }
    messages.appendChild(messageNode(message, 'user'))
    input.value = ''
    try {
      clearStatus()
      await sendMessage(activeSessionId, message)
      connectStream(activeSessionId)
    } catch {
      showError('Failed to send message.')
    }
  })

  void refreshSessions().catch(() => {
    showError('Failed to load sessions.')
  })
}
