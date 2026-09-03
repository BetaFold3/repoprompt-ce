# Oh My Pi ACP fixtures

- `initialize.json` records the locally observed OMP 17.2.12 initialize identity and capability advertisement.
- `agent_message_chunk.json` is a representative standard ACP message shape used to verify the deliberately thin OMP normalizer.
- `models-17.3.4.json` preserves the exact ordered model selector values observed from an OMP 17.3.4 ACP `session/new` response.
- `models-18.1.3.json` preserves the exact ordered model selector values captured live from OMP 18.1.3 ACP `session/new` on 2026-09-03 after PR #8988 collapsed Cursor Grok 4.5/4.6 effort IDs into base/fast pairs. Follow-up `session/set_config_option` captures observed `thinking` values `off, auto, low, medium, high, xhigh` for `cursor/cursor-grok-4.6` and `cursor/gpt-5.2`, and `off, auto` for `cursor/composer-2.5`.

OMP RepoPrompt-MCP tool event shapes have not been captured. No tool-call fixture here claims otherwise; tool-card canonicalization and release readiness remain gated on live capture.
