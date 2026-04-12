import test from 'node:test'
import assert from 'node:assert/strict'
import path from 'node:path'
import { readFile } from 'node:fs/promises'

const appModule = await loadAppModule()

test('creating or selecting a session does not open a stream', async () => {
  const { root, apiCalls, flushAsyncWork } = await renderApp({
    sessions: [{ id: 'existing-session', title: 'Existing Session', user_id: 'alice' }],
    createdSession: { id: 'new-session', title: 'New Session', user_id: 'alice' }
  })

  await flushAsyncWork()
  assert.deepEqual(apiCalls.openStream, [])

  const newSessionButton = root.querySelectorAll('button').find((button) => button.textContent === 'New Session')
  assert.ok(newSessionButton)
  newSessionButton.dispatchEvent({ type: 'click' })
  await flushAsyncWork()

  assert.deepEqual(apiCalls.openStream, [])

  const existingSessionButton = root.querySelectorAll('button').find((button) => button.textContent === 'Existing Session')
  assert.ok(existingSessionButton)
  existingSessionButton.dispatchEvent({ type: 'click' })
  await flushAsyncWork()

  assert.deepEqual(apiCalls.openStream, [])
  assert.equal(root.querySelector('#messages')?.children.length, 0)
})

test('selecting a session loads full history and renders assistant citations', async () => {
  const { root, flushAsyncWork } = await renderApp({
    sessions: [{ id: 'existing-session', title: 'Existing Session', user_id: 'alice' }],
    messagesBySession: {
      'existing-session': [
        {
          id: 'user-1',
          role: 'user',
          content: 'Find documents related to music',
          created_at: '2026-04-12T00:00:00Z',
          citations: []
        },
        {
          id: 'assistant-1',
          role: 'assistant',
          content: 'I found these documents related to music.',
          created_at: '2026-04-12T00:00:01Z',
          citations: [
            '/Music/Maki Otsuki - Destiny/visit JPOP.ru.url',
            '/Music/Maki Otsuki - Destiny/visit aziophrenia.com - Japan and Korea - music, video, idols.url'
          ]
        }
      ]
    }
  })

  await flushAsyncWork()

  const existingSessionButton = root.querySelectorAll('button').find((button) => button.textContent === 'Existing Session')
  assert.ok(existingSessionButton)
  existingSessionButton.dispatchEvent({ type: 'click' })
  await flushAsyncWork()

  const renderedMessages = root.querySelector('#messages')?.children ?? []
  assert.equal(renderedMessages.length, 2)
  assert.equal(renderedMessages[0]?.textContent, 'user: Find documents related to music')
  assert.match(renderedMessages[1]?.textContent ?? '', /assistant: I found these documents related to music\./)
  assert.equal(renderedMessages[1]?.children.length, 1)
  assert.match(renderedMessages[1]?.children[0]?.textContent ?? '', /Sources:/)
  assert.match(renderedMessages[1]?.children[0]?.textContent ?? '', /visit JPOP\.ru\.url/)
  assert.match(renderedMessages[1]?.children[0]?.textContent ?? '', /visit aziophrenia\.com - Japan and Korea - music, video, idols\.url/)
})

test('sending a message opens the stream for the active session', async () => {
  const { apiCalls, root, flushAsyncWork } = await renderApp({
    sessions: [{ id: 'session-1', title: 'Inbox', user_id: 'alice' }]
  })

  await flushAsyncWork()

  const sessionButton = root.querySelectorAll('button').find((button) => button.textContent === 'Inbox')
  assert.ok(sessionButton)
  sessionButton.dispatchEvent({ type: 'click' })
  await flushAsyncWork()

  const input = root.querySelector('#message-input')
  assert.ok(input)
  input.value = 'hello world'

  const form = root.querySelector('#composer')
  assert.ok(form)
  form.dispatchEvent({
    type: 'submit',
    preventDefault() {}
  })
  await flushAsyncWork()

  assert.deepEqual(apiCalls.sendMessage, [{ sessionId: 'session-1', message: 'hello world' }])
  assert.deepEqual(apiCalls.openStream, ['session-1'])
})

