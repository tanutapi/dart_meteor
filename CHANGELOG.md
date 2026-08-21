# 4.2.0

DDP session resumption, matching
[meteor/meteor#14051](https://github.com/meteor/meteor/pull/14051) (merged
2026-03-06).

Added:
- After an unexpected disconnect the client keeps its DDP session id and asks
  the server to resume it, sending `session` and `receivedCount` in `connect`.
  When the server agrees (same session id back) the login and subscriptions
  carry on untouched, messages published during the gap arrive in order, and
  `onReconnect` callbacks are not run. When it does not, the reconnect
  proceeds exactly as before: callbacks and re-subscribe.
- `DdpClient.resumedSession` reports whether the latest `connected` resumed
  the previous session; `DdpClient.receivedCount` exposes the message count.
- `disconnect()` sends a DDP `disconnect` message before closing the socket so
  the server drops the session at once instead of keeping it for the grace
  period.

Changed:
- In-flight method calls are failed once the reconnect completes (resumed or
  not), on an explicit `disconnect()`, or when the retry limit is reached,
  rather than the instant the socket drops. They still fail: a request sent
  just before the drop may never have reached the server, and that cannot be
  told apart from a slow method, so hanging forever is not an option.

Compatibility:
- Servers without session resumption ignore the extra fields and start a new
  session, so behaviour against them is unchanged.

# 4.1.0

Connection lifecycle fixes. The theme is a device that goes to sleep: the
process is suspended, timers stop, and the server drops the session without the
socket ever reporting an error.

Fixed:
- A missed `pong` left the client permanently offline. The pong timeout called
  `disconnect()`, which also disabled reconnection, so no retry was ever
  scheduled — the exact path a device takes when it wakes with a stale socket.
- Reconnect backoff never engaged. `retryCount` was reset on every connection
  attempt, so the computed interval was always 0s and `maxRetryCount` was never
  reached, producing a tight reconnect loop. The counter is now reset only once
  the server accepts the connection.
- Connecting to an unreachable server raised an **unhandled** exception that
  could terminate the application, because `WebSocketChannel.connect` fails
  asynchronously rather than throwing. The client now awaits `ready` and routes
  the failure into its normal retry path.
- A method call that was in flight when the connection dropped never completed.
  Pending calls are now completed with the new `MeteorConnectionError`.
- Subscriptions were re-sent before the login token was resumed, so
  publications depending on `this.userId` re-ran unauthenticated after every
  reconnect. Re-subscription now waits for the `onReconnect` callbacks.
- `disconnect()` did not cancel a pending reconnect timer, so an explicit
  disconnect could be undone by a retry that was already scheduled.
- `status()` emitted the client's own mutable status object, so a fast
  transition could be misread by subscribers. Each event is now a snapshot.

Added:
- `meteor.notifyAppPaused()` / `meteor.notifyAppResumed()` and
  `meteor.checkLiveness()`. On resume the client compares the wall clock
  against the last message received and replaces a stale connection
  immediately, instead of waiting for a ping to time out. The package stays
  pure Dart; the Flutter `WidgetsBindingObserver` glue is a few lines shown in
  the README and in `example/`.
- Configurable `pingInterval`, `pongTimeout`, `maxRetryInterval` and
  `stalenessThreshold` on `MeteorClient.connect` and `DdpClient`.
- `test/lifecycle_test.dart`, a server-free regression suite for the above; the
  mock DDP server moved to `test/mock_ddp_server.dart` so both suites share it.

Behaviour changes to be aware of when upgrading:
- `await meteor.call(...)` can now throw `MeteorConnectionError` where it
  previously hung forever. In-flight calls are **not** retried automatically,
  since methods are not necessarily idempotent.
- Reconnect attempts are spaced out rather than immediate.
- `onReconnect` callbacks may now return a `Future`, which is awaited before
  subscriptions are re-sent.

# 4.0.0
- Support for the latest Dart/Flutter releases (tested with Dart 3.13). The minimum SDK is now Dart 3.6.
- Verified compatibility with Meteor 3.x servers, including Meteor 3.5.1 (DDP protocol version 1, SHA-256 password login, EJSON `$date` handling).
- Web platform support from the 4.0.0 betas via `web_socket_channel` is included.
- Added a standalone DDP protocol test suite (`test/ddp_mock_server_test.dart`) that runs without a Meteor server or docker.
- Updated dependencies and lint rules (`lints` 6).
- BREAKING: `DdpClient.PING_SEC_INTERVAL` and `DdpClient.PONG_WITHIN_SEC` were renamed to the static constants `DdpClient.pingIntervalSeconds` and `DdpClient.pongTimeoutSeconds`.

# 4.0.0-beta.1, 4.0.0-beta.2
- Adding Web platform support by using the `web_socket_channel`.

# 3.0.0
- BREAKING CHANGE. The `meteor.collection('collectionName')` streams are now `hasData == true` and have an empty map at the beginning.
# 2.1.4
- Acessing to serverId and sessionId
# 2.1.3
- Resend subscription packets on reconnection.
# 2.1.2
- Return MeteorClientLoginResult on logoutOtherClients.
# 2.1.1
- Return null if no current value presents for the 'currentValue'.
# 2.1.0
- Fix a major bug on escaping DateTime when doing method call and subscribe.
# 2.0.4
- Fix bug on meteor.user() does not set back to null after user has been logged out.
## 2.0.3
- Separated login function.

## 2.0.2
- Fix bugs on connecting to Meteor 2.x.x and on logout function.

## 2.0.1
- Fix a $date bug when parsing an array result from methods/collections.

## 2.0.0
- Null safety and some API changes.

## 1.1.2
- Lower crypto package version to match the flutter_test.

## 1.1.1
- Allows both int and String for MeteorError.error

## 1.1.0

- Pin rxdart to 0.24.1 and crypto to 2.1.5.

## 1.0.8

- Allow passing email to loginWithPassword.

## 1.0.7

- **Don't use this release**

## 1.0.5 - 1.0.6

- Pin rxdart version to 0.22.6

## 1.0.1 - 1.0.4

- Update README and example

## 1.0.0 - 1.0.3

- Initial version.
