from pathlib import Path


def test_dockerfile_builds_ui_in_node_stage() -> None:
    dockerfile = Path(__file__).resolve().parents[1] / "Dockerfile"
    content = dockerfile.read_text()

    assert "FROM node:20" in content
    assert "WORKDIR /ui" in content
    assert "npm ci" in content or "npm install" in content
    assert "npm run build" in content


def test_dockerfile_copies_vite_dist_into_runtime_image() -> None:
    dockerfile = Path(__file__).resolve().parents[1] / "Dockerfile"
    content = dockerfile.read_text()

    assert "COPY --from=ui-builder /ui/dist ./ui/dist" in content


def test_compose_preserves_built_ui_dist_when_source_is_bind_mounted() -> None:
    compose_file = Path(__file__).resolve().parents[1] / "compose.yaml"
    content = compose_file.read_text()

    assert "- .:/app" in content
    assert "- agents-ui-dist:/app/ui/dist" in content
    assert "agents-ui-dist:" in content
