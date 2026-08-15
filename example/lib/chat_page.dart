import 'dart:async';

import 'package:dart_meteor/dart_meteor.dart';
import 'package:flutter/material.dart';

import 'assets_card.dart';
import 'main.dart';
import 'models.dart';

const _gradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
);

/// The chat room shown while a user is logged in.
///
/// Demonstrates:
/// * `meteor.subscribe(...)` in [initState] and `SubscriptionHandler.stop()`
///   in [dispose];
/// * `meteor.collection('messages')` / `meteor.collection('status')` streams;
/// * `meteor.user()` for the current user document;
/// * `meteor.call(...)` for the `sendMessage` and `clearAllMessages` methods;
/// * `meteor.logout()`.
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.userId});

  final String userId;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final SubscriptionHandler _messagesSub;
  late final SubscriptionHandler _statusSub;
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Subscriptions are re-sent automatically by dart_meteor whenever the
    // connection is re-established, so subscribing once is enough.
    _messagesSub = meteor.subscribe('messages');
    _statusSub = meteor.subscribe('status');
  }

  @override
  void dispose() {
    _messagesSub.stop();
    _statusSub.stop();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _showError(Object error) {
    if (!mounted) return;
    final text = error is MeteorError
        ? (error.reason ?? error.message ?? error.toString())
        : error.toString();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    _input.clear();
    setState(() => _sending = true);
    try {
      // The server stamps `from` and `createdAt`; the new document arrives
      // through the `messages` subscription like any other change.
      await meteor.call('sendMessage', args: [text]);
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _inputFocus.requestFocus();
      }
    }
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear chat'),
        content: const Text('Do you want to delete all chat messages?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await meteor.call('clearAllMessages');
    } catch (e) {
      _showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Header(onClear: _clearAll),
        Expanded(child: _MessageList(currentUserId: widget.userId)),
        _Composer(
          controller: _input,
          focusNode: _inputFocus,
          sending: _sending,
          onSend: _send,
        ),
        const AssetsCard(),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClear});

  final Future<void> Function() onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: _gradient),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              const Text('💬', style: TextStyle(fontSize: 24)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Simple Meteor Chat',
                        maxLines: 1,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    // `meteor.user()` emits the current user's document
                    // (only the fields the server publishes: username,
                    // profile) and null after logout.
                    StreamBuilder<Map<String, dynamic>?>(
                      stream: meteor.user(),
                      initialData: meteor.userCurrentValue(),
                      builder: (context, snapshot) => Text(
                        'Signed in as ${displayName(snapshot.data)}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const _PurgeCountdown(),
              IconButton(
                tooltip: 'Clear all messages',
                icon: const Icon(Icons.delete_sweep_outlined),
                color: Colors.white,
                visualDensity: VisualDensity.compact,
                onPressed: onClear,
              ),
              IconButton(
                tooltip: 'Logout',
                icon: const Icon(Icons.logout),
                color: Colors.white,
                visualDensity: VisualDensity.compact,
                onPressed: meteor.logout,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "⏳ M:SS" until the server wipes the chat, read from the single
/// `status/chatPurge` document. Turns red for the last 10 seconds.
class _PurgeCountdown extends StatefulWidget {
  const _PurgeCountdown();

  @override
  State<_PurgeCountdown> createState() => _PurgeCountdownState();
}

class _PurgeCountdownState extends State<_PurgeCountdown> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    // The document only changes once a minute; tick locally in between.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, dynamic>>(
      stream: meteor.collection('status'),
      initialData: meteor.collectionCurrentValue('status'),
      builder: (context, snapshot) {
        final doc = snapshot.data?['chatPurge'];
        final nextPurgeAt = doc is Map ? doc['nextPurgeAt'] : null;
        String label = '-:--';
        bool urgent = false;
        if (nextPurgeAt is DateTime) {
          final remaining = nextPurgeAt.difference(DateTime.now());
          label = countdown(remaining);
          urgent = remaining.inSeconds <= 10;
        }
        return Tooltip(
          message: 'Chat history is cleared automatically every minute',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: urgent ? Colors.red.shade600 : Colors.white24,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '⏳ $label',
              style: const TextStyle(
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({required this.currentUserId});

  final String currentUserId;

  @override
  Widget build(BuildContext context) {
    // The outer builder listens to `users` so sender names update if a user
    // document arrives after (or changes after) its messages.
    return StreamBuilder<Map<String, dynamic>>(
      stream: meteor.users,
      initialData: meteor.collectionCurrentValue('users'),
      builder: (context, usersSnapshot) {
        final users = usersSnapshot.data ?? const {};
        return StreamBuilder<Map<String, dynamic>>(
          stream: meteor.collection('messages'),
          initialData: meteor.collectionCurrentValue('messages'),
          builder: (context, snapshot) {
            // The stream emits the whole collection as {_id: document}. It is
            // the client's live map, so copy it before sorting.
            final messages = (snapshot.data ?? const {})
                .values
                .whereType<Map<String, dynamic>>()
                .map(ChatMessage.fromDoc)
                .toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

            if (messages.isEmpty) {
              return const _EmptyState();
            }
            // Newest first + reverse:true keeps the view pinned to the bottom
            // as new messages arrive, with no manual scrolling.
            return ListView.builder(
              reverse: true,
              padding: const EdgeInsets.symmetric(vertical: 12),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final message = messages[index];
                if (message.isSystem) {
                  return _SystemBubble(message: message);
                }
                final sender = users[message.from];
                return _MessageBubble(
                  message: message,
                  sender: sender is Map<String, dynamic> ? sender : null,
                  isOwn: message.from == currentUserId,
                );
              },
            );
          },
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🗨️', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 8),
          Text(
            'No messages yet — say hello!',
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

class _SystemBubble extends StatelessWidget {
  const _SystemBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Tooltip(
        message: hhmm(message.createdAt),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '📢 ${message.text}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.sender,
    required this.isOwn,
  });

  final ChatMessage message;
  final Map<String, dynamic>? sender;
  final bool isOwn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final time = Text(
      hhmm(message.createdAt),
      style: TextStyle(
        fontSize: 11,
        color: isOwn ? Colors.white70 : scheme.outline,
      ),
    );

    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.72,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        gradient: isOwn ? _gradient : null,
        color: isOwn ? null : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isOwn ? 18 : 4),
          bottomRight: Radius.circular(isOwn ? 4 : 18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isOwn)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                displayName(sender),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ),
          Text(
            message.text,
            style: TextStyle(color: isOwn ? Colors.white : scheme.onSurface),
          ),
          const SizedBox(height: 2),
          time,
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment:
            isOwn ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isOwn) ...[
            Tooltip(
              message: sender?['username'] as String? ?? '',
              child: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  gradient: _gradient,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  initialOf(sender),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          bubble,
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: 'Type a message…',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: sending ? null : onSend,
              icon: const Icon(Icons.send, size: 18),
              label: const Text('Send'),
            ),
          ],
        ),
      ),
    );
  }
}
