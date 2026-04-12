from spaces.access import SpaceScope, filter_allowed_documents


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
