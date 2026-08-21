import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:async';
import 'dart:math';

enum DdpConnectionStatusValues {
  connected,
  connecting,
  failed,
  waiting,
  offline
}

/// Thrown into an in-flight method call when the connection is lost before
/// the server replied. Callers can catch this to distinguish "the server said
/// no" (a [MeteorError]) from "we never heard back" - for example after the
/// device slept mid-call.
class MeteorConnectionError extends Error {
  final String reason;
  MeteorConnectionError(this.reason);

  @override
  String toString() => 'MeteorConnectionError: $reason';
}

class DdpConnectionStatus {
  bool connected;
  DdpConnectionStatusValues status;
  int retryCount;
  Duration retryTime;
  String? reason;

  DdpConnectionStatus({
    required this.connected,
    required this.status,
    required this.retryCount,
    required this.retryTime,
    required this.reason,
  });

  /// A point-in-time copy. The client keeps one mutable status internally;
  /// stream subscribers get a snapshot each, so a transition is still readable
  /// by the time the event is delivered even if the client has moved on.
  DdpConnectionStatus copy() {
    return DdpConnectionStatus(
      connected: connected,
      status: status,
      retryCount: retryCount,
      retryTime: retryTime,
      reason: reason,
    );
  }

  @override
  String toString() {
    return 'connected: $connected, status: $status, retryCount: $retryCount, retryTime: $retryTime, reason: $reason';
  }
}

class SubscriptionHandler {
  final DdpClient ddpClient;
  final String subId;
  final StreamController<bool> _readyStreamController = StreamController();
  late Stream<bool> _readyStream;
  final String subName;
  final List<dynamic> args;
  SubscriptionHandler(this.ddpClient, this.subId, this.subName, this.args) {
    _readyStream = _readyStreamController.stream.asBroadcastStream();
    _readyStreamController.sink.add(false);
  }
  Stream<bool> ready() {
    return _readyStream;
  }

  void stop() {
    if (ddpClient._connectionStatus.connected) {
      ddpClient._sendMsgUnsub(subId);
    }
  }
}

class SubscriptionCallback {
  Function Function(dynamic error)? onStop;
  Function? onReady;
  SubscriptionCallback({
    required this.onStop,
    required this.onReady,
  });
}

class OnReconnectionCallback {
  DdpClient ddpClient;
  String id;
  Function callback;
  OnReconnectionCallback({
    required this.ddpClient,
    required this.id,
    required this.callback,
  });

  void stop() {
    ddpClient._onReconnectCallbacks.remove(id);
  }
}

class DdpClient {
  static const int pingIntervalSeconds = 20;
  static const int pongTimeoutSeconds = 5;
  final Random _random = Random.secure();

  final StreamController<DdpConnectionStatus> _statusStreamController =
      StreamController();
  StreamController<dynamic> dataStreamController = StreamController();
  late DdpConnectionStatus _connectionStatus;
  String url;
  String userAgent;
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  int maxRetryCount;

  /// How often a `ping` is sent while the connection is up.
  final Duration pingInterval;

  /// How long to wait for the matching `pong` before treating the connection
  /// as dead.
  final Duration pongTimeout;

  /// Longest gap between reconnect attempts.
  final Duration maxRetryInterval;

  /// If no message at all has been received for this long, the socket is
  /// considered stale on the next liveness check. A suspended process (device
  /// asleep) resumes with a large gap here even though its timers never fired,
  /// which is what lets the client notice immediately rather than waiting a
  /// full ping cycle.
  final Duration stalenessThreshold;

  final Map<String, OnReconnectionCallback> _onReconnectCallbacks = {};
  String? serverId;
  String? sessionId;

  /// Number of DDP messages received from the server in the current session,
  /// excluding `ping`/`pong` (and the pre-session `server_id` frame). Sent with
  /// `connect` so a server that supports session resumption (Meteor PR #14051)
  /// can verify nothing was lost while we were away.
  int _receivedCount = 0;

