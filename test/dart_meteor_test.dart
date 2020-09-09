import 'dart:async';
import 'package:rxdart/rxdart.dart';

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
      meteor.subscribe(
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

    test('SubscriptionHandler.ready()', () async {
      var completer = Completer();
      expect(completer.future, completion(true));
      var subHandler = meteor.subscribe(
        'messages',
        args: [],
      );
      var s = 0;
      subHandler.ready().listen((value) {
        if (s == 0) {
          expect(value, false);
        } if (s == 1) {
          expect(value, true);
          if (value) {
            completer.complete(true);
          }
        }
        s++;
      });
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
      await Future.delayed(Duration(seconds: 10));
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });
  });

  group('Reactive with rxdart', () {
    var meteor = MeteorClient.connect(url: 'ws://127.0.0.1:3000');

    setUp(() async {
      meteor.reconnect();
      await Future.delayed(Duration(seconds: 2));
    });

    tearDown(() {
      meteor.disconnect();
    });

    test('reactive on subscription, expect assets contains one document if we do stop the fist subscription', () async {
      var completer = Completer();
      expect(completer.future, completion(true));
      await meteor.loginWithPassword('user1', 'password1');
      var reactive = BehaviorSubject();
      SubscriptionHandler sub;
      reactive.add('user1');
      reactive.listen((username) {
        if (sub != null) {
          sub.stop();
        }
        sub = meteor.subscribe(
          'assets', 
          args: [username],
          onReady: () async {
            var assets = await meteor.collectionCurrentValue('assets');
            if (username == 'user2' && assets.length == 1) {
              assets.forEach((k, v) { 
                if (v['owner'] == 'user2') {
                  completer.complete(true);
                }
              });
            }
          }
        );
      });
      var bFirst = true;
      meteor.collection('assets').listen((value) {
        print('collection assets listen:');
        print(value);

        if (bFirst) {
          reactive.add('user2');
          bFirst = false;
        }
      });
      await Future.delayed(Duration(seconds: 5));
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });

    test('reactive on subscription, expect assets contains two documents if we does not stop the fist subscription', () async {
      var completer = Completer();
      expect(completer.future, completion(true));
      await meteor.loginWithPassword('user1', 'password1');
      var reactive = BehaviorSubject();
      SubscriptionHandler sub;
      reactive.add('user1');
      reactive.listen((username) {
        sub = meteor.subscribe(
          'assets', 
          args: [username],
          onReady: () async {
            var assets = await meteor.collectionCurrentValue('assets');
            if (username == 'user2' && assets.length == 2) {
              assets.forEach((k, v) { 
                if (v['owner'] == 'user2') {
                  completer.complete(true);
                }
              });
            }
          }
        );
      });
      var bFirst = true;
      meteor.collection('assets').listen((value) {
        print('collection assets listen:');
        print(value);

        if (bFirst) {
          reactive.add('user2');
          bFirst = false;
        }
      });
      await Future.delayed(Duration(seconds: 5));
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });
  });
}
