from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_pyproject_no_longer_references_agno_and_obsolete_modules_are_removed() -> None:
    pyproject = (ROOT / "pyproject.toml").read_text(encoding="utf-8")

    assert "agno" not in pyproject
    assert "agentscope" in pyproject

    obsolete_paths = [
        ROOT / "agents" / "documents_agent.py",
        ROOT / "agents" / "knowledge_agent.py",
        ROOT / "agents" / "mcp_agent.py",
        ROOT / "agents" / "pal.py",
        ROOT / "knowledge" / "user_documents.py",
    ]

    for path in obsolete_paths:
        assert not path.exists(), f"{path} should be removed"
