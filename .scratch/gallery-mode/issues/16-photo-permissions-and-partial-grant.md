# 16 — Photo permissions and partial-grant degraded mode

**What to build:** The app asks for photo access with an explanation of what it
is for, and handles every answer honestly — including the awkward one.

Under Android 14's partial media grant, the user hands over a hand-picked set of
photos rather than the library. The app runs in a **clearly-degraded mode with a
visible warning** rather than blocking. **It must never report completeness it
cannot verify** — under partial access it can only see the photos it was given,
so "everything is backed up" would be a lie. Any summary of backup coverage must
say what it cannot see.

Refusing access entirely leaves the cloud-only gallery fully working; one
declined permission must not disable the feature.

**Blocked by:** 15

**Status:** ready-for-agent

- [ ] The permission request is preceded by an explanation of what access is used for
- [ ] With full access, the gallery behaves as in the previous ticket
- [ ] With a partial grant, the app works on the photos it can see and shows a persistent, comprehensible warning that it cannot see the rest
- [ ] Under a partial grant, no summary, badge or message states or implies that everything is backed up
- [ ] Under a partial grant, the user is offered a way to grant full access or to extend the selection
- [ ] With access denied, the cloud-only gallery works fully and the device half is absent rather than broken
- [ ] Changing the grant while the app is running is picked up without requiring a restart
- [ ] Covered at the app's mirror seam by driving the fake Local Source through each grant state and asserting on what the gallery reports about coverage
