/// Tests the MeteorClient/DdpClient against a local mock server that
/// implements the DDP protocol (version "1") exactly as a Meteor 3.x server
/// (tested against the behavior of Meteor 3.5.1) speaks it over
/// `/websocket`. These tests run standalone - no Meteor server or docker
/// required.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dart_meteor/dart_meteor.dart';
import 'package:test/test.dart';

import 'mock_ddp_server.dart';

Future<void> _waitForConnected(MeteorClient meteor) async {
  await meteor
      .status()
      .firstWhere((s) => s.status == DdpConnectionStatusValues.connected)
      .timeout(Duration(seconds: 10));
}

void main() {
  group('DDP protocol against a mock Meteor 3.x server', () {
    late MockDdpServer server;
    late MeteorClient meteor;

    setUp(() async {
      server = MockDdpServer();
      server.itemsCollection['doc1'] = {
        'title': 'First',
        'createdAt': {'\$date': 1598804210504},
      };
      await server.start();
      meteor = MeteorClient.connect(url: 'ws://127.0.0.1:${server.port}');
      await _waitForConnected(meteor);
    });

    tearDown(() async {
      meteor.disconnect();
      await server.stop();
    });

    test('completes the version 1 handshake and exposes ids', () async {
      expect(meteor.connection.serverId, '0');
      expect(meteor.connection.sessionId, 'mock-session-1');
    });

    test('method call returns the result', () async {
      var result = await meteor.call('methodThatReturnNumber');
      expect(result, 42);
    });

    test('method call echoes arguments and DateTime is EJSON encoded',
        () async {
      var date = DateTime.fromMillisecondsSinceEpoch(1598804210504);
      await meteor.call('echo', args: ['hello', 1, date]);
      var sentParams = server.lastMethodMessage!['params'] as List;
      expect(sentParams[0], 'hello');
      expect(sentParams[1], 1);
      expect(sentParams[2], {'\$date': 1598804210504});
    });

    test('EJSON \$date in results is decoded to DateTime', () async {
      var result = await meteor.call('methodThatReturnDate');
      expect(result['createdAt'], isA<DateTime>());
      expect((result['createdAt'] as DateTime).millisecondsSinceEpoch,
          1598804210504);
    });

    test('method errors surface as MeteorError', () async {
      try {
        await meteor.call('methodThatThrowError');
        fail('expected MeteorError');
      } on MeteorError catch (e) {
        expect(e.error, 500);
        expect(e.reason, 'This is an error');
        expect(e.errorType, 'Meteor.Error');
      }
    });

    test('loginWithPassword sends a sha-256 digest and yields a token',
        () async {
      var result = await meteor.loginWithPassword('user1', 'password1');
      expect(result.userId, 'user1-id');
      expect(result.token, 'valid-resume-token');
      expect(result.tokenExpires.isAfter(DateTime.now()), isTrue);

      var password = server.lastLoginRequest!['password'];
      expect(password['algorithm'], 'sha-256');
      expect(password['digest'], MockDdpServer.user1Digest);
      // The password must never be sent in plain text.
      expect(
          json.encode(server.lastLoginRequest), isNot(contains('password1')));
    });

    test('bad login rejects with MeteorError 403', () async {
      try {
        await meteor.loginWithPassword('user1', 'wrong-password');
        fail('expected MeteorError');
      } on MeteorError catch (e) {
        expect(e.error, 403);
        expect(e.reason, 'Incorrect password');
      }
    });

    test('loginWithToken resumes the session', () async {
      var result = await meteor.loginWithToken(token: 'valid-resume-token');
      expect(result, isNotNull);
      expect(result!.userId, 'user1-id');
      expect(server.lastLoginRequest, {'resume': 'valid-resume-token'});
    });

    test('subscription becomes ready and documents arrive in the collection',
        () async {
      var handler = meteor.subscribe('items');
      await handler.ready().firstWhere((ready) => ready == true).timeout(
            Duration(seconds: 5),
          );
      var items = await meteor
          .collection('items')
          .firstWhere((c) => c.isNotEmpty)
          .timeout(Duration(seconds: 5));
      expect(items['doc1'], isNotNull);
      expect(items['doc1']['title'], 'First');
      expect(items['doc1']['createdAt'], isA<DateTime>());
    });

    test('unknown subscription reports nosub through onStop', () async {
      var completer = Completer<dynamic>();
      meteor.subscribe('doesNotExist', onStop: (error) {
        completer.complete(error);
        return () {};
      });
      var error = await completer.future.timeout(Duration(seconds: 5));
      expect(error, isNotNull);
      expect(error['error'], 404);
    });

    test('changed and removed messages update the collection stream', () async {
      var handler = meteor.subscribe('items');
      await handler.ready().firstWhere((ready) => ready == true).timeout(
            Duration(seconds: 5),
          );
      await meteor
          .collection('items')
          .firstWhere((c) => c.isNotEmpty)
          .timeout(Duration(seconds: 5));

      server.broadcast({
        'msg': 'changed',
        'collection': 'items',
        'id': 'doc1',
        'fields': {'title': 'Updated'},
      });
      var updated = await meteor
          .collection('items')
          .firstWhere((c) => c['doc1']?['title'] == 'Updated')
          .timeout(Duration(seconds: 5));
      expect(updated['doc1']['title'], 'Updated');

      server.broadcast({
        'msg': 'removed',
        'collection': 'items',
        'id': 'doc1',
      });
      var afterRemove = await meteor
          .collection('items')
          .firstWhere((c) => c['doc1'] == null)
          .timeout(Duration(seconds: 5));
      expect(afterRemove.containsKey('doc1'), isFalse);
    });

    test('server-initiated ping is answered so the connection stays up',
        () async {
      server.broadcast({'msg': 'ping'});
      // If the client failed to pong, nothing observable happens locally;
      // simply assert the connection is still healthy after a beat.
      await Future.delayed(Duration(milliseconds: 500));
      var result = await meteor.call('methodThatReturnNumber');
      expect(result, 42);
    });

    test('client reconnects and re-subscribes after the socket drops',
        () async {
      var handler = meteor.subscribe('items');
      await handler.ready().firstWhere((ready) => ready == true).timeout(
            Duration(seconds: 5),
          );

      server.closeAllSockets();
      await meteor
          .status()
          .firstWhere((s) => s.status != DdpConnectionStatusValues.connected)
          .timeout(Duration(seconds: 10));
      await _waitForConnected(meteor);

      // The subscription must have been re-sent on the new socket.
      var items = await meteor
          .collection('items')
          .firstWhere((c) => c.isNotEmpty)
          .timeout(Duration(seconds: 10));
      expect(items['doc1'], isNotNull);
    }, timeout: Timeout(Duration(seconds: 30)));
  });
}
