/// Regression tests for the connection lifecycle: what happens when a device
/// sleeps, when the socket goes stale without closing, when the server is
/// unreachable, and when the app is explicitly disconnected.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_meteor/dart_meteor.dart';
import 'package:test/test.dart';

import 'mock_ddp_server.dart';

/// Short timings so the ping/pong paths can be exercised in a test run
/// instead of the 20s/5s production defaults.
MeteorClient _connectClient(int port) => MeteorClient.connect(
      url: 'ws://127.0.0.1:$port',
      pingInterval: Duration(milliseconds: 300),
      pongTimeout: Duration(milliseconds: 300),
      maxRetryInterval: Duration(seconds: 2),
      stalenessThreshold: Duration(milliseconds: 600),
    );

Future<void> _waitForConnected(MeteorClient meteor,
    {Duration timeout = const Duration(seconds: 10)}) async {
  await meteor
      .status()
      .firstWhere((s) => s.status == DdpConnectionStatusValues.connected)
      .timeout(timeout);
}

Future<void> _waitForDisconnected(MeteorClient meteor,
    {Duration timeout = const Duration(seconds: 10)}) async {
  await meteor
      .status()
      .firstWhere((s) => s.status != DdpConnectionStatusValues.connected)
      .timeout(timeout);
}

void main() {
  group('connection lifecycle', () {
    late MockDdpServer server;
    late MeteorClient meteor;

    setUp(() async {
      server = MockDdpServer();
      server.itemsCollection['doc1'] = {'title': 'First'};
      await server.start();
      meteor = _connectClient(server.port);
      await _waitForConnected(meteor);
    });

    tearDown(() async {
      meteor.disconnect();
      await server.stop();
    });

    test('recovers when the server stops answering pings', () async {
      // The socket stays open but the server goes silent - exactly what a
      // client sees when the device slept and the server gave up on it.
      server.respondToPings = false;
      await _waitForDisconnected(meteor);

      // The client must not give up: once the server is healthy again it has
      // to reconnect on its own, with no manual reconnect() call.
      server.respondToPings = true;
      await _waitForConnected(meteor);
      expect(await meteor.call('methodThatReturnNumber'), 42);
    }, timeout: Timeout(Duration(seconds: 30)));

    test(
        'an in-flight method call fails instead of hanging when the socket drops',
        () async {
      server.silentMethods.add('neverReturns');
      var future = meteor.call('neverReturns');
      await Future.delayed(Duration(milliseconds: 100));
      server.closeAllSockets();

      await expectLater(
        future.timeout(Duration(seconds: 5)),
        throwsA(isA<MeteorConnectionError>()),
      );
    }, timeout: Timeout(Duration(seconds: 30)));

    test('a method call made while offline fails immediately', () async {
      meteor.disconnect();
      await expectLater(
        meteor.call('methodThatReturnNumber').timeout(Duration(seconds: 5)),
        throwsA(isA<MeteorConnectionError>()),
      );
    });

    test('subscriptions are re-sent only after the login is resumed', () async {
      await meteor.loginWithPassword('user1', 'password1');
      meteor.subscribe('items');
      await Future.delayed(Duration(milliseconds: 200));

      var socketsBefore = server.connectionCount;
      server.closeAllSockets();
      await _waitForDisconnected(meteor);
      await _waitForConnected(meteor);
      await Future.delayed(Duration(milliseconds: 300));

      expect(server.connectionCount, greaterThan(socketsBefore));
      var msgs = server.messagesOnLatestSocket;
      var loginIndex = msgs
          .indexWhere((m) => m['msg'] == 'method' && m['method'] == 'login');
      var subIndex = msgs.indexWhere((m) => m['msg'] == 'sub');
      expect(loginIndex, isNonNegative,
          reason: 'the resume login must be sent on the new socket');
      expect(subIndex, isNonNegative,
          reason: 'the subscription must be re-sent on the new socket');
      expect(loginIndex, lessThan(subIndex),
          reason: 'login must precede the re-subscribe so publications '
              'see this.userId');
    }, timeout: Timeout(Duration(seconds: 30)));

    test('notifyAppResumed reconnects a client whose socket died while asleep',
        () async {
      meteor.notifyAppPaused();
      server.closeAllSockets();
      await _waitForDisconnected(meteor);

      meteor.notifyAppResumed();
      await _waitForConnected(meteor, timeout: Duration(seconds: 5));
      expect(await meteor.call('methodThatReturnNumber'), 42);
    }, timeout: Timeout(Duration(seconds: 30)));

    test('notifyAppResumed tears down a socket that went stale while suspended',
        () async {
      meteor.notifyAppPaused();
      // Server goes silent; while paused the client does not act on it.
      server.respondToPings = false;
      await Future.delayed(Duration(seconds: 1));
      expect((await meteor.status().first).status,
          DdpConnectionStatusValues.connected,
          reason: 'a paused app should not tear down its connection');

      var socketsBefore = server.connectionCount;
      server.respondToPings = true;
      meteor.notifyAppResumed();

      // The wall-clock gap exceeds the staleness threshold, so the stale
      // socket must be replaced rather than trusted: a brand new socket has to
      // appear at the server.
      var deadline = DateTime.now().add(Duration(seconds: 10));
      while (server.connectionCount == socketsBefore &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(Duration(milliseconds: 50));
      }
      expect(server.connectionCount, greaterThan(socketsBefore),
          reason: 'a stale socket must be replaced on resume');
      await _waitForConnected(meteor, timeout: Duration(seconds: 10));
      expect(await meteor.call('methodThatReturnNumber'), 42);
    }, timeout: Timeout(Duration(seconds: 30)));
  });

  group('session resumption (meteor/meteor#14051)', () {
    late MockDdpServer server;
    late MeteorClient meteor;

    setUp(() async {
      server = MockDdpServer()..supportsResumption = true;
      server.itemsCollection['doc1'] = {'title': 'First'};
      await server.start();
      meteor = _connectClient(server.port);
      await _waitForConnected(meteor);
    });

    tearDown(() async {
      meteor.disconnect();
      await server.stop();
    });

    test('receivedCount counts every message except ping/pong', () async {
      // Let a few client pings and server pongs go by.
      await Future.delayed(Duration(seconds: 1));
      expect(meteor.connection.receivedCount, 1,
          reason: 'only the connected message has been counted so far');
      expect(server.sessions.single.sentCount, 1);

      meteor.subscribe('items');
      await Future.delayed(Duration(milliseconds: 300));
      // added + ready
      expect(meteor.connection.receivedCount, 3);
      expect(meteor.connection.receivedCount, server.sessions.single.sentCount,
          reason: 'client and server counts must stay in lockstep');
    }, timeout: Timeout(Duration(seconds: 30)));

    test('an unexpected drop resumes the session without re-login or re-sub',
        () async {
      await meteor.loginWithPassword('user1', 'password1');
      meteor.subscribe('items');
      await Future.delayed(Duration(milliseconds: 200));
      var sessionBefore = meteor.connection.sessionId;
      var socketsBefore = server.connectionCount;

      server.closeAllSockets();
      await _waitForDisconnected(meteor);
      await _waitForConnected(meteor);
      await Future.delayed(Duration(milliseconds: 300));

      expect(server.connectionCount, greaterThan(socketsBefore));
      expect(meteor.connection.sessionId, sessionBefore,
          reason: 'the server must hand back the same session id');
      expect(meteor.connection.resumedSession, isTrue);
      expect(server.sessionCount, 1,
          reason: 'no new server session (onConnection) on resume');
      var msgs = server.messagesOnLatestSocket;
      expect(msgs.first['msg'], 'connect');
      expect(msgs.first['session'], sessionBefore);
      expect(msgs.first['receivedCount'], isA<int>());
      expect(msgs.where((m) => m['msg'] == 'method'), isEmpty,
          reason: 'the login must not be re-sent on a resumed session');
      expect(msgs.where((m) => m['msg'] == 'sub'), isEmpty,
          reason: 'subscriptions must not be re-sent on a resumed session');
      expect(await meteor.userId().first, 'user1-id');
      // The session is still fully usable afterwards.
      expect(await meteor.call('methodThatReturnNumber'), 42);
    }, timeout: Timeout(Duration(seconds: 30)));

    test('messages published during the gap are delivered after the resume',
        () async {
      meteor.subscribe('items');
      await Future.delayed(Duration(milliseconds: 200));
      var items = <Map<String, dynamic>>[];
      var sub = meteor.collection('items').listen(items.add);

      server.closeAllSockets();
      await _waitForDisconnected(meteor);
      server.broadcast({
        'msg': 'added',
        'collection': 'items',
        'id': 'doc2',
        'fields': {'title': 'Added while away'},
      });
      await _waitForConnected(meteor);
      await Future.delayed(Duration(milliseconds: 300));
      await sub.cancel();

      expect(meteor.connection.resumedSession, isTrue);
      expect(items.last['doc2']?['title'], 'Added while away');
      expect(meteor.connection.receivedCount, server.sessions.single.sentCount);
    }, timeout: Timeout(Duration(seconds: 30)));

    test('an in-flight method call completes after the session is resumed',
        () async {
      server.delayedMethods['slowEcho'] = Duration(milliseconds: 600);
      var future = meteor.apply('slowEcho', ['hello']);
      await Future.delayed(Duration(milliseconds: 100));
      server.closeAllSockets();
      await _waitForDisconnected(meteor);

      expect(await future.timeout(Duration(seconds: 5)), ['hello']);
      expect(meteor.connection.resumedSession, isTrue);
    }, timeout: Timeout(Duration(seconds: 30)));

    test('a message count mismatch starts a new session and re-subscribes',
        () async {
      await meteor.loginWithPassword('user1', 'password1');
      meteor.subscribe('items');
      await Future.delayed(Duration(milliseconds: 200));
      var sessionBefore = meteor.connection.sessionId;
      server.silentMethods.add('neverReturns');
      var pending = expectLater(
          meteor.call('neverReturns'), throwsA(isA<MeteorConnectionError>()));

      server.closeAllSockets();
      await _waitForDisconnected(meteor);
      // Pretend the server sent something the client never got.
      server.sessions.single.sentCount++;
      await _waitForConnected(meteor);
      await Future.delayed(Duration(milliseconds: 300));

      expect(meteor.connection.sessionId, isNot(sessionBefore));
      expect(meteor.connection.resumedSession, isFalse);
      expect(server.sessionCount, 2);
      expect(meteor.connection.receivedCount, server.sessions.single.sentCount);
      var msgs = server.messagesOnLatestSocket;
      expect(msgs.any((m) => m['msg'] == 'method' && m['method'] == 'login'),
          isTrue,
          reason: 'a new session must re-run the login');
      expect(msgs.any((m) => m['msg'] == 'sub'), isTrue,
          reason: 'a new session must re-send subscriptions');
      await pending;
    }, timeout: Timeout(Duration(seconds: 30)));

    test('an explicit disconnect tells the server and is never resumed',
        () async {
      var sessionBefore = meteor.connection.sessionId;
      meteor.disconnect();
      await Future.delayed(Duration(milliseconds: 200));

      expect(server.messagesOnLatestSocket.last['msg'], 'disconnect');
      expect(server.sessions, isEmpty,
          reason: 'a graceful disconnect must free the session immediately');

      meteor.reconnect();
      await _waitForConnected(meteor);
      expect(meteor.connection.sessionId, isNot(sessionBefore));
      expect(meteor.connection.resumedSession, isFalse);
      expect(
          server.messagesOnLatestSocket.first.containsKey('session'), isFalse,
          reason: 'after an explicit disconnect the client must not ask to '
              'resume');
    }, timeout: Timeout(Duration(seconds: 30)));

    test('a server-initiated close is not resumed', () async {
      var sessionBefore = meteor.connection.sessionId;
      server.closeAllSessions();
      await _waitForDisconnected(meteor);
      await _waitForConnected(meteor);

      expect(meteor.connection.sessionId, isNot(sessionBefore));
      expect(meteor.connection.resumedSession, isFalse);
      expect(server.sessionCount, 2);
    }, timeout: Timeout(Duration(seconds: 30)));

    test('a session whose grace period expired is not resumed', () async {
      server.disconnectGracePeriod = Duration.zero;
      var sessionBefore = meteor.connection.sessionId;
      server.closeAllSockets();
      await _waitForDisconnected(meteor);
      await _waitForConnected(meteor);

      expect(meteor.connection.sessionId, isNot(sessionBefore));
      expect(meteor.connection.resumedSession, isFalse);
      expect(await meteor.call('methodThatReturnNumber'), 42);
    }, timeout: Timeout(Duration(seconds: 30)));

    test('a server without resumption support still gets a working reconnect',
        () async {
      server.supportsResumption = false;
      await meteor.loginWithPassword('user1', 'password1');
      meteor.subscribe('items');
      await Future.delayed(Duration(milliseconds: 200));
      var sessionBefore = meteor.connection.sessionId;

      server.closeAllSockets();
      await _waitForDisconnected(meteor);
      await _waitForConnected(meteor);
      await Future.delayed(Duration(milliseconds: 300));

      // The client asked to resume, the server ignored it and started fresh.
      expect(server.messagesOnLatestSocket.first['session'], sessionBefore);
      expect(meteor.connection.sessionId, isNot(sessionBefore));
      expect(meteor.connection.resumedSession, isFalse);
      expect(
          server.messagesOnLatestSocket.any((m) => m['msg'] == 'sub'), isTrue);
      expect(await meteor.userId().first, 'user1-id');
    }, timeout: Timeout(Duration(seconds: 30)));
  });

  group('reconnect policy', () {
    test('a user-initiated disconnect is not undone by a pending retry',
        () async {
      var server = MockDdpServer();
      await server.start();
      var meteor = _connectClient(server.port);
      await _waitForConnected(meteor);

      server.closeAllSockets();
      await _waitForDisconnected(meteor);
      var socketsAtDisconnect = server.connectionCount;
      meteor.disconnect();

      await Future.delayed(Duration(seconds: 3));
      var status = await meteor.status().first;
      expect(status.status, DdpConnectionStatusValues.offline);
      expect(server.connectionCount, socketsAtDisconnect,
          reason: 'no new socket may be opened after an explicit disconnect');

      await server.stop();
    }, timeout: Timeout(Duration(seconds: 30)));

    test('an unreachable server backs off instead of spinning', () async {
      // Accepts TCP but refuses the websocket upgrade, so every attempt fails
      // the same way and is countable.
      var attempts = 0;
      var httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      httpServer.listen((req) async {
        attempts++;
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });

      var meteor = _connectClient(httpServer.port);
      var retryTimes = <int>[];
      var sub = meteor.status().listen((s) {
        if (s.status == DdpConnectionStatusValues.waiting) {
          retryTimes.add(s.retryTime.inMilliseconds);
        }
      });

      await Future.delayed(Duration(seconds: 4));
      await sub.cancel();
      meteor.disconnect();
      await httpServer.close(force: true);

      // A tight loop would rack up hundreds of attempts in 4 seconds.
      expect(attempts, lessThan(6),
          reason: 'reconnects must back off, not spin');
      expect(retryTimes.length, greaterThan(1),
          reason: 'the client must keep retrying');
      // The first entry is the client's initial `waiting` state, not a retry;
      // what matters is that the interval climbs to the configured ceiling.
      expect(retryTimes.reduce((a, b) => a > b ? a : b),
          greaterThanOrEqualTo(2000),
          reason: 'the backoff interval must grow up to maxRetryInterval');
      expect(retryTimes.last, greaterThanOrEqualTo(retryTimes.first),
          reason: 'the backoff interval must not shrink back to zero');
    }, timeout: Timeout(Duration(seconds: 30)));

    test('connecting to an unreachable port does not throw unhandled errors',
        () async {
      var errors = <Object>[];
      await runZonedGuarded(() async {
        // Nothing is listening here.
        var meteor = MeteorClient.connect(
          url: 'ws://127.0.0.1:1',
          pingInterval: Duration(milliseconds: 300),
          pongTimeout: Duration(milliseconds: 300),
          maxRetryInterval: Duration(seconds: 1),
        );
        await Future.delayed(Duration(seconds: 3));
        var status = await meteor.status().first;
        expect(
            status.status,
            anyOf(
              DdpConnectionStatusValues.waiting,
              DdpConnectionStatusValues.offline,
              DdpConnectionStatusValues.connecting,
              DdpConnectionStatusValues.failed,
            ));
        meteor.disconnect();
      }, (error, stack) {
        errors.add(error);
      });
      await Future.delayed(Duration(milliseconds: 500));
      expect(errors, isEmpty,
          reason: 'a failed connection must not escape as an unhandled error');
    }, timeout: Timeout(Duration(seconds: 30)));
  });
}
