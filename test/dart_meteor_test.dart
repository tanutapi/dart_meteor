import 'dart:async';

import 'package:dart_meteor/dart_meteor.dart';
import 'package:test/test.dart';

void main() {
  group('Environment', () {
    var meteor = MeteorClient.connect(url: 'ws://127.0.0.1:3000');

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

  group('MeteorError', () {
    var meteor = MeteorClient.connect(url: 'ws://127.0.0.1:3000');

    setUp(() async {
      meteor.reconnect();
      await Future.delayed(Duration(seconds: 2));
    });

    tearDown(() {
      meteor.disconnect();
    });

    test('It should throw error as integer', () async {
      try {
        await meteor.call('methodThatThrowErrorAsInt');
      } on MeteorError catch (e) {
        expect(e.error, 500);
        expect(e.reason, 'This is an error');
      }
    });

    test('It should throw error as string', () async {
      try {
        await meteor.call('methodThatThrowErrorAsString');
      } on MeteorError catch (e) {
        expect(e.error, 'error');
        expect(e.reason, 'This is an error');
      }
    });
  });

  group('Login', () {
    var meteor = MeteorClient.connect(url: 'ws://127.0.0.1:3000');

    setUp(() async {
      meteor.reconnect();
      await Future.delayed(Duration(seconds: 2));
    });

    tearDown(() {
      meteor.disconnect();
    });

    test('meteor.loginWithPassword', () async {
      var result = await meteor.loginWithPassword('user1', 'password1');
      print('MeteorClientLoginResult: ' + result.toString());
      expect(meteor.userId(), isNotNull);
    });
  });

  group('Subscription', () {
    var meteor = MeteorClient.connect(url: 'ws://127.0.0.1:3000');

    setUp(() async {
      meteor.reconnect();
      await Future.delayed(Duration(seconds: 2));
    });

    tearDown(() {
      meteor.disconnect();
    });

    test('meteor.subscribe with onReady', () async {
      var completer = Completer();
      expect(completer.future, completion(true));
      await meteor.subscribe(
        'messages',
        args: [],
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

    test('clearAllMessages', () async {
      await meteor.loginWithPassword('user1', 'password1');
      await meteor.call('clearAllMessages');
    });

    test(
        'collection(messages) stream should have values and "createdAt" should be instance of DateTime',
        () async {
      var completer = Completer();
      expect(completer.future, completion(true));
      await meteor.loginWithPassword('user1', 'password1');
      await meteor.subscribe(
        'messages',
      );
      meteor.collection('messages').listen((value) {
        print('collection messages listen:');
        print(value);

        if (!(value[value.keys.first]['createdAt'] is DateTime)) {
          if (!completer.isCompleted) {
            completer.complete(false);
          }
        } else {
          if (!completer.isCompleted) {
            completer.complete(true);
          }
        }
      });
      await meteor.call('sendMessage', args: ['message 1']);
      await meteor.call('sendMessage', args: ['message 2']);
      await meteor.call('sendMessage', args: ['message 3']);
      await Future.delayed(Duration(seconds: 20));
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });
  });
}
