# Capability: Agent direct file tools enforce user space scoping

## Purpose

Ensure agent direct file tools such as `list_directory`, `stat_file`, and
`read_file_excerpt` authorize every request against the Seraph space scopes
available to the current user and consistently normalize paths.

> **TBD:** Expand purpose as capability matures.

## Requirements

### Requirement: Direct file tools allow paths inside accessible spaces

The agent's direct file tools (`list_directory`, `stat_file`, and
`read_file_excerpt`) SHALL allow access when the requested
`(provider_id, path)` is within at least one space scope returned for the
user.

#### Scenario: Stat a file inside a nested scope

- **WHEN** the user has a scope `(provider_id="test", path_prefix="/wallpaper")`
  and calls `stat_file(provider_id="test", path="/wallpaper/round_moons_nasa.jpg")`
- **THEN** the tool returns file metadata without raising a permission error

#### Scenario: List a directory inside a nested scope

- **WHEN** the user has a scope `(provider_id="test", path_prefix="/wallpaper")`
  and calls `list_directory(provider_id="test", path="/wallpaper")`
- **THEN** the tool returns the directory entries without raising a permission
  error

#### Scenario: Read a file inside a nested scope

- **WHEN** the user has a scope `(provider_id="test", path_prefix="/wallpaper")`
  and calls `read_file_excerpt(provider_id="test",
  path="/wallpaper/round_moons_nasa.jpg")`
- **THEN** the tool returns the requested excerpt without raising a permission
  error

#### Scenario: Root scope allows nested paths

- **WHEN** the user has a scope `(provider_id="test", path_prefix="/")` and
  calls any direct file tool with `provider_id="test"` and a normalized
  absolute path
- **THEN** the tool proceeds without raising a permission error

#### Scenario: Exact prefix match is allowed

- **WHEN** the user has a scope `(provider_id="test", path_prefix="/wallpaper")`
  and calls `stat_file(provider_id="test", path="/wallpaper")`
- **THEN** the tool returns directory metadata without raising a permission
  error

### Requirement: Direct file tools reject paths outside accessible spaces

The agent's direct file tools SHALL raise `PermissionError` when the requested
`(provider_id, path)` is not within any space scope returned for the user.

#### Scenario: Path outside scope prefix is rejected

- **WHEN** the user has a scope `(provider_id="test", path_prefix="/wallpaper")`
  and calls `stat_file(provider_id="test", path="/private/file.txt")`
- **THEN** the tool raises `PermissionError` with the message "requested path is
  outside accessible scopes"

#### Scenario: Path on a different provider is rejected

- **WHEN** the user has a scope `(provider_id="test", path_prefix="/wallpaper")`
  and calls `stat_file(provider_id="other", path="/wallpaper/file.txt")`
- **THEN** the tool raises `PermissionError` with the message "requested path is
  outside accessible scopes"

#### Scenario: Prefix boundary escape is rejected

- **WHEN** the user has a scope `(provider_id="test", path_prefix="/wallpaper")`
  and calls `stat_file(provider_id="test", path="/wallpaper-private/file.txt")`
- **THEN** the tool raises `PermissionError` with the message "requested path is
  outside accessible scopes"

### Requirement: Path normalization is consistent across tools

All direct file tools SHALL normalize request paths using the same rules before
authorization and before passing the path to the file provider.

#### Scenario: Relative path is normalized before authorization

- **WHEN** the user has a scope `(provider_id="test", path_prefix="/wallpaper")`
  and calls `stat_file(provider_id="test",
  path="wallpaper/round_moons_nasa.jpg")`
- **THEN** the tool treats the path as `/wallpaper/round_moons_nasa.jpg` and
  proceeds without raising a permission error

#### Scenario: Trailing slash does not affect authorization

- **WHEN** the user has a scope `(provider_id="test", path_prefix="/wallpaper")`
  and calls `list_directory(provider_id="test", path="/wallpaper/")`
- **THEN** the tool proceeds without raising a permission error

#### Scenario: Path traversal is rejected during normalization

- **WHEN** the user calls any direct file tool with a path containing `..` that
  would escape the accessible scope
- **THEN** the tool raises `PermissionError` with the message "requested path is
  outside accessible scopes"
