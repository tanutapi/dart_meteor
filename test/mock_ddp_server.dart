/// A minimal in-process DDP server speaking protocol version "1", matching
/// the behavior of a Meteor 3.x server (tested against Meteor 3.5.1) over
/// `/websocket`. Shared by the protocol and lifecycle test suites so neither
/// needs a real Meteor server or docker.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class MockDdpServer {
  HttpServer? _httpServer;
  final List<WebSocket> _sockets = [];
  int? _boundPort;

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
        if ((msg['version'] == '1') && (msg['support'] as List).contains('1')) {
          _send(socket, {'msg': 'connected', 'session': 'mock-session-id'});
        } else {
          _send(socket, {'msg': 'failed', 'version': '1'});
        }
        break;
      case 'ping':
        if (respondToPings) {
          _send(socket, {'msg': 'pong', if (msg['id'] != null) 'id': msg['id']});
        }
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
    if (silentMethods.contains(msg['method'])) {
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

  /// Push a change on the `items` collection to every connected client.
  void broadcast(Map<String, dynamic> msg) {
    for (var socket in _sockets) {
      _send(socket, msg);
    }
  }
}
