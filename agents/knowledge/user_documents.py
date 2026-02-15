"""
User Documents Knowledge Base
=============================

Semantic knowledge base for user documents.
"""

from agno.knowledge import Knowledge
from agno.knowledge.embedder.openai import OpenAIEmbedder
from agno.vectordb.pgvector import PgVector, SearchType

from db import db_url

user_documents_knowledge = Knowledge(
    name="User Documents",
    vector_db=PgVector(
        db_url=db_url,
        table_name="user_documents_kb",
        search_type=SearchType.hybrid,
        embedder=OpenAIEmbedder(id="text-embedding-3-small"),
    ),
    max_results=10,
)
