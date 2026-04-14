export type ChatSession = {
  id: string
  title: string
  headline: string
  preview: string
  status: 'running' | 'finished'
  user_id: string
  created_at: string
  updated_at: string
  last_message_at: string
}

export type ChatMessage = {
  id: string
  role: string
  content: string
  created_at: string
  citations: string[]
}

export type AcceptedMessageResponse = {
  accepted: boolean
}

async function requestJson<T>(input: string, init?: RequestInit): Promise<T> {
  const response = await fetch(input, {
    credentials: 'same-origin',
    ...init,
  })
  if (!response.ok) {
    throw new Error(`request failed: ${response.status}`)
  }
  return response.json() as Promise<T>
}

export async function listSessions(): Promise<ChatSession[]> {
  return requestJson<ChatSession[]>('/api/v1/chat/sessions')
}

export async function createSession(title: string): Promise<ChatSession> {
  return requestJson<ChatSession>('/api/v1/chat/sessions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title })
  })
}

export async function sendMessage(sessionId: string, message: string): Promise<AcceptedMessageResponse> {
  return requestJson<AcceptedMessageResponse>(`/api/v1/chat/sessions/${sessionId}/messages`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ message })
  })
}

export async function listMessages(sessionId: string): Promise<ChatMessage[]> {
  return requestJson<ChatMessage[]>(`/api/v1/chat/sessions/${sessionId}/messages`)
}

export async function deleteSession(sessionId: string): Promise<void> {
  const response = await fetch(`/api/v1/chat/sessions/${sessionId}`, {
    method: 'DELETE',
    credentials: 'same-origin',
  })
  if (!response.ok) {
    throw new Error('failed to delete session')
  }
}

export function openStream(sessionId: string): EventSource {
  return new EventSource(`/api/v1/chat/sessions/${sessionId}/stream`)
}
