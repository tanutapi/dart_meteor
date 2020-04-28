import 'package:dart_meteor/dart_meteor.dart';
import 'package:test/test.dart';

void main() {
  group('MeteorClient', () {
    MeteorClient meteor;

    setUp(() {
      meteor = MeteorClient.connect(url: 'ws://localhost:3000');
    });

    tearDown(() {
      meteor.disconnect();
    });
//
//    test('meteor.isClient', () {
//      expect(meteor.isClient(), isTrue);
//    });
//
//    test('meteor.isServer', () {
//      expect(meteor.isServer(), isFalse);
//    });
//
//    test('meteor.isCordova', () {
//      expect(meteor.isCordova(), isFalse);
//    });

    test('meteor.loginWithPassword', () async {
      await Future.delayed(Duration(seconds: 5));
      try {
        MeteorClientLoginResult result =
            await meteor.loginWithPassword('user1', 'password1');
        print('MeteorClientLoginResult: ' + result.toString());
        expect(meteor.userId(), isNotNull);
      } catch (e) {
        print(e);
      }
    });
  });
}
