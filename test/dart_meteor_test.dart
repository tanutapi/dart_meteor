import 'package:dart_meteor/dart_meteor.dart';
import 'package:test/test.dart';

void main() {
  group('MeteorClient', () {
    MeteorClient meteor;

    setUp(() {
      meteor = MeteorClient.connect(url: 'wss://echo.websocket.org');
    });

    tearDown(() {
      meteor.disconnect();
    });

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
}
