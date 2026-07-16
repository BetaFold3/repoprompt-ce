# Remote Relay Contract

Status: Phase 3 / M7 contract only. This document freezes the implementation-facing boundary for a future WAN relay or native companion without adding a relay runtime, APNs entitlement, native companion target, or gateway packaging change in this repository.

## Scope

The repository-owned contract is `Sources/RepoPromptGateway/Relay/RemoteRelayClient.swift`:

- `RemoteRelayClient` defines connect, send, inbound-envelope stream, and disconnect operations.
- `RelayCredential` is an opaque relay-transport credential only.
- `EncryptedRelayEnvelope` is the only relay payload shape: routing metadata plus encrypted bytes.

No first-party relay service, managed-provider adapter, outbound WSS implementation, APNs integration, or native companion application is implemented by M7.

## Relay modes

RepoPrompt Remote Control can use the same app-owned trust model through multiple reachability modes:

1. **Tunnel-only / bring-your-own network** — the existing gateway remains reachable through loopback, tailnet, or an HTTPS tunnel. No relay protocol is involved.
2. **Managed realtime provider** — a provider may supply fanout, presence, or mailbox semantics, but RepoPrompt still owns device pairing, tickets, scopes, revocation, idempotency, and audit semantics.
3. **First-party relay** — a future service may move encrypted envelopes and assist discovery. Operating that service adds uptime, abuse-prevention, key-rotation, and versioning responsibilities, but it still does not become a RepoPrompt trust authority.

All modes preserve the same security boundary: reachability is separable from RepoPrompt authorization.

## End-to-end envelope

Relay traffic is carried as `EncryptedRelayEnvelope`:

```swift
struct EncryptedRelayEnvelope: Codable, Sendable {
    let channelID: String
    let senderDeviceID: String
    let recipientID: String
    let nonce: Data
    let ciphertext: Data
}
```

The relay-visible fields are limited to channel/routing metadata:

- `channelID` — relay routing channel or mailbox identifier.
- `senderDeviceID` — paired device identity namespace used for routing/audit correlation.
- `recipientID` — host or device recipient identifier.
- `nonce` — nonce for the E2E encryption layer.
- `ciphertext` — encrypted remote-control frame bytes.

The plaintext is a gateway/companion concern, not a relay concern. A future implementation derives E2E encryption keys from the existing host/device pairing keys:

1. Host and device use their paired P-256 key material for ECDH agreement.
2. The shared secret is expanded with HKDF using transcript-bound salt/info that includes the pairing identities and relay channel context.
3. Derived keys encrypt/decrypt the remote frame payload before it is wrapped in `EncryptedRelayEnvelope`.
4. Relay implementations forward envelopes without decrypting, rewriting, signing on behalf of devices, or interpreting the remote-control frame inside `ciphertext`.

## Relay security boundary

A relay may:

- authenticate clients for relay transport access using `RelayCredential`;
- route by `channelID`, `senderDeviceID`, and `recipientID`;
- store and forward encrypted envelopes when the selected relay mode requires mailbox behavior;
- expose availability or delivery metadata needed by the gateway or companion.

A relay must not:

- mint RepoPrompt pairing records, tickets, scopes, or app credentials;
- approve devices or bypass the app consent flow;
- change revocation state;
- decrypt, inspect, or mutate remote-control frame plaintext;
- replay mutations as if they were new client commands;
- replace gateway `CommandLedger`, app-side idempotency, or gateway audit responsibilities.

The RepoPrompt app remains the trust authority. It owns host keys, paired-device records, consent, ticket minting, scope grants, and revocation. The gateway remains responsible for enforcing tickets, signatures, scopes, command idempotency, and remote audit semantics before translating to MCP.

`RelayCredential` authenticates only to the relay transport. It is not a Remote Control ticket and carries no RepoPrompt scopes.

## Native companion and APNs prerequisites

Native companion and APNs work is explicitly future or out-of-repo for this phase. Before any native companion lands in this repository, a separate plan must cover:

- a native app target and lifecycle model;
- APNs entitlement, provisioning profile, bundle identifier, signing, and release-process changes;
- device-token registration and rotation;
- push payload privacy rules equivalent to the current Web Push identifier-only contract;
- UX for pairing, host fingerprint display, scope consent, revocation, and lost-device recovery;
- packaging and CI validation for the new target.

M7 makes no changes to `Scripts/package_app.sh`, app entitlements, provisioning, or release artifact layout.
