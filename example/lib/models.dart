/// Small helpers that turn the raw `Map<String, dynamic>` documents delivered
/// by `meteor.collection(...)` into something convenient for the UI.
///
/// dart_meteor already converts EJSON `{$date: ...}` values into [DateTime]
/// and adds the `_id` field to every document, so no extra decoding is needed.
library;

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.from,
    required this.text,
    required this.createdAt,
    required this.isSystem,
  });

  factory ChatMessage.fromDoc(Map<String, dynamic> doc) {
    return ChatMessage(
      id: doc['_id'] as String,
      from: doc['from'] as String?,
      text: doc['msg'] as String? ?? '',
      createdAt: doc['createdAt'] as DateTime? ??
          DateTime.fromMillisecondsSinceEpoch(0),
      isSystem: doc['system'] == true,
    );
  }

  final String id;

  /// The `_id` of the sender in the `users` collection, or null for
  /// server broadcasts.
  final String? from;
  final String text;
  final DateTime createdAt;
  final bool isSystem;
}

/// "Name Surname" from a `users` document, falling back to the username.
String displayName(Map<String, dynamic>? user) {
  if (user == null) return 'Unknown';
  final profile = user['profile'];
  if (profile is Map) {
    final name = '${profile['name'] ?? ''} ${profile['surname'] ?? ''}'.trim();
    if (name.isNotEmpty) return name;
  }
  return user['username'] as String? ?? 'Unknown';
}

/// First letter of the username, upper-cased, used for avatars.
String initialOf(Map<String, dynamic>? user) {
  final username = user?['username'] as String?;
  if (username == null || username.isEmpty) return '?';
  return username.substring(0, 1).toUpperCase();
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Local time as `HH:mm`.
String hhmm(DateTime time) {
  final local = time.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}';
}

/// Remaining time as `M:SS`, clamped at 0:00.
String countdown(Duration remaining) {
  final seconds = remaining.isNegative ? 0 : remaining.inSeconds;
  return '${seconds ~/ 60}:${_two(seconds % 60)}';
}
