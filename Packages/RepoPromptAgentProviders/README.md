# RepoPromptAgentProviders

Repo-local staging package for provider code that can later be split into an external repository.

Current public product:

- `RepoPromptClaudeCompatibleProvider` — Foundation-first DTO, codec, and translator scaffolding for Claude-compatible providers.

This package intentionally does **not** import the RepoPrompt app target. The root app currently imports the package through the documented bridge seam (`ClaudeCompatibleProviderRuntimeBridge` and `ClaudeCompatiblePluginBridge`) and delegates Foundation-only DTO/codec/catalog/prompt-delivery/headless-argument logic to it. The app still owns persistence, secure storage, transcript mutation, permission matching, native process control, and runtime construction.

## Local development

For now this package lives under `Packages/RepoPromptAgentProviders`. From the repository root, use the coordinated package test lane:

```bash
make dev-provider-test
```

Use direct package-local `swift test` only when the developer daemon is unavailable, as described in the [development workflow](../../docs/context/workflows/development.md).

When this package is split out, prefer SwiftPM/Xcode local package overrides for sibling-checkout development rather than requiring a path dependency in RepoPrompt CE's root manifest.

## Architecture reference

See `docs/architecture/provider-plugins.md` in the RepoPrompt CE repo for the full plugin seam contract: bridge/adapter responsibilities, the provider-neutral native runtime contract, core-vs-plugin ownership, and the recipe for adding a new provider product.
