# Implementation Findings

This file captures concrete improvement work identified during the project review.

## Priority 1: Correctness and Concurrency

### Avoid nested `RWMutex` acquisition in `Clients.GetByListener`

- Location: `clients.go:92`
- Problem: `GetByListener` holds `cl.RLock()` and then calls `cl.Len()`, which attempts to acquire `cl.RLock()` again. Go's `sync.RWMutex` blocks new readers while a writer is waiting, so this pattern can deadlock.
- Implementation: allocate the result slice using `len(cl.internal)` while already holding the lock.
- Test: add a small regression test that exercises `GetByListener` while a writer is pending, or keep the change simple and cover with `go test -race ./...`.

### Move listener client `WaitGroup` accounting to the goroutine boundary

- Location: `server.go:407`
- Problem: `s.Listeners.ClientsWg.Add(1)` happens inside `attachClient`, after listener code has already spawned a goroutine. `CloseAll().Wait()` can race with a newly accepted connection before the counter is incremented.
- Implementation: increment before starting the goroutine that calls `EstablishConnection`, or introduce a listener/server helper that wraps establish calls with `Add` and `Done`.
- Test: add a close-during-accept/establish regression test and run with `-race`.

### Make `Server.Close` idempotent

- Location: `server.go:1496`
- Problem: `Close` directly calls `close(s.done)`, so a second public `Close()` call panics.
- Implementation: add `sync.Once` or an atomic closed flag to guard the close path. Preserve hook/listener shutdown ordering.
- Test: add a test that calls `Close()` twice and expects no panic.

### Reserve maximum-client capacity atomically

- Location: `server.go:419` and `server.go:452`
- Problem: maximum-client enforcement checks `ClientsConnected` before incrementing it. Concurrent new connections can all pass the check before any increment occurs.
- Implementation: reserve a slot atomically before auth/session setup, reject if it exceeds `MaximumClients`, and release the reservation on failure or disconnect.
- Test: add a concurrent connection test with `MaximumClients` set low and run under `-race`.

## Priority 2: Test Reliability

### Remove fixed port bindings from tests

- Location: `server_test.go:270`
- Problem: `TestServerAddListenersFromConfig` binds `:1883`, `:1882`, `:1881`, and `:1880`. The suite fails on developer machines or CI runners where those ports are in use.
- Implementation: use `127.0.0.1:0` for network listeners and assert the listener protocol/id plus non-empty assigned address. For tests that require exact config address preservation, use mock listeners or do not call `Init`.
- Verification observed: `go test ./...` failed locally because `:1883` was already in use.

### Investigate full-suite takeover flake

- Location: `server_test.go:677`
- Problem: `TestEstablishConnectionInheritExistingTrueTakeover` failed once during the full suite, but passed in isolation with `-race -count=5`.
- Implementation: inspect shared packet test data mutation around `RawBytes`, reduce sleeps, and prefer explicit synchronization over timing assumptions.
- Verification observed: `go test -race -run TestEstablishConnectionInheritExistingTrueTakeover -count=5 -v .` passed.

## Priority 3: Security and Maintenance

### Patch Go toolchain used for builds and CI

- Problem: `govulncheck ./...` reported reachable standard-library vulnerabilities when run with local `go1.26.0`; fixes are in `go1.26.1` and `go1.26.2`.
- Implementation: update local/CI/build Go versions to a patched release and add `govulncheck` to CI.
- Verification observed: `go vet ./...` passed, but `govulncheck` exited non-zero due to standard-library findings.

### Refresh stale dependencies deliberately

- Direct dependencies with available updates observed via `go list -m -u all`:
  - `github.com/dgraph-io/badger/v4`: `v4.2.0 -> v4.9.1`
  - `go.etcd.io/bbolt`: `v1.3.5 -> v1.4.3`
  - `github.com/gorilla/websocket`: `v1.5.0 -> v1.5.3`
  - `github.com/stretchr/testify`: `v1.8.1 -> v1.11.1`
- Implementation: update in small batches by storage backend/test surface, run `go test ./...`, then run `govulncheck ./...`.

### Make websocket origin policy configurable

- Location: `listeners/websocket.go:50`
- Problem: `CheckOrigin` always returns `true`. That may be acceptable for non-browser MQTT clients, but it is risky for deployments exposed to browser-originated websocket traffic.
- Implementation: add a config hook or explicit allowed-origins setting while preserving the current permissive default only when configured.
- Test: add websocket upgrade tests for allowed and denied origins.

