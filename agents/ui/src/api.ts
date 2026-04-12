export type ChatSession = {
  id: string
  title: string
  user_id: string
}

export async function listSessions(): Promise<ChatSession[]> {
  const response = await fetch('/api/v1/chat/sessions', { credentials: 'same-origin' })
  if (!response.ok) {
    return []
  }
  return response.json() as Promise<ChatSession[]>
}

export async function createSession(title: string): Promise<ChatSession> {
  const response = await fetch('/api/v1/chat/sessions', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title })
  })
  if (!response.ok) {
    throw new Error('failed to create session')
  }
  return response.json() as Promise<ChatSession>
}

export async function sendMessage(sessionId: string, message: string): Promise<void> {
  const response = await fetch(`/api/v1/chat/sessions/${sessionId}/messages`, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ message })
  })
  if (!response.ok) {
    throw new Error('failed to send message')
  }
}

export function openStream(sessionId: string): EventSource {
  return new EventSource(`/api/v1/chat/sessions/${sessionId}/stream`)
}
