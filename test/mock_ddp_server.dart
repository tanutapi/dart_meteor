/// A minimal in-process DDP server speaking protocol version "1", matching
/// the behavior of a Meteor 3.x server (tested against Meteor 3.5.1) over
/// `/websocket`. Shared by the protocol and lifecycle test suites so neither
/// needs a real Meteor server or docker.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Server-side state of one DDP session, modelled on `Session` in Meteor's
/// `ddp-server/livedata_server.js` after session resumption landed
/// (meteor/meteor#14051).
class MockDdpSession {
  MockDdpSession(this.id);

  final String id;
  WebSocket? socket;

  /// Messages sent on this session excluding ping/pong, compared against the
  /// client's `receivedCount` on reconnect.
  int sentCount = 0;

  /// Non-null while the session is disconnected and waiting to be resumed.
  List<Map<String, dynamic>>? messageQueue;
  Timer? removeTimer;

  /// Set by a client `disconnect` message; such a session is never resumed.
  bool expectingDisconnect = false;

  /// Ids of the subscriptions the client has open on this session.
  final Set<String> subscriptionIds = {};
}

class MockDdpServer {
  HttpServer? _httpServer;
  final List<WebSocket> _sockets = [];
  final Map<WebSocket, MockDdpSession> _sessionBySocket = {};
  final Map<String, MockDdpSession> _sessions = {};
  int _sessionCounter = 0;
  int? _boundPort;

  /// When true the server behaves like Meteor with meteor/meteor#14051: an
  /// ungracefully dropped session is kept for [disconnectGracePeriod] and
  /// resumed if the client reconnects with the same session id and a matching
  /// message count. When false (default) every connect starts a new session,
  /// like Meteor releases before that change.
  bool supportsResumption = false;

  /// How long a dropped session is kept around for resumption.
  Duration disconnectGracePeriod = const Duration(seconds: 15);

  /// Messages queued for a dropped session before it is given up on.
  int maxMessageQueueLength = 100;

  /// Session ids handed out by `connected`, in order. A resumed session
  /// repeats the previous id.
  final List<String> sessionIdsSent = [];

  /// How many sessions were created (resumptions do not count), i.e. how many
  /// times `onConnection` would have fired on a real server.
  int sessionCount = 0;

  /// Sessions currently known to the server, live or awaiting resumption.
  Iterable<MockDdpSession> get sessions => _sessions.values;

  /// The port the server is (or last was) bound to. Stable across a
  /// [stop]/[start] cycle so tests can simulate a server outage.
  int get port => _httpServer?.port ?? _boundPort!;

  /// Documents published by the `items` publication.
  final Map<String, Map<String, dynamic>> itemsCollection = {};

  /// Digest expected from loginWithPassword for user1/password1.
  static final String user1Digest =
      sha256.convert(utf8.encode('password1')).toString();

  /// The last login request received, for asserting on the wire format.
  Map<String, dynamic>? lastLoginRequest;

  /// The last method message received, for asserting on the wire format.
  Map<String, dynamic>? lastMethodMessage;

  /// When false the server ignores client `ping` messages, simulating a
  /// connection that has gone stale without the socket being closed - what a
  /// sleeping device sees on wake.
  bool respondToPings = true;

  /// Methods named here are accepted but never answered, so the client is
  /// left with an in-flight call.
  final Set<String> silentMethods = {};

  /// Methods named here are answered only after the given delay, so a result
  /// can land while the client is disconnected.
  final Map<String, Duration> delayedMethods = {};

  /// How many websocket connections have been accepted over this server's
  /// lifetime, including across restarts.
  int connectionCount = 0;

  /// Every message received, grouped by the socket it arrived on. Index 0 is
  /// the first connection. Used to assert on message ordering after a
  /// reconnect.
  final List<List<Map<String, dynamic>>> messagesBySocket = [];

  /// Messages received on the most recently accepted socket.
  List<Map<String, dynamic>> get messagesOnLatestSocket =>
      messagesBySocket.isEmpty ? const [] : messagesBySocket.last;

