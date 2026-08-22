# dart_meteor — a Meteor DDP client for Dart/Flutter

![](https://github.com/tanutapi/dart_meteor/workflows/Testing/badge.svg?branch=master)

Connect your Flutter app to a [Meteor](https://www.meteor.com/) backend over DDP.
Designed to work seamlessly with `StreamBuilder` and `FutureBuilder`.

- **Platforms:** Dart VM, Flutter iOS/Android/Web
- **Dart:** 3.6 or newer
- **Meteor:** compatible with Meteor 2.x and 3.x servers (tested against Meteor 3.5.1)

## Features

- Method calls with `Future`-based results
- Subscriptions and reactive collections as `Stream`s
- Accounts: login with password/token, logout, password management
- Automatic reconnection with backoff, re-login and re-subscription
- App lifecycle aware: detects a connection that died while the device slept
- `DateTime` values are converted to/from EJSON `$date` automatically

## Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  dart_meteor: ^4.2.0
```

## Quick start

Create a single `MeteorClient` instance in your app's global scope so you can
use it anywhere in your project. The client connects immediately and keeps the
connection alive:

```dart
import 'package:flutter/material.dart';
import 'package:dart_meteor/dart_meteor.dart';

final meteor = MeteorClient.connect(url: 'https://yourdomain.com');

void main() => runApp(MyApp());
```

The `url` may be `https://…` or `wss://…`; the client appends the `/websocket`
DDP endpoint for you.

Then build widgets from the client's streams:

```dart
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('dart_meteor example')),
        body: Column(
          children: [
            // Show the live connection status.
            StreamBuilder<DdpConnectionStatus>(
              stream: meteor.status(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Text('Status: ---');
                return Text('Status: ${snapshot.data}');
              },
            ),
            // Show a login/logout button depending on the current user.
            StreamBuilder<String?>(
              stream: meteor.userId(),
              builder: (context, snapshot) {
                if (snapshot.data != null) {
                  return ElevatedButton(
                    onPressed: () => meteor.logout(),
                    child: const Text('Logout'),
                  );
                }
                return ElevatedButton(
                  onPressed: () =>
                      meteor.loginWithPassword('username', 'password'),
                  child: const Text('Login'),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
```

A complete runnable app is in [/example][example]: a Flutter chat client
(iOS, Android and Web) that connects to the live demo server at
`https://simple-meteor-chat.tanutapi.dev` and exercises login, subscriptions,
collections and method calls. There is also a longer walk-through covering
connection status, authentication, and subscriptions in [this Medium post][medium].

## Method calls

`meteor.call()` returns a `Future`. Always handle errors — an unhandled
`MeteorError` will otherwise crash your app:

```dart
try {
  final result = await meteor.call('sumMethod', args: [5, 10]);
  print('Answer is $result'); // 15
} on MeteorError catch (err) {
  print('${err.error}: ${err.reason}');
}
```

Arguments are optional — `meteor.call('helloMethod')` works too. A `DateTime`
anywhere in the arguments or the result is converted to/from Meteor's EJSON
date format automatically.

Method calls also fit naturally into a `FutureBuilder`:

```dart
FutureBuilder<dynamic>(
  future: meteor.call('sumMethod', args: [5, 10]),
  builder: (context, snapshot) {
    if (snapshot.hasError) return Text('Error: ${snapshot.error}');
    if (!snapshot.hasData) return const CircularProgressIndicator();
    return Text('Answer is: ${snapshot.data}');
  },
),
```

## Subscriptions and collections

Subscribe to a publication on the server, and read the documents it publishes
through `meteor.collection()`:

```dart
class YourWidget extends StatefulWidget {
  const YourWidget({super.key});

  @override
  State<YourWidget> createState() => _YourWidgetState();
}

class _YourWidgetState extends State<YourWidget> {
  late SubscriptionHandler _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = meteor.subscribe('your_pub', args: ['param_1', 'param_2']);
  }

  @override
  void dispose() {
    _subscription.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, dynamic>>(
      stream: meteor.collection('your_collection'),
      builder: (context, snapshot) {
        final docCount = snapshot.data?.length ?? 0;
        return Text('Total document count: $docCount');
      },
    );
  }
}
```

Details worth knowing:

- `meteor.subscribe()` returns a `SubscriptionHandler` with `stop()` and a
  `ready()` stream that emits `true` once the server has sent the initial
  batch of documents. Optional `onReady` and `onStop` callbacks are also
  supported. Subscriptions are re-established automatically after a reconnect.
- `meteor.collection()` returns a stream backed by an rxdart
  `BehaviorSubject`: every new listener immediately receives the latest value,
  so a `StreamBuilder` starts with `snapshot.hasData == true` and an empty map
  before any documents arrive.
- The emitted value is a `Map<String, dynamic>` keyed by document `_id`, with
  the whole document as the value:

```jsonc
{
  "DGbsysgxzSf7Cr8Jg": {
    "_id": "DGbsysgxzSf7Cr8Jg",
    "field1": 0,
    "field2": "a",
    "field3": true,
    "field4": "2020-08-30T16:15:57.000Z" // delivered as a Dart DateTime
  }
}
```

There is no minimongo on the client. Use plain Dart collection operations
(`where`, `map`, `reduce`, …) to query the map — they cover the same ground as
minimongo queries in the Meteor web client.

### Looking up a document by id

Since the collection is a map keyed by `_id`, a lookup is just an index
operation:

```dart
// Non-reactive read of a document by its id.
final doc = meteor.collectionCurrentValue('your_collection_name')?['DGbsysgxzSf7Cr8Jg'];
if (doc != null) {
  // do something
}

// The same works for users.
final user = meteor.collectionCurrentValue('users')?['Sf7Cr8JgDGbsysgxz'];
```

### Reading current values without a stream

When you only need the latest value for a condition check — not a reactive
rebuild — every major stream has a non-reactive counterpart:

| Reactive stream | Current value |
| --- | --- |
| `meteor.collection(name)` | `meteor.collectionCurrentValue(name)` |
| `meteor.user()` | `meteor.userCurrentValue()` |
| `meteor.userId()` | `meteor.userIdCurrentValue()` |

## Accounts

```dart
// Log in (works with a username or an email address; the password is sent
// as a SHA-256 digest, never in plain text).
final result = await meteor.loginWithPassword('user_or_email', 'password');

// Resume a session with a saved token, e.g. after an app restart.
await meteor.loginWithToken(token: result.token, tokenExpires: result.tokenExpires);

// Log out.
await meteor.logout();
```

Related APIs: `meteor.user()`, `meteor.userId()`, `meteor.loggingIn()`, and
`meteor.logInStatus()` are reactive streams of the current account state;
`logoutOtherClients()`, `changePassword()`, `forgotPassword()`, and
`resetPassword()` cover the rest of the standard accounts flows. After a
reconnect the client re-authenticates automatically using its stored token.

## Connection management

```dart
meteor.status();     // Stream<DdpConnectionStatus>: connected/connecting/failed/waiting/offline
meteor.reconnect();  // force a reconnection attempt if not connected
meteor.disconnect(); // close the connection and stop reconnecting
```

While connected, the client exchanges DDP ping/pong with the server and
reconnects when the connection is considered dead, backing off between
attempts (0s, 5s, 10s, … up to `maxRetryInterval`) so an unreachable server
does not keep the radio busy. `disconnect()` is final: the client stays offline
until you call `reconnect()`.

### Session resumption

Meteor servers that include [meteor/meteor#14051](https://github.com/meteor/meteor/pull/14051)
keep a session alive for a grace period (15 s by default,
`Meteor.server.options.disconnectGracePeriod`) after an ungraceful disconnect.
The client asks to resume that session on reconnect, sending its DDP session id
and the number of messages it has received so far. If the server still has the
session and nothing was lost in between, the reconnect is seamless:

- the login is still in place — no resume-token round trip;
- subscriptions are not re-sent, and documents published while the client was
  away are delivered in order on the new socket;
- `onConnection` does not fire again on the server, and the connection id is
  unchanged.

If the server cannot resume (grace period expired, a message was lost, the
server restarted, or it predates that change), it starts a new session and the
client falls back to the usual reconnect: re-login and re-subscribe.
`meteor.connection.resumedSession` tells you which happened after each
reconnect.

Method calls that were in flight fail with `MeteorConnectionError` in both
cases. A request written just before the socket dropped may never have reached
the server, and the client cannot distinguish that from a slow method, so it
reports the uncertainty instead of waiting forever.

`disconnect()` sends a DDP `disconnect` message first, so the server frees the
session immediately instead of holding it open for the grace period.

The timings are configurable if the defaults do not suit your server:

```dart
final meteor = MeteorClient.connect(
  url: 'https://yourdomain.com',
  pingInterval: const Duration(seconds: 20),
  pongTimeout: const Duration(seconds: 5),
  maxRetryInterval: const Duration(seconds: 30),
  stalenessThreshold: const Duration(seconds: 25),
);
```

### App lifecycle (mobile)

When a phone sleeps, the OS suspends the process: Dart timers stop firing, and
the server can drop the session without the socket ever reporting an error. The
app then wakes up believing it is still connected, and stays that way until the
next ping happens to time out.

`dart_meteor` is a pure Dart package, so it does not watch Flutter's lifecycle
itself. Forward it from a `WidgetsBindingObserver` — this is the whole
integration:

```dart
class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      meteor.notifyAppResumed();
    } else {
      meteor.notifyAppPaused();
    }
  }
}
```

On resume the client measures by wall clock how long it was actually away
rather than trusting its timers. If the connection has been silent longer than
`stalenessThreshold` it is torn down and replaced immediately, re-resuming the
login and re-subscribing. While paused, the client will not tear down a
connection just because a timer fired late.

`meteor.checkLiveness()` runs the same check on demand — useful if your app
learns from somewhere else (a connectivity plugin, say) that the network may
have changed.

The [example app][example] wires this up in `lib/main.dart`.

## Error handling

Server-side `Meteor.Error`s are thrown as `MeteorError`, which exposes
`error`, `reason`, `message`, `details`, `errorType`, and `isClientSafe` — the
same fields you get in a Meteor web client.

A call that was still in flight when the connection dropped — because the
device slept, or the network went away — throws `MeteorConnectionError`
(whether or not the session is then [resumed](#session-resumption)). The two
errors are worth distinguishing:
`MeteorError` means the server considered the request and said no, while
`MeteorConnectionError` means you never heard back and the method may or may
not have run.

```dart
try {
  await meteor.call('sendMessage', args: ['hello']);
} on MeteorError catch (err) {
  // The server rejected it.
} on MeteorConnectionError catch (err) {
  // Never got a reply — offer a retry.
}
```

Calls are not resent automatically after a reconnect: a method like
`sendMessage` is not safe to run twice, so whether to retry is left to you.

## Upgrading

See [CHANGELOG.md](CHANGELOG.md) for the full history. The notable breaking
changes:

- **4.2.0** — DDP session resumption. Against a server with
  [meteor/meteor#14051](https://github.com/meteor/meteor/pull/14051) a brief
  network drop no longer re-runs the login or re-sends subscriptions, and
  `onReconnect` callbacks are not invoked on a resumed session. Older servers
  behave exactly as before.
- **4.1.0** — two behaviour changes worth knowing about, both fixes. A method
  call that is in flight when the connection drops now throws
  `MeteorConnectionError` instead of hanging forever, so `await meteor.call(…)`
  can now throw where it previously never returned. And reconnect attempts now
  back off instead of retrying immediately.
- **4.0.0** — requires Dart 3.6+; verified against Meteor 3.x (incl. 3.5.1);
  web support via `web_socket_channel`. The `DdpClient.PING_SEC_INTERVAL` and
  `DdpClient.PONG_WITHIN_SEC` fields were renamed to the static constants
  `DdpClient.pingIntervalSeconds` and `DdpClient.pongTimeoutSeconds`.
- **3.0.0** — `meteor.collection()` streams start with `snapshot.hasData ==
  true` and an empty map instead of no data.
- **2.0.0** — method/subscription arguments became a named parameter:
  `meteor.call('method', args: [...])`, `meteor.subscribe('pub', args: [...])`
  (both optional). `prepareCollection()` is no longer needed — just call
  `meteor.collection()`. `DateTime` values are supported directly.

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/tanutapi/dart_meteor/issues
[rxdart]: https://pub.dev/packages/rxdart
[example]: https://github.com/tanutapi/dart_meteor/tree/master/example
[medium]: https://medium.com/@tanutapi/writing-flutter-mobile-application-with-meteor-backend-643d2c1947d0?source=friends_link&sk=52ce2fa2603934e7395e2d19dd54e06c