test('assistant stream renders text from array content blocks', async () => {
  const { apiCalls, root, flushAsyncWork } = await renderApp({
    sessions: [{ id: 'session-1', title: 'Inbox', user_id: 'alice' }]
  })

  await flushAsyncWork()

  const sessionButton = root.querySelectorAll('button').find((button) => button.textContent === 'Inbox')
  assert.ok(sessionButton)
  sessionButton.dispatchEvent({ type: 'click' })
  await flushAsyncWork()

  const input = root.querySelector('#message-input')
  assert.ok(input)
  input.value = 'ping'

  const form = root.querySelector('#composer')
  assert.ok(form)
  form.dispatchEvent({
    type: 'submit',
    preventDefault() {}
  })
  await flushAsyncWork()

  apiCalls.streams.at(-1)?.onmessage?.({
    data: JSON.stringify({
      content: [{ type: 'text', text: 'pong' }]
    })
  })

  const renderedMessages = root.querySelector('#messages')?.children ?? []
  assert.equal(renderedMessages.at(-1)?.textContent, 'assistant: pong')
})

test('stream completion refreshes history so assistant citations appear immediately', async () => {
  const { apiCalls, root, flushAsyncWork } = await renderApp({
    sessions: [{ id: 'session-1', title: 'Inbox', user_id: 'alice' }],
    messagesBySession: {
      'session-1': [
        {
          id: 'user-1',
          role: 'user',
          content: 'Find documents related to music',
          created_at: '2026-04-12T00:00:00Z',
          citations: []
        },
        {
          id: 'assistant-1',
          role: 'assistant',
          content: 'I found these music-related documents.',
          created_at: '2026-04-12T00:00:01Z',
          citations: ['/Music/example.url']
        }
      ]
    }
  })

  await flushAsyncWork()

  const sessionButton = root.querySelectorAll('button').find((button) => button.textContent === 'Inbox')
  assert.ok(sessionButton)
  sessionButton.dispatchEvent({ type: 'click' })
  await flushAsyncWork()

  const input = root.querySelector('#message-input')
  assert.ok(input)
  input.value = 'Find documents related to music'

  const form = root.querySelector('#composer')
  assert.ok(form)
  form.dispatchEvent({
    type: 'submit',
    preventDefault() {}
  })
  await flushAsyncWork()

  apiCalls.streams.at(-1)?.onmessage?.({
    data: JSON.stringify({
      content: [{ type: 'text', text: 'I found these music-related documents.' }]
    })
  })
  apiCalls.streams.at(-1)?.onerror?.({ type: 'error' })
  await flushAsyncWork()
  await flushAsyncWork()

  const renderedMessages = root.querySelector('#messages')?.children ?? []
  assert.match(renderedMessages.at(-1)?.textContent ?? '', /assistant: I found these music-related documents\./)
  assert.equal(renderedMessages.at(-1)?.children.length, 1)
  assert.match(renderedMessages.at(-1)?.children[0]?.textContent ?? '', /Sources: \/Music\/example\.url/)
})

async function loadAppModule() {
  const bundlePath = path.resolve('ui/dist/app.js')
  const bundled = await readFile(bundlePath, 'utf8')
  const rewritten = bundled
    .replace('function openStream(sessionId) {', 'function openStream(sessionId) { return globalThis.__appTestOpenStream(sessionId); }\nfunction __unused_openStream(sessionId) {')
    .replace(/var root = document\.getElementById\("app"\);[\s\S]*$/, '')

  return import(`data:text/javascript,${encodeURIComponent(`${rewritten}\nexport { mountApp };`)}`)
}