  /// Whether the most recent `connected` message resumed the previous session
  /// rather than starting a new one.
  bool _lastConnectResumedSession = false;
  int _currentMethodId = 0;
  Timer? _pingPeriodicTimer;
  Timer? _pongTimeoutTimer;
  DateTime? _lastMessageReceivedAt;
  final Map<String, Completer<dynamic>> _methodCompleters = {};
  final Map<String, SubscriptionCallback> _subscriptions = {};
  final Map<String, SubscriptionHandler> _subscriptionHandlers = {};
  bool _isTryToReconnect = true;
  bool _appIsPaused = false;
  Timer? _scheduleReconnectTimer;

  final bool debug;

  DdpClient({
    required this.url,
    this.maxRetryCount = 20,
    this.debug = false,
    required this.userAgent,
    Duration? pingInterval,
    Duration? pongTimeout,
    Duration? maxRetryInterval,
    Duration? stalenessThreshold,
  })  : pingInterval =
            pingInterval ?? const Duration(seconds: pingIntervalSeconds),
        pongTimeout =
            pongTimeout ?? const Duration(seconds: pongTimeoutSeconds),
        maxRetryInterval = maxRetryInterval ?? const Duration(seconds: 30),
        stalenessThreshold = stalenessThreshold ??
            Duration(
              seconds: (pingInterval ??
                          const Duration(seconds: pingIntervalSeconds))
                      .inSeconds +
                  (pongTimeout ?? const Duration(seconds: pongTimeoutSeconds))
                      .inSeconds,
            ) {
    _connectionStatus = DdpConnectionStatus(
      connected: false,
      status: DdpConnectionStatusValues.waiting,
      retryCount: 0,
      retryTime: Duration(seconds: 0),
      reason: null,
    );
    _emitStatus();
    _connect();
  }

  /// Publish a snapshot of the current status. Subscribers must never receive
  /// the client's own mutable instance, or a fast transition (offline ->
  /// waiting -> connecting) would be unreadable by the time it is delivered.
  void _emitStatus() {
    _statusStreamController.sink.add(_connectionStatus.copy());
  }

  void printDebug(String str) {
    if (debug) {
      print('DDP[${_socket.hashCode}] - ${DateTime.now()}');
      print('DDP[${_socket.hashCode}] - $str');
    }
  }

  /// Register a function to call as the first step of reconnecting.
  /// This function can call methods which will be executed before any other outstanding methods.
  /// For example, this can be used to re-establish the appropriate authentication context on the connection.
  ///
  /// The callback may return a [Future]; subscriptions are not re-sent until
  /// it completes, so a publication that depends on `this.userId` sees the
  /// resumed login rather than an anonymous connection.
  ///
  /// callback:
  /// The function to call. It will be called with a single argument, the connection object that is reconnecting.
  void onReconnect(
      FutureOr<void> Function(OnReconnectionCallback reconnection) callback) {
    var id = _generateUID(16);
    var onReconnectCallback =
        OnReconnectionCallback(ddpClient: this, id: id, callback: callback);
    _onReconnectCallbacks[id] = onReconnectCallback;
  }

  String _generateUID(int numOfByte) {
    var values = List<int>.generate(numOfByte, (i) => _random.nextInt(256));
    return base64Url.encode(values);
  }

  SubscriptionHandler subscribe(
    String name,
    List<dynamic> params, {
    Function Function(dynamic error)? onStop,
    Function? onReady,
  }) {
    var id = '$name-${_generateUID(16)}';
    _subscriptions[id] = SubscriptionCallback(onStop: onStop, onReady: onReady);
    params = DdpClient.escapeSpecialFieldValues(params);
    var handler = SubscriptionHandler(this, id, name, params);
    _subscriptionHandlers[id] = handler;
    _sendMsgSub(id, name, params);
    return handler;
  }

  Future<dynamic> call(String method, List<dynamic> params) {
    return apply(method, params);
  }

