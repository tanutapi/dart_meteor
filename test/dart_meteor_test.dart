import 'dart:async';

import 'package:dart_meteor/dart_meteor.dart';
import 'package:test/test.dart';

void main() {
  group('Environment', () {
    MeteorClient meteor = MeteorClient.connect(url: 'ws://127.0.0.1:3000');

    test('meteor.isClient', () {
      expect(meteor.isClient(), isTrue);
    });

    test('meteor.isServer', () {
      expect(meteor.isServer(), isFalse);
    });

    test('meteor.isCordova', () {
      expect(meteor.isCordova(), isFalse);
    });
  });

  group('Login', () {
    MeteorClient meteor = MeteorClient.connect(url: 'ws://127.0.0.1:3000');

    setUp(() async {
      meteor.reconnect();
      await Future.delayed(Duration(seconds: 2));
    });

    tearDown(() {
      meteor.disconnect();
    });

    test('meteor.loginWithPassword', () async {
      MeteorClientLoginResult result =
          await meteor.loginWithPassword('user1', 'password1');
      print('MeteorClientLoginResult: ' + result.toString());
      expect(meteor.userId(), isNotNull);
    });

    test('meteor.subscribe with onReady', () async {
      var completer = Completer();
      expect(completer.future, completion(true));
      await meteor.subscribe(
        'messages',
        [],
        onReady: () {
          print('onReady is called.');
          completer.complete(true);
        },
      );
      await Future.delayed(Duration(seconds: 5));
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });
  });
}
