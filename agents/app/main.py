"""
AgentOS
=======

The main entry point for AgentOS.

Run:
    python -m app.main
"""

from contextlib import asynccontextmanager
from os import getenv
from pathlib import Path

from agno.os import AgentOS

from agents.documents_agent import documents_agent
from agents.knowledge_agent import knowledge_agent
from agents.mcp_agent import mcp_agent
from agents.pal import pal, pal_knowledge
from db import get_postgres_db
from ingestion.file_changed_consumer import create_ingestion_service
from knowledge.user_documents import user_documents_knowledge

ingestion_service = create_ingestion_service()


@asynccontextmanager
async def ingestion_lifespan(_app, agent_os=None):
    await ingestion_service.start()
    try:
        yield
    finally:
        await ingestion_service.stop()


# ============================================================================
# Create AgentOS
# ============================================================================
agent_os = AgentOS(
    name="AgentOS",
    tracing=True,
    db=get_postgres_db(),
    agents=[pal, knowledge_agent, documents_agent, mcp_agent],
    knowledge=[pal_knowledge, user_documents_knowledge],
    config=str(Path(__file__).parent / "config.yaml"),
    lifespan=ingestion_lifespan,
)

app = agent_os.get_app()

if __name__ == "__main__":
    agent_os.serve(
        app="main:app",
        reload=getenv("RUNTIME_ENV", "prd") == "dev",
    )
