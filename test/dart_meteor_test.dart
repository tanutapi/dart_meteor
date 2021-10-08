import 'dart:async';
import 'package:rxdart/rxdart.dart';

import 'package:dart_meteor/dart_meteor.dart';
import 'package:test/test.dart';

var url = 'ws://127.0.0.1:3000';

void main() {
  group('Environment', () {
    var meteor = MeteorClient.connect(
      url: url,
      debug: true,
    );

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
    var meteor = MeteorClient.connect(
      url: url,
      debug: true,
    );

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

  group('Method', () {
    var meteor = MeteorClient.connect(
      url: url,
      debug: true,
    );

    setUp(() async {
      meteor.reconnect();
      await Future.delayed(Duration(seconds: 2));
    });

    tearDown(() {
      meteor.disconnect();
    });

    test('Method that return a Number', () async {
      var result = await meteor.call('methodThatReturnNumber');
      expect(result, isA<double>());
    });

    test('Method that return a String', () async {
      var result = await meteor.call('methodThatReturnString');
      expect(result, isA<String>());
    });

    test('Method that return a DateTime', () async {
      var result = await meteor.call('methodThatReturnDateTime');
      expect(result, isA<DateTime>());
    });

    test('Method that return a Object', () async {
      var result = await meteor.call('methodThatReturnObject');
      expect(result, isA<Map>());
      expect(result['createdAt'], isA<DateTime>());
    });

    test('Method that return a nested Date Object', () async {
      var result = await meteor.call('methodThatReturnNestedDateObject');
      // From the simple-meteor-chat test backend project...
      // return {
      //   a: {
      //     createdAt: new Date(),
      //     b: {
      //       c: {
      //         createdAt: new Date(),
      //       }
      //     }
      //   },
      //   createdAt: new Date(),
      // };
      expect(result, isA<Map>());
      expect(result['createdAt'], isA<DateTime>());
      expect(result['a']['createdAt'], isA<DateTime>());
      expect(result['a']['b']['c']['createdAt'], isA<DateTime>());
    });

    test('Method that return an array of nested Date Objects', () async {
      var result = await meteor.call('methodThatReturnArrayOfNestedDateObject');
      // From the simple-meteor-chat test backend project...
      // return [{
      //   a: {
      //     createdAt: date1,
      //     b: {
      //       c: [{
      //         createdAt: date2,
      //       }, {
      //         createdAt: date3,
      //       }, {
      //         createdAt: date4,
      //       }],
      //       d: [date5, date6],
      //     }
      //   },
      //   createdAt: [date5, date6],
      // }, {
      //   a: {
      //     createdAt: date1,
      //     b: {
      //       c: [{
      //         createdAt: date2,
      //       }, {
      //         createdAt: date3,
      //       }, {
      //         createdAt: date4,
      //       }],
      //       d: [date5, date6],
      //     }
      //   },
      //   createdAt: [date5, date6],
      // }];
      print(result);
      expect(result, isA<List>());
      expect(result[0]['createdAt'][0], isA<DateTime>());
      expect(result[0]['createdAt'][1], isA<DateTime>());
      expect(result[0]['a']['createdAt'], isA<DateTime>());
      expect(result[0]['a']['b']['c'][0]['createdAt'], isA<DateTime>());
      expect(result[0]['a']['b']['c'][1]['createdAt'], isA<DateTime>());
      expect(result[0]['a']['b']['c'][2]['createdAt'], isA<DateTime>());
      expect(result[0]['a']['b']['d'][0], isA<DateTime>());
      expect(result[0]['a']['b']['d'][1], isA<DateTime>());

      expect(result[1]['createdAt'][0], isA<DateTime>());
      expect(result[1]['createdAt'][1], isA<DateTime>());
      expect(result[1]['a']['createdAt'], isA<DateTime>());
      expect(result[1]['a']['b']['c'][0]['createdAt'], isA<DateTime>());
      expect(result[1]['a']['b']['c'][1]['createdAt'], isA<DateTime>());
      expect(result[1]['a']['b']['c'][2]['createdAt'], isA<DateTime>());
      expect(result[1]['a']['b']['d'][0], isA<DateTime>());
      expect(result[1]['a']['b']['d'][1], isA<DateTime>());
    });
  });

  group('Login and logout', () {
    var meteor = MeteorClient.connect(
      url: url,
      debug: true,
    );

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
      print('UserID: ${meteor.userIdCurrentValue()}');
      expect(meteor.userIdCurrentValue(), isNotNull);
    });

    test('meteor.logout', () async {
      var result = await meteor.loginWithPassword('user1', 'password1');
      print('MeteorClientLoginResult: ' + result.toString());
      print('UserID: ${meteor.userIdCurrentValue()}');
      expect(meteor.userIdCurrentValue(), isNotNull);
      expect(meteor.userCurrentValue(), isNotNull);
      await meteor.logout();
      expect(meteor.userIdCurrentValue(), isNull);
      expect(meteor.userCurrentValue(), isNull);
    });

    test('meteor.logoutOtherClients', () async {
      var result = await meteor.loginWithPassword('user1', 'password1');
      print('MeteorClientLoginResult: ' + result.toString());
      print('UserID: ${meteor.userIdCurrentValue()}');
      expect(meteor.userIdCurrentValue(), isNotNull);
      expect(meteor.userCurrentValue(), isNotNull);
      await meteor.logoutOtherClients();
      expect(meteor.userIdCurrentValue(), isNotNull);
      expect(meteor.userCurrentValue(), isNull);
    });
  });

  group('Subscription', () {
    var meteor = MeteorClient.connect(
      url: url,
      debug: true,
    );

    setUp(() async {
      meteor.reconnect();
      await Future.delayed(Duration(seconds: 2));
    });

    tearDown(() {
      meteor.disconnect();
    });

    test('meteor.loggingIn', () async {
      var state = 0;
      var currentLoggingIn = true;
      meteor.loggingIn().listen((event) {
        print('Before: loggingIn state: $state, loggingIn: $event');
        currentLoggingIn = event;
        if (state == 0 && event == false) {
          state++;
        } else if (state == 1 && event == true) {
          state++;
        } else if (state == 2 && event == false) {
          state++;
        }
        print('After: loggingIn state: $state, loggingIn: $event');
      });
      await meteor.loginWithPassword('user1', 'password1');
      expect(meteor.userId(), isNotNull);
      await Future.delayed(Duration(seconds: 5));
      expect(state, 3);
      expect(currentLoggingIn, false);
    });
  });

  group('subscription', () {
    var meteor = MeteorClient.connect(
      url: url,
      debug: true,
    );

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
        } else if (s == 1) {
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
      meteor.subscribe(
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
    var meteor = MeteorClient.connect(
      url: url,
      debug: true,
    );

    setUp(() async {
      meteor.reconnect();
      await Future.delayed(Duration(seconds: 2));
    });

    tearDown(() {
      meteor.disconnect();
    });

    test(
        'reactive on subscription, expect assets contains one document if we do stop the fist subscription',
        () async {
      var completer = Completer();
      expect(completer.future, completion(true));
      await meteor.loginWithPassword('user1', 'password1');
      var reactive = BehaviorSubject();
      SubscriptionHandler? sub;
      reactive.add('user1');
      reactive.listen((username) {
        if (sub != null) {
          sub!.stop();
        }
        sub = meteor.subscribe('assets', args: [username], onReady: () async {
          await Future.delayed(Duration(seconds: 2));
          var assets = meteor.collectionCurrentValue('assets');
          if (username == 'user2' && assets!.length == 1) {
            assets.forEach((k, v) {
              if (v['owner'] == 'user2') {
                completer.complete(true);
              }
            });
          }
        });
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

    test(
        'reactive on subscription, expect assets contains two documents if we does not stop the fist subscription',
        () async {
      var completer = Completer();
      expect(completer.future, completion(true));
      await meteor.loginWithPassword('user1', 'password1');
      var reactive = BehaviorSubject();
      SubscriptionHandler sub;
      reactive.add('user1');
      reactive.listen((username) {
        sub = meteor.subscribe('assets', args: [username], onReady: () async {
          await Future.delayed(Duration(seconds: 2));
          var assets = meteor.collectionCurrentValue('assets');
          if (username == 'user2' && assets!.length == 2) {
            assets.forEach((k, v) {
              if (v['owner'] == 'user2') {
                completer.complete(true);
              }
            });
          }
        });
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