  Future<dynamic> apply(String method, List<dynamic> params) {
    var methodCompleter = Completer<dynamic>();
    var newId = _currentMethodId.toString();
    params = DdpClient.escapeSpecialFieldValues(params);
    _currentMethodId++;
    _methodCompleters[newId] = methodCompleter;
    if (_socket == null) {
      _failMethodCall(newId, 'Not connected to the server');
    } else {
      _sendMsgMethod(method, params, newId);
    }
    return methodCompleter.future;
  }

  Stream<DdpConnectionStatus> status() {
    return _statusStreamController.stream;
  }

  /// Force an immediate reconnection attempt if the client is not connected.
  void reconnect() {
    printDebug('Reconnect: the connection status is ... $_connectionStatus');
    if (_connectionStatus.status != DdpConnectionStatusValues.connected &&
        _connectionStatus.status != DdpConnectionStatusValues.connecting) {
      _cancelScheduledReconnect();
      _connectionStatus.retryCount = 0;
      _connect();
    }
  }

  /// Tell the client the host application went to the background.
  ///
  /// The connection is left alone - the OS may keep it alive - but the client
  /// stops assuming its timers are reliable from this point on.
  void notifyAppPaused() {
    printDebug('App paused');
    _appIsPaused = true;
  }

  /// Tell the client the host application came back to the foreground.
  ///
  /// This checks how long it has actually been (by wall clock) since the last
  /// message arrived. A process that was suspended wakes up with timers that
  /// never fired and a socket the server may have already discarded, so a
  /// stale connection is torn down and replaced immediately instead of waiting
  /// for the next ping to time out.
  void notifyAppResumed() {
    printDebug('App resumed');
    _appIsPaused = false;
    checkLiveness();
  }

  /// Verify the connection is still alive, tearing it down and reconnecting if
  /// it is not. Safe to call at any time.
  void checkLiveness() {
    if (!_isTryToReconnect) {
      // The user explicitly disconnected; leave it alone.
      return;
    }
    if (_connectionStatus.status == DdpConnectionStatusValues.connected) {
      var last = _lastMessageReceivedAt;
      var silentFor =
          last == null ? stalenessThreshold : DateTime.now().difference(last);
      if (silentFor >= stalenessThreshold) {
        printDebug(
          'Connection considered stale - nothing received for $silentFor',
        );
        _handleConnectionLost('Connection went stale while suspended');
      }
      return;
    }
    // Not connected: the user is looking at the app, so try again now rather
    // than sitting out the remaining backoff.
    _cancelScheduledReconnect();
    _connectionStatus.retryCount = 0;
    _connect();
  }

  /// `true` if the last `connected` message from the server resumed the
  /// previous DDP session (same session id, no data lost), `false` if it
  /// started a fresh one. Only meaningful while connected.
  bool get resumedSession => _lastConnectResumedSession;

  /// Messages received from the server in this session, excluding ping/pong.
  /// Exposed for tests and diagnostics.
  int get receivedCount => _receivedCount;

  /// Disconnect the client from the server. The client stays offline until
  /// [reconnect] is called.
  void disconnect() {
    printDebug('Begin of disconnect()');
    _isTryToReconnect = false;
    _cancelScheduledReconnect();
    // Tell the server this is intentional so it drops the session right away
    // instead of holding it open for the resumption grace period.
    _sendMsgDisconnect();
    _teardownConnection('Disconnected by the client', keepSession: false);
    _connectionStatus.retryCount = 0;
    _connectionStatus.connected = false;
    _connectionStatus.status = DdpConnectionStatusValues.offline;
    _connectionStatus.reason = null;
    _emitStatus();
    printDebug('End of disconnect()');
  }

  /// Close the current socket and release everything attached to it, without
  /// deciding whether to reconnect.
  ///
  /// With [keepSession] the session id, message count and in-flight method
  /// calls survive so the next `connect` can try to resume the session; they
  /// are dropped only if the server then answers with a new session. Without
  /// it everything is forgotten and [reason] is reported to any in-flight
  /// method calls.
  void _teardownConnection(String reason, {required bool keepSession}) {
    _pingPeriodicTimer?.cancel();
    _pingPeriodicTimer = null;
    _pongTimeoutTimer?.cancel();
    _pongTimeoutTimer = null;

    var subscription = _socketSubscription;
    _socketSubscription = null;
    subscription?.cancel().catchError((Object err) {
      printDebug('Error while cancelling the socket subscription: $err');
    });

    var socket = _socket;
    _socket = null;
    if (socket != null) {
      socket.sink.close().catchError((Object err) {
        printDebug('Error while closing the socket: $err');
      });
    }

    serverId = null;
    _lastMessageReceivedAt = null;
    if (!keepSession) {
      _forgetSession();
      _failAllPendingMethodCalls(reason);
    }
  }

