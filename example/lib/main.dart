import 'package:dart_meteor/dart_meteor.dart';
import 'package:flutter/material.dart';

import 'chat_page.dart';
import 'login_page.dart';

/// The demo server. `MeteorClient.connect` turns `https://` into `wss://` and
/// appends `/websocket` automatically, so a plain site URL is enough.
const serverUrl = 'https://simple-meteor-chat.tanutapi.dev';

/// A single, app-wide client. It starts connecting as soon as it is created
/// and keeps reconnecting (and re-subscribing / resuming the login token) on
/// its own when the connection drops.
final MeteorClient meteor = MeteorClient.connect(url: serverUrl);

void main() {
  runApp(const SimpleMeteorChatApp());
}

class SimpleMeteorChatApp extends StatefulWidget {
  const SimpleMeteorChatApp({super.key});

  @override
  State<SimpleMeteorChatApp> createState() => _SimpleMeteorChatAppState();
}

/// Forwards the app lifecycle to the Meteor client.
///
/// This is the whole integration: while the device is asleep the process is
/// suspended, so timers stop firing and the server may drop the connection
/// without the socket ever reporting an error. Telling the client when the app
/// resumes lets it check by wall clock how long it was really away and replace
/// a dead connection immediately, instead of looking connected until the next
/// ping happens to time out.
class _SimpleMeteorChatAppState extends State<SimpleMeteorChatApp>
    with WidgetsBindingObserver {
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Simple Meteor Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6366F1)),
        useMaterial3: true,
      ),
      home: const RootPage(),
    );
  }
}

/// Shows [LoginPage] while nobody is logged in and [ChatPage] otherwise.
///
/// `meteor.userId()` emits `null` after logout and the user id after a
/// successful login (or a token resume), so switching on it is all that is
/// needed for navigation.
class RootPage extends StatelessWidget {
  const RootPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const ConnectionBanner(),
          Expanded(
            child: StreamBuilder<String?>(
              stream: meteor.userId(),
              initialData: meteor.userIdCurrentValue(),
              builder: (context, snapshot) {
                final userId = snapshot.data;
                if (userId == null) {
                  return const LoginPage();
                }
                // Keying on the user id resets the chat state when a
                // different user signs in.
                return ChatPage(key: ValueKey(userId), userId: userId);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A slim strip at the top of the screen that is only visible while the DDP
/// connection is not established.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DdpConnectionStatus>(
      stream: meteor.status(),
      builder: (context, snapshot) {
        final status = snapshot.data;
        if (status != null && status.connected) {
          return const SizedBox.shrink();
        }
        final label = switch (status?.status) {
          null || DdpConnectionStatusValues.connecting => 'Connecting…',
          DdpConnectionStatusValues.waiting =>
            'Reconnecting… (attempt ${status!.retryCount})',
          DdpConnectionStatusValues.failed => 'Connection failed',
          DdpConnectionStatusValues.offline => 'Offline',
          DdpConnectionStatusValues.connected => 'Connected',
        };
        final scheme = Theme.of(context).colorScheme;
        return Material(
          color: scheme.errorContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.cloud_off, size: 18, color: scheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                  TextButton(
                    onPressed: meteor.reconnect,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
