# Native Direct-Tailnet Pairing

This document defines the v1 native macOS-to-macOS Remote Control onboarding contract.

## Build identity

RepoPrompt release uses TCP port `47391`, URL scheme `repoprompt-ce`, and the `release` Remote Control namespace. Debug uses port `47392`, scheme `repoprompt-ce-debug`, and the `debug` namespace. Trust files, host signing keys, client device keys, and gateway runtime data never cross these namespaces. Existing pre-namespace data is not migrated or deleted.

## Host lifecycle

When Remote Control is enabled, the app runs only `tailscale status --json`, selects the lowest numeric eligible self IPv4 in `100.64.0.0/10`, and starts one packaged gateway listener on that exact address and the channel's fixed port. Missing, stopped, malformed, or address-less Tailscale state makes the host unavailable. There is no loopback, LAN, wildcard, IPv6, MagicDNS, or Tailscale Serve fallback.

The app owns the P-256 host signing key and configures the discovery authority for one gateway launch. The gateway never receives that private key. Disabling, rebinding, failed startup, or process termination clears discovery authority.

## Discovery

A client search reads the visible peers from bounded Tailscale status output and probes each numeric peer address at both fixed build ports:

`POST /.well-known/repoprompt/remote-pairing/v1`

Each request carries v1 kind, a fresh 32-byte nonce, and a build channel. The gateway applies body, rate, concurrency, and app-link timeout limits and derives admission identity only from the direct socket peer.

The app constructs and signs the complete response: nonce, channel, normalized origin, host public key and fingerprint, host/build identity, required capabilities, issue/expiry times, and a random approval context. Clients verify every signed field, require a direct HTTP Tailscale origin at the channel port, reject redirects, and show Tailscale peer identity separately from the signed RepoPrompt host identity.

Search is explicit and never pairs automatically. Selecting **Request Access** performs a fresh probe and requires the same origin, channel, and fingerprint.

## Pairing and approval

The fresh discovery response becomes an in-memory pairing payload. Native pairing sends only `approval_context` to `/api/pair/begin`; it never sends `window_id`. The context is valid for at most 60 seconds, single-use, bounded in storage, and bound to the gateway launch, origin, channel, host fingerprint, discovery nonce, and challenge.

The host routes approval only when exactly one non-closing host window exists. No window, multiple windows, a closing target, cancellation, and user denial remain distinct outcomes. The supplied device ID must match the ID derived from the device public key.

Client device keys are created only after the verified begin response. Discovery and begin failures persist no host trust. A host record is persisted only after proof verification, explicit host approval, and successful pairing completion. Existing ticket, counter, revocation, and reconnect rules remain authoritative after pairing.

## Bounds

- Tailscale process: 5 seconds; 2 MiB combined output.
- Candidates: 256; online or unknown peers only; deterministic numeric order.
- Discovery probes: concurrency 16; 2.5 seconds each; 15 seconds overall; 32 KiB response.
- Gateway discovery request: 2 KiB; four in-flight signing requests.
- Discovery lifetime: at most 60 seconds with bounded clock skew.
