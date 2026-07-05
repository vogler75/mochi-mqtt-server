# MQTT Spec Compliance — Improvement Points

Findings from a deep audit of this broker against MQTT 3.1.1 and MQTT 5.0 (2026-07-04).
The core protocol machinery (QoS 0/1/2 flows, flow control, session lifecycle, topic
aliases, shared subscriptions, retained messages, wire codec) is substantially compliant.
The items below are the verified gaps and improvement opportunities.

---

## 1. Advertise server capabilities in CONNACK (HIGH — biggest compliance gap)

**Where:** `SendConnack()` — `server.go:610`

CONNACK currently only emits Receive Maximum, Server Keep Alive, Maximum QoS (when < 2),
Assigned Client ID, and Session Expiry override. It never encodes:

- `Topic Alias Maximum` — absence means **0** per spec, so conformant v5 clients will
  never send topic aliases even though the broker supports 65,535 of them
  (`Capabilities.TopicAliasMaximum`, `server.go:78`). Inbound aliasing is effectively
  dark for well-behaved clients.
- `Maximum Packet Size` — if configured, it is enforced on read (`clients.go:456`)
  but never advertised; clients get disconnected for a limit they were never told about.
- `Retain Available`, `Wildcard Subscription Available`, `Shared Subscription Available`,
  `Subscription Identifier Available` — all configurable in `Capabilities`
  (`server.go:58-64`) and enforced (e.g. will-retain rejection at `server.go:555`),
  but never advertised. With non-default configs (any of these set to 0) the broker
  is non-compliant, because clients are entitled to rely on the spec defaults (= available).

**Fix:** in `SendConnack`, encode `TopicAliasMaximum`, `MaximumPacketSize` (when > 0),
and each availability flag whenever the capability is disabled (value 0).

## 2. Accept zero-length Will payloads (MEDIUM)

**Where:** `ConnectValidate()` — `packets/packets.go:483`

```go
if len(pk.Connect.WillPayload) == 0 || pk.Connect.WillTopic == "" {
    return ErrProtocolViolationWillFlagNoPayload
}
```

Both 3.1.1 and 5.0 require the Will fields to be *present*, but a zero-byte Will
Message payload is legal (commonly used to clear retained state via LWT). This check
rejects valid CONNECT packets. Only the empty-topic check should remain.

## 3. Validate the Will topic for wildcards (LOW)

**Where:** `ConnectValidate()` — `packets/packets.go:482-490`

Will QoS and retain are validated, but the Will topic is not checked for `+` / `#`.
A will topic like `lwt/#` is accepted at CONNECT and later published as a topic name,
violating [MQTT-4.7.1-1]. Add a wildcard rejection check.

## 4. Reject CONNECT with unsupported Authentication Method (MEDIUM)

**Where:** `processAuth()` — `server.go:1385`; CONNECT handling in `establishConnection`

Enhanced authentication (AUTH, MQTT 5.0) is delegated entirely to the `OnAuthPacket`
hook. Enhanced auth itself is optional, but the rejection path is not: a CONNECT
carrying an `Authentication Method` the server does not support MUST be answered with
CONNACK 0x8C (Bad authentication method). Currently it is silently accepted.

Longer-term: add a first-class enhanced-auth flow (challenge/response state machine,
AUTH timing validation, reason codes 0x18 Continue Authentication / 0x19 Re-authenticate)
around the existing hook.

## 5. Reject duplicate MQTT 5 properties (MEDIUM)

**Where:** properties decoder — `packets/properties.go:393-472`

A repeated non-User property is a Protocol Error per MQTT 5.0; the decoder currently
overwrites the previous value silently (e.g. `SessionExpiryInterval`). Track seen
property IDs during decode and return a protocol error on duplicates, with the
User Property exception.

## 6. Smaller validation gaps (LOW)

- **Zero-length client ID + CleanSession=0 (v3.1.1):** returns a generic unspecified
  error instead of CONNACK 0x02 "identifier rejected" (`server.go:547`).
- **Oversized outbound packets:** correctly dropped when exceeding the client's
  Maximum Packet Size (`clients.go:598`), but no DISCONNECT 0x95 is sent — permitted
  by spec, but silent drops complicate client-side debugging.
- **Range checks:** `RequestResponseInfo` and `RetainAvailable` property bytes are not
  validated to be 0/1 on decode.

## 7. Performance opportunities (non-correctness)

- **`NextPacketID`** (`clients.go:276`): linear probe over the inflight map under lock.
  Fine at default limits; a free-list would make it O(1).
- **`publishToClient`** (`server.go:1046`): subscription identifiers are re-sorted with
  `sort.Ints` on every message delivery; they could be sorted once at subscribe time.

---

## Verified as correct (false alarms during audit — do not "fix")

- Clearing the retain flag when forwarding to v3 subscribers (`server.go:1035`) is
  exactly what [MQTT-3.3.1-9] requires.
- QoS 2 duplicate handling uses spec "Method B" (reject duplicate PUBLISH with
  `ErrPacketIdentifierInUse` while PUBREC is outstanding) — compliant.
- Subscription identifier handling is correct despite the `[]int` property type.
- Retransmission only on session resume with DUP=1 is correct v5 behavior.
