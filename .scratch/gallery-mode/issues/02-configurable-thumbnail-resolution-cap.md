# 02 — Raise and make configurable the thumbnail resolution cap

**What to build:** A person with a recent phone should get thumbnails for their
highest-resolution photos like any other. Today the thumbnailer rejects any
image whose dimensions exceed 8120 pixels outright, so a 108 MP photo
(12000×9000) or Samsung's 200 MP mode (16320×12240) becomes a broken tile —
exactly the photos a user most wants to see.

The cap legitimately bounds decode memory, so it stays; its current value is
simply wrong for phones shipping today. Raise the default and make the limit
configurable so an administrator can trade memory against coverage on their own
hardware.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] The maximum thumbnailable width and height are read from configuration, with a documented default well above current flagship phone resolutions
- [ ] An image within the new cap that the old cap rejected now produces a thumbnail
- [ ] An image beyond the configured cap is still refused, with a clear reason rather than a generic failure
- [ ] The refusal reason is distinguishable by callers from "this format is not supported" and from "this file is corrupt"
- [ ] Covered by the existing thumbnailer tests with fixtures at both sides of the boundary
