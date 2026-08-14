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
- Automatic reconnection with re-login and re-subscription
- `DateTime` values are converted to/from EJSON `$date` automatically

## Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  dart_meteor: ^4.0.0
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

A complete runnable app is in [/example][example], and there is a longer
walk-through covering connection status, authentication, and subscriptions in
[this Medium post][medium].

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
reconnects (with backoff) when the connection is considered dead.

## Error handling

Server-side `Meteor.Error`s are thrown as `MeteorError`, which exposes
`error`, `reason`, `message`, `details`, `errorType`, and `isClientSafe` — the
same fields you get in a Meteor web client.

## Upgrading

See [CHANGELOG.md](CHANGELOG.md) for the full history. The notable breaking
changes:

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