async function renderApp(fixtures) {
  const root = new TestElement('div')
  const document = createDocument()
  const apiCalls = {
    createSession: [],
    sendMessage: [],
    openStream: [],
    closeStream: [],
    streams: []
  }

  globalThis.document = document
  globalThis.__appTestApiCalls = apiCalls
  globalThis.__appTestFixtures = {
    sessions: fixtures.sessions ?? [],
    createdSession: fixtures.createdSession,
    messagesBySession: fixtures.messagesBySession ?? {}
  }
  globalThis.fetch = async (url, options = {}) => {
    const method = options.method ?? 'GET'

    if (url === '/api/v1/chat/sessions' && method === 'GET') {
      return jsonResponse(globalThis.__appTestFixtures.sessions)
    }

    if (url === '/api/v1/chat/sessions' && method === 'POST') {
      const payload = JSON.parse(options.body ?? '{}')
      apiCalls.createSession.push(payload.title)
      return jsonResponse(globalThis.__appTestFixtures.createdSession ?? { id: 'created-session', title: payload.title, user_id: 'alice' })
    }

    const messageMatch = String(url).match(/^\/api\/v1\/chat\/sessions\/([^/]+)\/messages$/)
    if (messageMatch && method === 'GET') {
      return jsonResponse(globalThis.__appTestFixtures.messagesBySession[messageMatch[1]] ?? [])
    }

    if (messageMatch && method === 'POST') {
      const payload = JSON.parse(options.body ?? '{}')
      apiCalls.sendMessage.push({ sessionId: messageMatch[1], message: payload.message })
      return { ok: true }
    }

    throw new Error(`Unhandled fetch: ${method} ${url}`)
  }
  globalThis.__appTestOpenStream = (sessionId) => {
    apiCalls.openStream.push(sessionId)
    const stream = {
      close() {
        apiCalls.closeStream.push(sessionId)
      },
      onerror: null,
      onmessage: null,
    }
    apiCalls.streams.push(stream)
    return stream
  }

  appModule.mountApp(root)

  return {
    root,
    apiCalls,
    flushAsyncWork,
  }
}

async function flushAsyncWork() {
  await Promise.resolve()
  await Promise.resolve()
  await Promise.resolve()
}

function createDocument() {
  return {
    createElement(tagName) {
      return new TestElement(tagName)
    }
  }
}

function jsonResponse(payload) {
  return {
    ok: true,
    async json() {
      return payload
    }
  }
}

class TestElement {
  constructor(tagName) {
    this.tagName = tagName.toUpperCase()
    this.children = []
    this.parentNode = null
    this.dataset = {}
    this.listeners = new Map()
    this.attributes = new Map()
    this.textContent = ''
    this.value = ''
    this.id = ''
    this.type = ''
  }

  set innerHTML(value) {
    this._innerHTML = value
    this.children = []

    if (!value.includes('Seraph Chat')) {
      return
    }

    const status = this.appendNamedChild(new TestElement('div'), 'status')
    status.attributes.set('role', 'status')

    const newSession = this.appendNamedChild(new TestElement('button'), 'new-session')
    newSession.type = 'button'
    newSession.textContent = 'New Session'

    this.appendNamedChild(new TestElement('ul'), 'sessions')
    this.appendNamedChild(new TestElement('div'), 'messages')
    this.appendNamedChild(new TestElement('form'), 'composer')

    const input = this.appendNamedChild(new TestElement('input'), 'message-input')
    input.attributes.set('name', 'message')
    input.type = 'text'

    const sendButton = new TestElement('button')
    sendButton.type = 'submit'
    sendButton.textContent = 'Send'
    this.querySelector('#composer')?.appendChild(sendButton)
  }

  get innerHTML() {
    return this._innerHTML ?? ''
  }

  appendNamedChild(child, id) {
    child.id = id
    this.appendChild(child)
    return child
  }

  appendChild(child) {
    child.parentNode = this
    this.children.push(child)
    return child
  }

  addEventListener(type, handler) {
    const handlers = this.listeners.get(type) ?? []
    handlers.push(handler)
    this.listeners.set(type, handlers)
  }

  dispatchEvent(event) {
    const handlers = this.listeners.get(event.type) ?? []
    for (const handler of handlers) {
      handler(event)
    }
    return true
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] ?? null
  }

  querySelectorAll(selector) {
    const matches = []
    this.walk((node) => {
      if (selector.startsWith('#')) {
        if (node.id === selector.slice(1)) {
          matches.push(node)
        }
        return
      }

      if (node.tagName === selector.toUpperCase()) {
        matches.push(node)
      }
    })
    return matches
  }

  walk(visitor) {
    for (const child of this.children) {
      visitor(child)
      child.walk(visitor)
    }
  }
}
