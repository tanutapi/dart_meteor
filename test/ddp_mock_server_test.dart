/// Tests the MeteorClient/DdpClient against a local mock server that
/// implements the DDP protocol (version "1") exactly as a Meteor 3.x server
/// (tested against the behavior of Meteor 3.5.1) speaks it over
/// `/websocket`. These tests run standalone - no Meteor server or docker
/// required.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_meteor/dart_meteor.dart';
import 'package:test/test.dart';

/// A minimal in-process DDP server speaking protocol version "1".
class MockDdpServer {
  HttpServer? _httpServer;
  final List<WebSocket> _sockets = [];
  int get port => _httpServer!.port;

  /// Documents published by the `items` publication.
  final Map<String, Map<String, dynamic>> itemsCollection = {};

  /// Digest expected from loginWithPassword for user1/password1.
  static final String user1Digest =
      sha256.convert(utf8.encode('password1')).toString();

  /// The last login request received, for asserting on the wire format.
  Map<String, dynamic>? lastLoginRequest;

  /// The last method message received, for asserting on the wire format.
  Map<String, dynamic>? lastMethodMessage;

  Future<void> start() async {
    _httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _httpServer!.listen((HttpRequest req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        var socket = await WebSocketTransformer.upgrade(req);
        _sockets.add(socket);
        // Meteor sends server_id as the very first message on the socket.
        socket.add(json.encode({'server_id': '0'}));
        socket.listen((data) => _onMessage(socket, data),
            onDone: () => _sockets.remove(socket));
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    });
  }

  Future<void> stop() async {
    for (var socket in List<WebSocket>.from(_sockets)) {
      await socket.close();
    }
    _sockets.clear();
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  void closeAllSockets() {
    for (var socket in List<WebSocket>.from(_sockets)) {
      socket.close();
    }
    _sockets.clear();
  }

  void _send(WebSocket socket, Map<String, dynamic> msg) {
    socket.add(json.encode(msg));
  }

  void _onMessage(WebSocket socket, dynamic data) {
    var msg = json.decode(data) as Map<String, dynamic>;
    switch (msg['msg']) {
      case 'connect':
        if ((msg['version'] == '1') && (msg['support'] as List).contains('1')) {
          _send(socket, {'msg': 'connected', 'session': 'mock-session-id'});
        } else {
          _send(socket, {'msg': 'failed', 'version': '1'});
        }
        break;
      case 'ping':
        _send(socket, {'msg': 'pong', if (msg['id'] != null) 'id': msg['id']});
        break;
      case 'pong':
        break;
      case 'method':
        _handleMethod(socket, msg);
        break;
      case 'sub':
        _handleSub(socket, msg);
        break;
      case 'unsub':
        _send(socket, {'msg': 'nosub', 'id': msg['id']});
        break;
    }
  }

  void _handleMethod(WebSocket socket, Map<String, dynamic> msg) {
    lastMethodMessage = msg;
    var id = msg['id'];
    var params = msg['params'] as List? ?? [];
    switch (msg['method']) {
      case 'login':
        var loginData = params.isNotEmpty
            ? params[0] as Map<String, dynamic>
            : <String, dynamic>{};
        lastLoginRequest = loginData;
        var password = loginData['password'];
        var resume = loginData['resume'];
        var validPassword = password is Map &&
            password['algorithm'] == 'sha-256' &&
            password['digest'] == user1Digest;
        var validResume = resume == 'valid-resume-token';
        if (validPassword || validResume) {
          _send(socket, {
            'msg': 'result',
            'id': id,
            'result': {
              'id': 'user1-id',
              'token': 'valid-resume-token',
              'tokenExpires': {
                '\$date': DateTime.now()
                    .add(Duration(days: 90))
                    .millisecondsSinceEpoch
              },
            },
          });
          _send(socket, {
            'msg': 'updated',
            'methods': [id]
          });
        } else {
          _send(socket, {
            'msg': 'result',
            'id': id,
            'error': {
              'isClientSafe': true,
              'error': 403,
              'reason': 'Incorrect password',
              'message': 'Incorrect password [403]',
              'errorType': 'Meteor.Error',
            },
          });
        }
        break;
      case 'echo':
        _send(socket, {'msg': 'result', 'id': id, 'result': params});
        _send(socket, {
          'msg': 'updated',
          'methods': [id]
        });
        break;
      case 'methodThatReturnNumber':
        _send(socket, {'msg': 'result', 'id': id, 'result': 42});
        _send(socket, {
          'msg': 'updated',
          'methods': [id]
        });
        break;
      case 'methodThatReturnDate':
        _send(socket, {
          'msg': 'result',
          'id': id,
          'result': {
            'createdAt': {'\$date': 1598804210504},
          },
        });
        _send(socket, {
          'msg': 'updated',
          'methods': [id]
        });
        break;
      case 'methodThatThrowError':
        _send(socket, {
          'msg': 'result',
          'id': id,
          'error': {
            'isClientSafe': true,
            'error': 500,
            'reason': 'This is an error',
            'message': 'This is an error [500]',
            'errorType': 'Meteor.Error',
          },
        });
        break;
      default:
        _send(socket, {
          'msg': 'result',
          'id': id,
          'error': {
            'isClientSafe': true,
            'error': 404,
            'reason': "Method '${msg['method']}' not found",
            'errorType': 'Meteor.Error',
          },
        });
    }
  }

  void _handleSub(WebSocket socket, Map<String, dynamic> msg) {
    var id = msg['id'];
    switch (msg['name']) {
      case 'items':
        itemsCollection.forEach((docId, fields) {
          _send(socket, {
            'msg': 'added',
            'collection': 'items',
            'id': docId,
            'fields': fields,
          });
        });
        _send(socket, {
          'msg': 'ready',
          'subs': [id]
        });
        break;
      default:
        _send(socket, {
          'msg': 'nosub',
          'id': id,
          'error': {
            'isClientSafe': true,
            'error': 404,
            'reason': "Subscription '${msg['name']}' not found",
            'errorType': 'Meteor.Error',
          },
        });
    }
  }

  /// Push a change on the `items` collection to every connected client.
  void broadcast(Map<String, dynamic> msg) {
    for (var socket in _sockets) {
      _send(socket, msg);
    }
  }
}

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
      expect(meteor.connection.sessionId, 'mock-session-id');
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
