# 06 — Gallery service and Gallery Source Folder configuration

**What to build:** A user can choose which folders in Seraph feed Gallery Mode,
using the folder picker they already know from the file browser. The choice is
stored against their account on the server, so a second device and the web UI
see the same set. Removing a folder from the set never deletes a file.

This ticket stands up the new `gallery` service and takes one narrow path all
the way through it — configuration only, no photos yet. The service follows the
shape already established by `spaces` and `shares`: its own Go module, `fx`
wiring, MongoDB with the existing migrations mechanism, logging and tracing
wired the same way, NATS request/reply for its API. The api-gateway gains
authenticated endpoints that fan out to it, following the existing spaces and
search endpoints.

**Gallery Source Folders are stored in Space terms** — `(spaceProviderId, path)`
— exactly as the user picked them. Storing them physically would force the app
to translate before saving and would silently invalidate the configuration
whenever an administrator re-mounted a Space.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] A user can list, add and remove their Gallery Source Folders through the gateway
- [ ] Folders are stored per user in Space terms, and one user's folders are never visible to another
- [ ] Adding a folder the user has no access to is refused
- [ ] Adding the same folder twice is idempotent rather than producing a duplicate
- [ ] Removing a folder deletes no files and touches no File Provider
- [ ] The app offers folder selection through the existing folder picker and shows the current set
- [ ] The same set is visible from a second signed-in device
- [ ] The service reads no other service's collections
- [ ] Covered at the gallery service's NATS boundary following the `spaces` integration test pattern — embedded NATS, MongoDB testcontainer, `fxtest` lifecycle — plus a narrow gateway test for authentication and request validation following the search test pattern