  void _forgetSession() {
    sessionId = null;
    _receivedCount = 0;
    _lastConnectResumedSession = false;
  }

  /// Handle a connection that dropped on its own (socket closed, error, or a
  /// missed pong) as opposed to one the user closed. Always schedules a
  /// reconnect.
  void _handleConnectionLost(String reason) {
    if (_connectionStatus.status == DdpConnectionStatusValues.waiting) {
      // A reconnect is already pending; nothing more to do.
      return;
    }
    printDebug('Connection lost: $reason');
    _teardownConnection(reason, keepSession: true);
    _connectionStatus.connected = false;
    _connectionStatus.status = DdpConnectionStatusValues.offline;
    _connectionStatus.reason = reason;
    _emitStatus();
    if (_isTryToReconnect) {
      _scheduleReconnect();
    }
  }

  void _failMethodCall(String id, String reason) {
    var completer = _methodCompleters.remove(id);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(MeteorConnectionError(reason));
    }
  }

  void _failAllPendingMethodCalls(String reason) {
    if (_methodCompleters.isEmpty) {
      return;
    }
    printDebug(
      'Failing ${_methodCompleters.length} in-flight method call(s): $reason',
    );
    var pending = Map<String, Completer<dynamic>>.from(_methodCompleters);
    _methodCompleters.clear();
    pending.forEach((id, completer) {
      if (!completer.isCompleted) {
        completer.completeError(MeteorConnectionError(reason));
      }
    });
  }

  void _cancelScheduledReconnect() {
    _scheduleReconnectTimer?.cancel();
    _scheduleReconnectTimer = null;
  }

  void _connect() async {
    if (_connectionStatus.status == DdpConnectionStatusValues.connected ||
        _connectionStatus.status == DdpConnectionStatusValues.connecting) {
      return;
    }
    _isTryToReconnect = true;
    _connectionStatus.status = DdpConnectionStatusValues.connecting;
    _connectionStatus.reason = null;
    _emitStatus();

    WebSocketChannel channel;
    try {
      channel = WebSocketChannel.connect(Uri.parse(url));
    } catch (err) {
      printDebug('Failed to create the websocket: $err');
      _handleConnectionLost('Failed to create the websocket: $err');
      return;
    }
    _socket = channel;

    // The sink reports failures on its `done` future. Without a handler these
    // escape as unhandled async errors and take the whole application down.
    unawaited(channel.sink.done.catchError((Object err) {
      printDebug('Websocket sink closed with an error: $err');
      return null;
    }));

    try {
      await channel.ready;
    } catch (err) {
      if (!identical(_socket, channel)) {
        // Superseded by a newer attempt (or an explicit disconnect).
        return;
      }
      printDebug('Websocket failed to connect: $err');
      _handleConnectionLost('Websocket failed to connect: $err');
      return;
    }

    if (!identical(_socket, channel)) {
      // The client moved on while we were connecting.
      channel.sink.close().catchError((Object err) => null);
      return;
    }

    _lastMessageReceivedAt = DateTime.now();
    _socketSubscription = channel.stream.listen(
      _onData,
      onDone: _onDone,
      onError: _onError,
      cancelOnError: true,
    );
    _sendMsgConnect();
  }

  void _scheduleReconnect() {
    if (_connectionStatus.status != DdpConnectionStatusValues.offline &&
        _connectionStatus.status != DdpConnectionStatusValues.failed) {
      return;
    }
    _connectionStatus.retryCount++;
    if (_connectionStatus.retryCount <= maxRetryCount) {
      _connectionStatus.connected = false;
      _connectionStatus.status = DdpConnectionStatusValues.waiting;
      _connectionStatus.retryTime = _retryIntervalFor(
        _connectionStatus.retryCount,
      );
      _emitStatus();
      printDebug('Retry to connect in ${_connectionStatus.retryTime}');

      _cancelScheduledReconnect();
      _scheduleReconnectTimer = Timer(_connectionStatus.retryTime, () {
        _scheduleReconnectTimer = null;
        printDebug('Retry to connect count: ${_connectionStatus.retryCount}');
        if (_isTryToReconnect) {
          _connect();
        }
      });
    } else {
      _connectionStatus.connected = false;
      _connectionStatus.status = DdpConnectionStatusValues.failed;
      _connectionStatus.reason = 'DDP. Reach max retry attempt';
      _emitStatus();
      _failAllPendingMethodCalls('DDP. Reach max retry attempt');
    }
  }

  /// Back off linearly (0s, 5s, 10s, ...) up to [maxRetryInterval] so a device
  /// that wakes without a network does not spin on the radio.
  Duration _retryIntervalFor(int retryCount) {
    var seconds = 5 * (retryCount - 1);
    return Duration(
      seconds: min(seconds, maxRetryInterval.inSeconds),
    );
  }

  void _sendMsgConnect() {
    if (_socket != null) {
      var data = {
        'msg': 'connect',
        'version': '1',
        'support': ['1', 'pre1', 'pre2'],
      };
      if (sessionId != null) {
        // Ask to resume. The server only does so if it still has the session
        // and its sent count equals our received count; otherwise it starts
        // a new session. Servers without resumption support ignore both.
        data['session'] = sessionId!;
        data['receivedCount'] = _receivedCount;
      }
      var msg = json.encode(data);
      printDebug('Send: $msg');
      _socket!.sink.add(msg);
    }
  }

  void _sendMsgDisconnect() {
    var socket = _socket;
    if (socket != null && _connectionStatus.connected) {
      var msg = json.encode({'msg': 'disconnect'});
      printDebug('Send: $msg');
      try {
        socket.sink.add(msg);
      } catch (err) {
        printDebug('Failed to send disconnect: $err');
      }
    }
  }

  /// Re-send every live subscription on a freshly established connection.
  /// Called only once the server has replied `connected` and the reconnect
  /// callbacks (in practice, the login resume) have finished.
  void _resendSubscriptions() {
    _subscriptionHandlers.forEach((id, handler) {
      _sendMsgSub(id, handler.subName, handler.args);
    });
  }

  void _sendMsgPing() {
    if (_socket != null) {
      var msg = json.encode({'msg': 'ping'});
      printDebug('Send: $msg');
      _socket!.sink.add(msg);
      var sentTime = DateTime.now();
      // Start the clock on the first unanswered ping only. Restarting it per
      // ping would forgive a missed pong forever whenever pongTimeout is not
      // shorter than pingInterval; the timer is cleared when a pong arrives.
      _pongTimeoutTimer ??= Timer(pongTimeout, () {
        _pongTimeoutTimer = null;
        printDebug('Disconnect due to not receiving PONG');
        printDebug('The latest PING was sent since $sentTime');
        printDebug(
          'Time diff since the PING was sent is ${DateTime.now().difference(sentTime)}',
        );
        _handleConnectionLost('No PONG received within $pongTimeout');
      });
    }
  }

  void _sendMsgPong() {
    if (_socket != null) {
      var msg = json.encode({'msg': 'pong'});
      printDebug('Send: $msg');
      _socket!.sink.add(msg);
    }
  }

  void _sendMsgSub(String id, String name, List<dynamic> params) {
    if (_socket != null) {
      var data = {
        'msg': 'sub',
        'name': name,
        'params': params,
        'id': id,
      };
      var msg = json.encode(data);
      printDebug('Send: $msg');
      _socket!.sink.add(msg);
    }
  }

  void _sendMsgUnsub(String id) {
    if (_socket != null) {
      var data = {
        'msg': 'unsub',
        'id': id,
      };
      var msg = json.encode(data);
      printDebug('Send: $msg');
      _socket!.sink.add(msg);
    }
  }

  void _sendMsgMethod(String method, List<dynamic> params, String id,
      {Map<String, dynamic>? randomSeed}) {
    if (_socket != null) {
      var data = {
        'msg': 'method',
        'method': method,
        'params': params,
        'id': id,
      };
      if (randomSeed != null) {
        data['randomSeed'] = randomSeed;
      }
      var msg = json.encode(data);
      printDebug('Send: $msg');
      _socket!.sink.add(msg);
    }
  }

  /// Runs once the server accepted the connection.
  ///
  /// If the server handed back the session id we asked to resume, the session
  /// continues where it left off: the login, subscriptions and any in-flight
  /// method calls are still live on the server, so nothing is re-sent.
  /// Otherwise this is a new session: mark the client connected, give the
  /// reconnect callbacks a chance to restore the login, then re-send the
  /// subscriptions.
  Future<void> _onConnected(Map<String, dynamic> dataMap) async {
    var newSessionId = dataMap['session'];
    var resumed = sessionId != null && newSessionId == sessionId;
    _lastConnectResumedSession = resumed;
    sessionId = newSessionId;

    _connectionStatus.connected = true;
    _connectionStatus.status = DdpConnectionStatusValues.connected;
    _connectionStatus.reason = null;
    _connectionStatus.retryCount = 0;
    _connectionStatus.retryTime = Duration(seconds: 0);
    _emitStatus();

    _pingPeriodicTimer?.cancel();
    _pingPeriodicTimer = Timer.periodic(pingInterval, (timer) {
      if (_appIsPaused) {
        // Timers are unreliable while suspended; liveness is re-checked on
        // resume instead of tearing the connection down from a late timer.
        return;
      }
      _sendMsgPing();
    });

    if (resumed) {
      printDebug('Resumed DDP session $sessionId');
      return;
    }

    // New session: the 'connected' message itself is the first counted
    // message, and anything that was in flight on the old session is gone.
    _receivedCount = 1;
    _failAllPendingMethodCalls(
        'Connection was re-established as a new session');

    var callbacks = List<OnReconnectionCallback>.from(
      _onReconnectCallbacks.values,
    );
    for (var reconnectCallback in callbacks) {
      try {
        await reconnectCallback.callback(reconnectCallback);
      } catch (err) {
        printDebug('onReconnect callback failed: $err');
      }
      if (_connectionStatus.status != DdpConnectionStatusValues.connected) {
        // Lost the connection again while restoring it.
        return;
      }
    }
    _resendSubscriptions();
  }

  void _onData(dynamic data) {
    printDebug('Received: $data');
    _lastMessageReceivedAt = DateTime.now();
    var dataMap = json.decode(data) ?? {};
    var msg = dataMap['msg'];
    if (msg == 'ping') {
      // Answer regardless of state so the server never times us out.
      _sendMsgPong();
      return;
    }
    if (msg == 'pong') {
      _pongTimeoutTimer?.cancel();
      _pongTimeoutTimer = null;
      return;
    }
    if (msg != null) {
      // Mirrors the server's sentCount: every real DDP message counts, the
      // pre-session `server_id` frame (no `msg` field) and ping/pong do not.
      _receivedCount++;
    }
    if (_connectionStatus.status == DdpConnectionStatusValues.connecting) {
      if (dataMap['server_id'] != null) {
        serverId = dataMap['server_id'];
        if (debug) {
          print('DDP[${_socket.hashCode}] - Server ID: $serverId');
        }
      } else if (msg == 'connected') {
        unawaited(_onConnected(dataMap));
      } else if (msg == 'failed') {
        serverId = null;
        _forgetSession();
        _connectionStatus.connected = false;
        _connectionStatus.status = DdpConnectionStatusValues.failed;
        _connectionStatus.reason =
            'Failed connect to server. Protocol version ${dataMap['version']} is suggested!';
        _emitStatus();
      }
    } else if (_connectionStatus.status ==
        DdpConnectionStatusValues.connected) {
      if (msg == 'nosub') {
        if (dataMap['id'] != null) {
          String id = dataMap['id'];
          var sub = _subscriptions[id];
          if (sub != null && sub.onStop != null) {
            sub.onStop!(dataMap['error']);
            _subscriptions.remove(id);
            sub = null;
          } else if (sub == null) {
            printDebug('Unknown "nosub" error!');
          }
          var handler = _subscriptionHandlers[id];
          if (handler != null) {
            _subscriptionHandlers.remove(id);
            handler = null;
          }
        }
      } else if (msg == 'added') {
        dataStreamController.sink.add(dataMap);
      } else if (msg == 'changed') {
        dataStreamController.sink.add(dataMap);
      } else if (msg == 'removed') {
        dataStreamController.sink.add(dataMap);
      } else if (msg == 'ready') {
        // subs: array of strings (ids passed to 'sub' which have sent their initial batch of data)
        List? subs = dataMap['subs'];
        if (subs != null) {
          for (var id in subs) {
            var sub = _subscriptions[id];
            if (sub != null && sub.onReady != null) {
              sub.onReady!();
            }
            var handler = _subscriptionHandlers[id];
            if (handler != null) {
              handler._readyStreamController.sink.add(true);
            }
          }
        }
      } else if (msg == 'addedBefore') {
      } else if (msg == 'movedBefore') {
      } else if (msg == 'result') {
        if (dataMap['id'] != null) {
          String id = dataMap['id'];
          var completer = _methodCompleters.remove(id);
          if (completer != null) {
            if (dataMap['error'] != null) {
              completer.completeError(dataMap['error']);
            } else {
              DdpClient.formatSpecialFieldValues(dataMap);
              var result = dataMap['result'];
              completer.complete(result);
            }
          } else {
            printDebug('No method completer found!');
          }
        }
      } else if (msg == 'updated') {
        List methodIds = dataMap['methods'];
        printDebug(methodIds.toString());
      }
    }
  }

  /// Escape a special value before sending it out to Meteor server
  /// ex.
  /// createdAt: DateTime Instance 2020-08-30 23:15:57.471
  /// become
  /// createdAt: {$date: 1598804210504}
  static dynamic escapeSpecialFieldValues(dynamic params) {
    if (params is DateTime) {
      return {
        '\$date': params.millisecondsSinceEpoch,
      };
    } else if (params is List) {
      return params.map((param) => escapeSpecialFieldValues(param)).toList();
    } else if (params is Map) {
      var newMap = <String, dynamic>{};
      params.forEach((key, value) {
        newMap[key] = escapeSpecialFieldValues(value);
      });
      return newMap;
    }
    return params;
  }

  /// Format a special value
  /// ex.
  /// createdAt: {$date: 1598804210504}
  /// become
  /// createdAt: DateTime Instance 2020-08-30 23:15:57.471
  static void formatSpecialFieldValues(
    dynamic object, {
    dynamic parent,
    dynamic field,
  }) {
    if (object is Map<dynamic, dynamic>) {
      object.forEach((k, v) {
        if (v is Map || v is List) {
          DdpClient.formatSpecialFieldValues(v, parent: object, field: k);
        } else if (k == '\$date') {
          if (parent != null && field != null) {
            parent[field] = DateTime.fromMillisecondsSinceEpoch(v);
          }
        }
      });
    } else if (object is List) {
      object.asMap().forEach((idx, subObject) {
        formatSpecialFieldValues(subObject, parent: object, field: idx);
      });
    }
  }

  void _onDone() {
    if (_isTryToReconnect) {
      _handleConnectionLost('The websocket was closed by the other side');
    } else {
      _teardownConnection('The websocket was closed', keepSession: false);
    }
  }

  void _onError(dynamic error) {
    if (_isTryToReconnect) {
      _handleConnectionLost('Websocket error: $error');
    } else {
      _teardownConnection('Websocket error: $error', keepSession: false);
    }
  }
}