  Future<void> start({int? port}) async {
    _httpServer =
        await HttpServer.bind(InternetAddress.loopbackIPv4, port ?? 0);
    _boundPort = _httpServer!.port;
    _httpServer!.listen((HttpRequest req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        var socket = await WebSocketTransformer.upgrade(req);
        _sockets.add(socket);
        connectionCount++;
        var inbox = <Map<String, dynamic>>[];
        messagesBySocket.add(inbox);
        // Meteor sends server_id as the very first message on the socket.
        socket.add(json.encode({'server_id': '0'}));
        socket.listen((data) => _onMessage(socket, inbox, data),
            onDone: () => _onSocketClosed(socket));
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
    for (var session in _sessions.values) {
      session.removeTimer?.cancel();
    }
    _sessions.clear();
    _sessionBySocket.clear();
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  /// Drop every socket without warning - what the client sees on a network
  /// loss. Sessions stay resumable if [supportsResumption] is on.
  void closeAllSockets() {
    for (var socket in List<WebSocket>.from(_sockets)) {
      // Detach synchronously: a real server notices its own close at once,
      // whereas the websocket's onDone only fires after the close handshake,
      // by which time a fast client may already be reconnecting.
      _onSocketClosed(socket);
      socket.close();
    }
    _sockets.clear();
  }

  /// Server-initiated close of every session (`connection.close()` on the
  /// server). Never resumable, regardless of [supportsResumption].
  void closeAllSessions() {
    for (var session in List<MockDdpSession>.from(_sessions.values)) {
      session.expectingDisconnect = true;
      _destroySession(session);
    }
    closeAllSockets();
  }

  void _onSocketClosed(WebSocket socket) {
    _sockets.remove(socket);
    var session = _sessionBySocket.remove(socket);
    if (session == null || session.socket != socket) {
      return;
    }
    session.socket = null;
    if (!supportsResumption || session.expectingDisconnect) {
      _destroySession(session);
      return;
    }
    // Ungraceful disconnect: queue outgoing messages and wait for a resume.
    session.messageQueue = [];
    session.removeTimer?.cancel();
    session.removeTimer =
        Timer(disconnectGracePeriod, () => _destroySession(session));
  }

  void _destroySession(MockDdpSession session) {
    session.removeTimer?.cancel();
    session.removeTimer = null;
    session.messageQueue = null;
    _sessions.remove(session.id);
  }

  void _handleConnect(WebSocket socket, Map<String, dynamic> msg) {
    if (msg['version'] != '1' || !(msg['support'] as List).contains('1')) {
      _sendRaw(socket, {'msg': 'failed', 'version': '1'});
      return;
    }
    var existing = _sessions[msg['session']];
    var resumable = supportsResumption &&
        existing != null &&
        existing.socket == null &&
        existing.removeTimer != null &&
        !existing.expectingDisconnect &&
        existing.sentCount == msg['receivedCount'];
    if (resumable) {
      existing.removeTimer?.cancel();
      existing.removeTimer = null;
      var queue = existing.messageQueue ?? const [];
      existing.messageQueue = null;
      existing.socket = socket;
      _sessionBySocket[socket] = existing;
      sessionIdsSent.add(existing.id);
      _sendOn(existing, {'msg': 'connected', 'session': existing.id});
      for (var queued in queue) {
        _sendOn(existing, queued);
      }
      return;
    }
    if (existing != null) {
      // Out of date (or not resumable) - drop the old session immediately.
      _destroySession(existing);
    }
    var session = MockDdpSession('mock-session-${++_sessionCounter}');
    session.socket = socket;
    _sessions[session.id] = session;
    _sessionBySocket[socket] = session;
    sessionCount++;
    sessionIdsSent.add(session.id);
    _sendOn(session, {'msg': 'connected', 'session': session.id});
  }

  /// Send on the session a socket belongs to, so the message is counted and,
  /// while the session is disconnected, queued.
  void _send(WebSocket socket, Map<String, dynamic> msg) {
    var session = _sessionBySocket[socket];
    if (session == null) {
      _sendRaw(socket, msg);
      return;
    }
    _sendOn(session, msg);
  }

  void _sendOn(MockDdpSession session, Map<String, dynamic> msg) {
    var counted = msg['msg'] != 'ping' && msg['msg'] != 'pong';
    var queue = session.messageQueue;
    if (queue != null) {
      if (counted) {
        queue.add(msg);
        if (queue.length > maxMessageQueueLength) {
          _destroySession(session);
        }
      }
      return;
    }
    var socket = session.socket;
    if (socket == null) {
      return;
    }
    if (counted) {
      session.sentCount++;
    }
    _sendRaw(socket, msg);
  }

  void _sendRaw(WebSocket socket, Map<String, dynamic> msg) {
    // A message can be in flight when the test closes the socket underneath
    // us; a real server would just drop it.
    if (socket.readyState != WebSocket.open) {
      return;
    }
    try {
      socket.add(json.encode(msg));
    } on StateError {
      // Sink closed between the check and the write.
    }
  }

  void _onMessage(
      WebSocket socket, List<Map<String, dynamic>> inbox, dynamic data) {
    var msg = json.decode(data) as Map<String, dynamic>;
    inbox.add(msg);
    switch (msg['msg']) {
      case 'connect':
        _handleConnect(socket, msg);
        break;
      case 'disconnect':
        // Graceful disconnect: the session is torn down as soon as the
        // socket goes, never resumed.
        _sessionBySocket[socket]?.expectingDisconnect = true;
        break;
      case 'ping':
        if (respondToPings) {
          _send(
              socket, {'msg': 'pong', if (msg['id'] != null) 'id': msg['id']});
        }
        break;
      case 'pong':
        break;
      case 'method':
        _handleMethod(socket, msg);
        break;
      case 'sub':
        _sessionBySocket[socket]?.subscriptionIds.add(msg['id']);
        _handleSub(socket, msg);
        break;
      case 'unsub':
        _sessionBySocket[socket]?.subscriptionIds.remove(msg['id']);
        _send(socket, {'msg': 'nosub', 'id': msg['id']});
        break;
    }
  }

  void _handleMethod(WebSocket socket, Map<String, dynamic> msg) {
    lastMethodMessage = msg;
    var id = msg['id'];
    var params = msg['params'] as List? ?? [];
    if (silentMethods.contains(msg['method'])) {
      return;
    }
    var delay = delayedMethods[msg['method']];
    if (delay != null) {
      var session = _sessionBySocket[socket];
      Timer(delay, () {
        if (session != null) {
          _sendOn(session, {'msg': 'result', 'id': id, 'result': params});
          _sendOn(session, {
            'msg': 'updated',
            'methods': [id]
          });
        }
      });
      return;
    }
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

  /// Push a message to every session, live or waiting to be resumed (for
  /// the latter it is queued, exactly like an observe callback firing during
  /// the grace period).
  void broadcast(Map<String, dynamic> msg) {
    for (var session in List<MockDdpSession>.from(_sessions.values)) {
      _sendOn(session, msg);
    }
  }
}
