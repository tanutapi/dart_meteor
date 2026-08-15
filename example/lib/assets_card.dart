import 'package:dart_meteor/dart_meteor.dart';
import 'package:flutter/material.dart';

import 'main.dart';

/// A small card that lists the `assets` documents owned by a chosen user.
///
/// Demonstrates a subscription **with arguments** and re-subscribing when the
/// argument changes: `meteor.subscribe('assets', args: [username])`, stopping
/// the previous handler first.
class AssetsCard extends StatefulWidget {
  const AssetsCard({super.key});

  @override
  State<AssetsCard> createState() => _AssetsCardState();
}

class _AssetsCardState extends State<AssetsCard> {
  String? _owner;
  SubscriptionHandler? _subscription;

  void _selectOwner(String? owner) {
    // Stopping the old subscription makes the server remove its documents
    // from the local `assets` collection before the new ones arrive.
    _subscription?.stop();
    _subscription = owner == null
        ? null
        : meteor.subscribe('assets', args: [owner]);
    setState(() => _owner = owner);
  }

  @override
  void dispose() {
    _subscription?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    'Assets',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const Spacer(),
                  // Every logged-in client automatically receives the
                  // `users` collection (username + profile) from the
                  // server's unnamed publication.
                  StreamBuilder<Map<String, dynamic>>(
                    stream: meteor.users,
                    initialData: meteor.collectionCurrentValue('users'),
                    builder: (context, snapshot) {
                      final usernames = (snapshot.data ?? const {})
                          .values
                          .map((u) => u is Map ? u['username'] : null)
                          .whereType<String>()
                          .toList()
                        ..sort();
                      final items = <DropdownMenuItem<String?>>[
                        const DropdownMenuItem(value: null, child: Text('—')),
                        for (final name in usernames)
                          DropdownMenuItem(value: name, child: Text(name)),
                      ];
                      return DropdownButton<String?>(
                        value: usernames.contains(_owner) ? _owner : null,
                        items: items,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        onChanged: _selectOwner,
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 4),
              StreamBuilder<Map<String, dynamic>>(
                stream: meteor.collection('assets'),
                initialData: meteor.collectionCurrentValue('assets'),
                builder: (context, snapshot) {
                  final assets = (snapshot.data ?? const {})
                      .values
                      .whereType<Map<String, dynamic>>()
                      .toList();
                  if (assets.isEmpty) {
                    return Text(
                      'No property found',
                      style: TextStyle(fontSize: 12, color: scheme.outline),
                    );
                  }
                  return Column(
                    children: [
                      for (final asset in assets)
                        Row(
                          children: [
                            Text(asset['owner']?.toString() ?? '?'),
                            const Spacer(),
                            Wrap(
                              spacing: 4,
                              children: [
                                for (final p in (asset['properties'] as List? ??
                                    const []))
                                  Chip(
                                    label: Text('$p'),
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                              ],
                            ),
                          ],
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
