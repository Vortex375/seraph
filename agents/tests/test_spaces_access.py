from spaces.access import SpaceScope, _normalize_path, _path_allowed, filter_allowed_documents


def test_normalize_path_handles_root_and_empty() -> None:
    assert _normalize_path("") == "/"
    assert _normalize_path("/") == "/"
    assert _normalize_path("/team/docs") == "/team/docs"
    assert _normalize_path("team/docs") == "/team/docs"
    assert _normalize_path("/team/docs/") == "/team/docs"


def test_path_allowed_root_scope_allows_any_normalized_path() -> None:
    assert _path_allowed("/", "/") is True
    assert _path_allowed("/", "/a") is True
    assert _path_allowed("/", "/team/docs/spec.md") is True


def test_path_allowed_exact_prefix_match() -> None:
    assert _path_allowed("/team/docs", "/team/docs") is True
    assert _path_allowed("/team/docs/", "/team/docs") is True
    assert _path_allowed("/team/docs", "team/docs") is True


def test_path_allowed_nested_paths() -> None:
    assert _path_allowed("/team/docs", "/team/docs/spec.md") is True
    assert _path_allowed("/team/docs", "/team/docs/archive/spec.md") is True


def test_path_allowed_rejects_prefix_boundary_escape() -> None:
    assert _path_allowed("/team/docs", "/team/docs-archive/spec.md") is False


def test_path_allowed_rejects_path_traversal() -> None:
    assert _path_allowed("/team/docs", "/team/docs/../private/spec.md") is False


def test_filter_allowed_documents_keeps_matching_provider_prefix() -> None:
    scopes = [SpaceScope(provider_id="provider-a", path_prefix="/team/docs")]
    docs = [
        {"provider_id": "provider-a", "path": "/team/docs/spec.md"},
        {"provider_id": "provider-a", "path": "/private/spec.md"},
    ]

    allowed = filter_allowed_documents(scopes, docs)

    assert allowed == [{"provider_id": "provider-a", "path": "/team/docs/spec.md"}]


def test_filter_allowed_documents_rejects_path_traversal_escape() -> None:
    scopes = [SpaceScope(provider_id="provider-a", path_prefix="/team/docs")]
    docs = [
        {"provider_id": "provider-a", "path": "/team/docs/../private/spec.md"},
    ]

    allowed = filter_allowed_documents(scopes, docs)

    assert allowed == []


def test_filter_allowed_documents_rejects_prefix_boundary_escape() -> None:
    scopes = [SpaceScope(provider_id="provider-a", path_prefix="/team/docs")]
    docs = [
        {"provider_id": "provider-a", "path": "/team/docs-archive/spec.md"},
    ]

    allowed = filter_allowed_documents(scopes, docs)

    assert allowed == []
