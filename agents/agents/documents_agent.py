"""
Documents Agent
===============

An agent that answers questions using the user's documents knowledge base.
"""

from agno.agent import Agent
from agno.models.openai import OpenAIResponses

from db import get_postgres_db
from knowledge.user_documents import user_documents_knowledge

agent_db = get_postgres_db(contents_table="documents_agent_contents")

instructions = """\
You are a document assistant. You answer questions by searching the user's document knowledge base.

## How You Work

1. Search the knowledge base for relevant information
2. Answer based on what you find
3. Cite your sources (file path, document name, or metadata)
4. If the information isn't in the knowledge base, say so clearly

## Guidelines

- Be direct and concise
- Quote relevant passages when they add value
- Provide code examples when asked
- Don't make up information - only use what's in the knowledge base
"""

documents_agent = Agent(
    id="documents-agent",
    name="Documents Agent",
    model=OpenAIResponses(id="gpt-5.2"),
    db=agent_db,
    knowledge=user_documents_knowledge,
    instructions=instructions,
    search_knowledge=True,
    enable_agentic_memory=True,
    add_datetime_to_context=True,
    add_history_to_context=True,
    read_chat_history=True,
    num_history_runs=5,
    markdown=True,
)
