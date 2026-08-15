# Simple Meteor Chat — dart_meteor example

A small Flutter chat client (iOS, Android and Web) built with
[`dart_meteor`](https://pub.dev/packages/dart_meteor). It is a Flutter port of
the Blaze web app [simple-meteor-chat](https://github.com/tanutapi/simple-meteor-chat)
and talks to the public demo server:

```
https://simple-meteor-chat.tanutapi.dev
```

`MeteorClient.connect` turns that into `wss://simple-meteor-chat.tanutapi.dev/websocket`
for you, so the plain site URL is all the app needs (see `lib/main.dart`).

## Sign-in

There is no sign-up. Use one of the seeded accounts:

| Username | Password    |
|----------|-------------|
| `user1`  | `password1` |
| `user2`  | `password2` |

Open the app twice (e.g. two browser tabs, or a phone and Chrome) and sign in
as `user1` and `user2` to chat with yourself.

The demo server is intentionally noisy: it posts a system broadcast every
10 seconds and **wipes the whole chat every minute** — the ⏳ countdown in the
header shows when the next purge happens.

## Run it

Flutter ≥ 3.27 (Dart ≥ 3.6). The folder is pinned to the `stable` channel via
[fvm](https://fvm.app) (`.fvmrc`) — if you use fvm, `fvm install` picks it up
and you can prefix the commands below with `fvm`; otherwise plain `flutter`
works too.

```sh
cd example
flutter pub get
flutter run -d chrome        # Web
flutter run -d ios           # iOS simulator / device
flutter run -d android       # Android emulator / device
```

## What it demonstrates

| Feature in the app                          | `dart_meteor` API |
|---------------------------------------------|-------------------|
| One app-wide client, auto-reconnect         | `MeteorClient.connect(url: …)` |
| "Connecting…" banner + Retry                | `meteor.status()`, `meteor.reconnect()` |
| Login page ↔ chat page switching            | `meteor.userId()` / `meteor.userIdCurrentValue()` |
| Sign in / sign out                          | `meteor.loginWithPassword(user, pass)`, `meteor.logout()` |
| Login errors ("Incorrect password", …)      | `MeteorError.reason` |
| "Signed in as Apple Seed"                   | `meteor.user()` |
| Live message list, purge countdown          | `meteor.subscribe('messages')`, `subscribe('status')`, `meteor.collection('messages')`, `collection('status')` |
| Sender names / avatars                      | `meteor.users` (auto-published `users` collection) |
| Send a message, clear the chat              | `meteor.call('sendMessage', args: [text])`, `call('clearAllMessages')` |
| Assets card: pick a user, re-subscribe      | `meteor.subscribe('assets', args: [username])`, `SubscriptionHandler.stop()` |

Files:

- `lib/main.dart` — creates the `MeteorClient`, `RootPage` (login vs chat), connection banner
- `lib/login_page.dart` — username/password sign-in
- `lib/chat_page.dart` — header, message list, composer
- `lib/assets_card.dart` — subscription with arguments
- `lib/models.dart` — tiny helpers for the raw `Map` documents

## Point it at your own server

Run [simple-meteor-chat](https://github.com/tanutapi/simple-meteor-chat) locally
(`meteor run`, or `docker run -p 3000:3000 tanutapi/simple-meteor-chat`) and
change `serverUrl` in `lib/main.dart` to `http://localhost:3000` (Android
emulator: `http://10.0.2.2:3000`).
