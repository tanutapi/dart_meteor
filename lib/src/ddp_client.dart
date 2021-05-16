import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:math';

enum DdpConnectionStatusValues {
  connected,
  connecting,
  failed,
  waiting,
  offline
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
  final int PING_SEC_INTERVAL = 20;
  final int PONG_WITHIN_SEC = 5;
  final Random _random = Random.secure();

  final StreamController<DdpConnectionStatus> _statusStreamController =
      StreamController();
  StreamController<dynamic> dataStreamController = StreamController();
  late DdpConnectionStatus _connectionStatus;
  String url;
  WebSocket? _socket;
  int maxRetryCount;
  final Map<String, OnReconnectionCallback> _onReconnectCallbacks = {};
  String? _sessionId;
  int _currentMethodId = 0;
  bool _flagToBeResetAtPongMsg = false;
  Timer? _pingPeriodicTimer;
  final Map<String, Completer<dynamic>> _methodCompleters = {};
  final Map<String, SubscriptionCallback> _subscriptions = {};
  final Map<String, SubscriptionHandler> _subscriptionHandlers = {};
  bool _isTryToReconnect = true;
  Timer? _scheduleReconnectTimer;

  final bool debug;

  DdpClient({
    required this.url,
    this.maxRetryCount = 20,
    this.debug = false,
  }) {
    _connectionStatus = DdpConnectionStatus(
      connected: false,
      status: DdpConnectionStatusValues.waiting,
      retryCount: 0,
      retryTime: Duration(seconds: 0),
      reason: null,
    );
    _statusStreamController.sink.add(_connectionStatus);
    _connect();
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
  /// callback:
  /// The function to call. It will be called with a single argument, the connection object that is reconnecting.
  void onReconnect(
      void Function(OnReconnectionCallback reconnection) callback) {
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
    var id = name + '-' + _generateUID(16);
    _subscriptions[id] = SubscriptionCallback(onStop: onStop, onReady: onReady);
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
    _sendMsgMethod(method, params, newId);
    _currentMethodId++;
    _methodCompleters[newId] = methodCompleter;
    return methodCompleter.future;
  }

  Stream<DdpConnectionStatus> status() {
    return _statusStreamController.stream;
  }

  void reconnect() {
    printDebug('Reconnect: the connection status is ... $_connectionStatus');
    if (_connectionStatus.status != DdpConnectionStatusValues.connected &&
        _connectionStatus.status != DdpConnectionStatusValues.connecting) {
      if (_scheduleReconnectTimer != null) {
        if (_scheduleReconnectTimer!.isActive) {
          _scheduleReconnectTimer!.cancel();
          _scheduleReconnectTimer = null;
        }
      }
      _connect();
    }
  }

  void disconnect() {
    printDebug('Begin of disconnect()');
    _isTryToReconnect = false;
    if (_socket != null) {
      _socket!.close().then((value) {
        _socket = null;
      }).catchError((err) {
        printDebug(err);
        _socket = null;
      });
    }
    // Cancel ping-pong timer
    if (_pingPeriodicTimer != null) {
      _pingPeriodicTimer!.cancel();
      _pingPeriodicTimer = null;
    }

    // Reset ping-pong flag
    _flagToBeResetAtPongMsg = false;

    _sessionId = null;
    _connectionStatus.connected = false;
    _connectionStatus.status = DdpConnectionStatusValues.offline;
    _connectionStatus.retryCount = 0;
    _connectionStatus.reason = null;
    _statusStreamController.sink.add(_connectionStatus);
    printDebug('End of disconnect()');
  }

  void _connect() async {
    if (_connectionStatus.status != DdpConnectionStatusValues.connected &&
        _connectionStatus.status != DdpConnectionStatusValues.connecting) {
      _isTryToReconnect = true;
      _connectionStatus.status = DdpConnectionStatusValues.connecting;
      _connectionStatus.reason = null;
      _statusStreamController.sink.add(_connectionStatus);
      try {
        _socket = await WebSocket.connect(url).timeout(
          Duration(seconds: 5),
        );
        _connectionStatus.retryCount = 0;
        _connectionStatus.retryTime = Duration(seconds: 1);
        _socket!.listen(
          _onData,
          onDone: _onDone,
          onError: _onError,
          cancelOnError: true,
        );
      } catch (err) {
        print(err);
        _connectionStatus.status = DdpConnectionStatusValues.failed;
        _connectionStatus.reason = err.toString();
        _statusStreamController.sink.add(_connectionStatus);
        _socket = null;
        printDebug(
          'Schedule to reconnect due to websocket exception while trying to connect to the server!',
        );
        _scheduleReconnect();
      }
      ;
    }
  }

  void _scheduleReconnect() {
    if (_connectionStatus.status == DdpConnectionStatusValues.offline ||
        _connectionStatus.status == DdpConnectionStatusValues.failed) {
      _connectionStatus.retryCount++;
      if (_connectionStatus.retryCount <= maxRetryCount) {
        _connectionStatus.connected = false;
        _connectionStatus.status = DdpConnectionStatusValues.waiting;
        _connectionStatus.retryTime =
            Duration(seconds: min(5 * (_connectionStatus.retryCount - 1), 30));
        _connectionStatus.reason = null;
        _statusStreamController.sink.add(_connectionStatus);
        printDebug('Retry to connect in ${_connectionStatus.retryTime}');

        if (_scheduleReconnectTimer != null) {
          if (_scheduleReconnectTimer!.isActive) {
            _scheduleReconnectTimer!.cancel();
            _scheduleReconnectTimer = null;
          }
        }
        _scheduleReconnectTimer = Timer(_connectionStatus.retryTime, () {
          printDebug('Retry to connect count: ${_connectionStatus.retryCount}');
          _connect();
        });
      } else {
        _connectionStatus.connected = false;
        _connectionStatus.status = DdpConnectionStatusValues.failed;
        _connectionStatus.reason = 'DDP. Reach max retry attempt';
        _statusStreamController.sink.add(_connectionStatus);
      }
    }
  }

  void _sendMsgConnect() {
    if (_socket != null) {
      var data = {
        'msg': 'connect',
        'version': '1',
        'support': ['1'],
      };
      if (_sessionId != null) {
        data['session'] = _sessionId!;
      }
      var msg = json.encode(data);
      printDebug('Send: $msg');
      _socket!.add(msg);
    }
  }

  void _sendMsgPing() {
    if (_socket != null) {
      var msg = json.encode({'msg': 'ping'});
      printDebug('Send: $msg');
      _socket!.add(msg);
      var sentTime = DateTime.now();
      _flagToBeResetAtPongMsg = true;
      Future.delayed(Duration(seconds: PONG_WITHIN_SEC), () {
        if (_flagToBeResetAtPongMsg == true) {
          printDebug('');
          printDebug('Disconnect due to not receiving PONG');
          printDebug('The latest PING was sent since $sentTime');
          printDebug('The current time is ${DateTime.now()}');
          printDebug(
            'Time diff since the PING was sent is ${DateTime.now().difference(sentTime)}',
          );
          disconnect();
        }
      });
    }
  }

  void _sendMsgPong() {
    if (_socket != null) {
      var msg = json.encode({'msg': 'pong'});
      printDebug('Send: $msg');
      _socket!.add(msg);
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
      _socket!.add(msg);
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
      _socket!.add(msg);
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
      _socket!.add(msg);
    }
  }

  void _onData(dynamic data) {
    printDebug('Received: $data');
    var dataMap = json.decode(data) ?? {};
    var msg = dataMap['msg'];
    if (_connectionStatus.status == DdpConnectionStatusValues.connecting) {
      if (dataMap['server_id'] != null) {
        _sendMsgConnect();
      } else if (msg == 'connected') {
        _onReconnectCallbacks.values.forEach((reconnectCallback) {
          reconnectCallback.callback(reconnectCallback);
        });

        _connectionStatus.connected = true;
        _connectionStatus.status = DdpConnectionStatusValues.connected;
        _connectionStatus.reason = null;
        _statusStreamController.sink.add(_connectionStatus);
        _sessionId = dataMap['session'];

        // Cancel ping-pong timer
        if (_pingPeriodicTimer != null) {
          _pingPeriodicTimer!.cancel();
          _pingPeriodicTimer = null;
        }

        _pingPeriodicTimer =
            Timer.periodic(Duration(seconds: PING_SEC_INTERVAL), (timer) {
          _sendMsgPing();
        });
      } else if (msg == 'failed') {
        _sessionId = null;
        _connectionStatus.connected = false;
        _connectionStatus.status = DdpConnectionStatusValues.failed;
        _connectionStatus.reason =
            'Failed connect to server. Protocol version ${dataMap['version']} is suggested!';
        _statusStreamController.sink.add(_connectionStatus);
      }
    } else if (_connectionStatus.status ==
        DdpConnectionStatusValues.connected) {
      if (msg == 'ping') {
        _sendMsgPong();
      } else if (msg == 'pong') {
        _flagToBeResetAtPongMsg = false;
      } else if (msg == 'nosub') {
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
        List subs = dataMap['subs'];
        if (subs != null) {
          subs.forEach((id) {
            var sub = _subscriptions[id];
            if (sub != null && sub.onReady != null) {
              sub.onReady!();
            }
            var handler = _subscriptionHandlers[id];
            if (handler != null) {
              handler._readyStreamController.sink.add(true);
            }
          });
        }
      } else if (msg == 'addedBefore') {
      } else if (msg == 'movedBefore') {
      } else if (msg == 'result') {
        if (dataMap['id'] != null) {
          String id = dataMap['id'];
          var completer = _methodCompleters[id];
          if (completer != null) {
            if (dataMap['error'] != null) {
              completer.completeError(dataMap['error']);
            } else {
              completer.complete(dataMap['result']);
            }
            _methodCompleters.remove(id);
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

  void _onDone() {
    _socket = null;
    if (_isTryToReconnect) {
      printDebug(
        'Disconnect the socket due to "onDone" event on the websocket!',
      );
      disconnect();
      printDebug(
        'ScheduleReconnect due to "onDone" event on the websocket!',
      );
      _scheduleReconnect();
    } else {
      disconnect();
    }
  }

  void _onError(dynamic error) {
    _socket = null;
    if (_isTryToReconnect) {
      printDebug('Disconnect due to "onError" event on the websocket!');
      disconnect();
      printDebug('ScheduleReconnect due to "onError" event on the websocket!');
      _scheduleReconnect();
    } else {
      printDebug('Disconnect due to "onError" event on the websocket!');
      disconnect();
    }
  }
}
