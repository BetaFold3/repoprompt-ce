# Cursor ACP wire fixtures

Captured from `cursor-agent 2026.07.23-e383d2b` on 2026-08-05 by a
session-local Python 3 probe. The probe spawned
`cursor-agent --approve-mcps acp`, exchanged newline-delimited JSON-RPC over
stdio, and did not send `session/prompt`.

`legacy_session_new.json` omits the parameterized-model capability.
`capability_session_new.json` sends
`clientCapabilities._meta.parameterizedModelPicker: true`. The remaining
fixtures capture model-selector growth, model-switch shrinkage, a parameter
mutation echo, validation errors, and `cursor/list_available_models`.
The catalog response was also requested without the capability flag and its
`result` was identical.

The session ID was replaced with `cursor-acp-fixture-session`; no home paths or
usernames were present. Session creation inherited the pre-existing
`gpt-5.6-sol` model rather than Auto, so the two session fixtures intentionally
retain that live `currentValue`.

For the mutation fixture, the pre-existing `gpt-5.6-sol` reasoning value was
`medium`, the probe temporarily selected `high`, and the echoed restore
confirmed `medium` before shutdown. The probe never changed `fast`.
