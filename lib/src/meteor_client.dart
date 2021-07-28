import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:rxdart/rxdart.dart';
import 'ddp_client.dart';

class MeteorClientLoginResult {
  String userId;
  String token;
  DateTime tokenExpires;
  MeteorClientLoginResult({
    required this.userId,
    required this.token,
    required this.tokenExpires,
  });
}

class MeteorError extends Error {
  String? details;
  dynamic error;
  String? errorType;
  bool isClientSafe = true;
  String? message;
  String? reason;
  String? stack;

  MeteorError.parse(Map<String, dynamic> object) {
    try {
      details = object['details']?.toString();
      error = object['error'] is String
          ? int.tryParse(object['error']) ?? object['error']
          : object['error'];
      errorType = object['errorType']?.toString();
      isClientSafe = object['isClientSafe'] == true;
      message = object['message']?.toString();
      reason = object['reason']?.toString();
      stack = object['stack']?.toString();
    } catch (_) {}
  }

  @override
  String toString() {
    return '''
isClientSafe: $isClientSafe
errorType: $errorType
error: $error
details: $details
message: $message
reason: $reason
stack: $stack
''';
  }
}

enum UserLogInStatus {
  loggedOut,
  loggedIn,
  loggingIn,
  loggingOut,
}

class MeteorClient {
  late DdpClient connection;

  final BehaviorSubject<DdpConnectionStatus> _statusSubject = BehaviorSubject();
  late Stream<DdpConnectionStatus> _statusStream;

  final BehaviorSubject<UserLogInStatus> _logInStatusSubject =
      BehaviorSubject.seeded(UserLogInStatus.loggedOut);
  late Stream<UserLogInStatus> _logInStatusStream;

  final BehaviorSubject<bool> _loggingInSubject = BehaviorSubject();
  late Stream<bool> _loggingInStream;

  final BehaviorSubject<String?> _userIdSubject = BehaviorSubject();
  late Stream<String?> _userIdStream;

  final BehaviorSubject<Map<String, dynamic>> _userSubject = BehaviorSubject();
  late Stream<Map<String, dynamic>> _userStream;

  String? _userId;
  String? _token;
  DateTime? _tokenExpires;
  UserLogInStatus _logInStatus = UserLogInStatus.loggedOut;

  final Map<String, SubscriptionHandler> _subscriptions = {};

  /// Meteor.collections
  final Map<String, Map<String, dynamic>> _collections = {};
  final Map<String, BehaviorSubject<Map<String, dynamic>>> _collectionsSubject =
      {};
  final Map<String, Stream<Map<String, dynamic>>> _collectionsStreams = {};

  MeteorClient.connect({required String url, bool debug = false}) {
    url = url.replaceFirst(RegExp(r'^http'), 'ws');
    if (!url.endsWith('websocket')) {
      url = url.replaceFirst(RegExp(r'/$'), '') + '/websocket';
    }
    print('MeteorClient[$hashCode] - Make a connection to $url');
    connection = DdpClient(url: url, debug: debug);

    connection.status().listen((ddpStatus) {
      _statusSubject.add(ddpStatus);
    })
      ..onError((dynamic error) {
        _statusSubject.addError(error);
      })
      ..onDone(() {
        _statusSubject.close();
      });
    _statusStream = _statusSubject.stream;

    _loggingInStream = _loggingInSubject.stream;
    _logInStatusStream = _logInStatusSubject.stream;
    _logInStatusStream.listen((event) {
      _loggingInSubject.add(event == UserLogInStatus.loggingIn);
    });
    _userIdStream = _userIdSubject.stream;
    _userStream = _userSubject.stream;

    _prepareCollection('users');

    connection.dataStreamController.stream.listen((data) {
      String collectionName = data['collection'];
      String id = data['id'];
      dynamic fields = data['fields'];
      if (fields != null) {
        fields['_id'] = id;
        DdpClient.formatSpecialFieldValues(fields);
      }

      _prepareCollection(collectionName);

      if (data['msg'] == 'removed') {
        _collections[collectionName]!.remove(id);
      } else if (data['msg'] == 'added') {
        if (fields != null) {
          _collections[collectionName]![id] = fields;
        }
      } else if (data['msg'] == 'changed') {
        if (fields != null) {
          if (_collections[collectionName]![id] != null &&
              _collections[collectionName]![id] is Map) {
            fields.forEach((k, v) {
              _collections[collectionName]![id][k] = v;
            });
          }
        } else if (data['cleared'] != null && data['cleared'] is List) {
          List<dynamic> clearList = data['cleared'];
          if (_collections[collectionName]![id] != null &&
              _collections[collectionName]![id] is Map) {
            clearList.forEach((k) {
              _collections[collectionName]![id].remove(k);
            });
          }
        }
      }

      _collectionsSubject[collectionName]!.add(_collections[collectionName]!);
      if (collectionName == 'users' && id == _userId) {
        if (_collections['users'] != null &&
            _collections['users']![_userId] != null) {
          _userSubject.add(_collections['users']![_userId]);
        }
      }
    })
      ..onError((dynamic error) {})
      ..onDone(() {});

    connection.onReconnect((OnReconnectionCallback reconnectionCallback) {
      print('MeteorClient[$hashCode] - connection.onReconnect()');
      _loginWithExistingToken().catchError((error) {});
    });

    _statusStream.listen((ddpStatus) {
      if (ddpStatus.status == DdpConnectionStatusValues.connected &&
          !isAlreadyRunStartupFunctions) {
        isAlreadyRunStartupFunctions = true;
        _startupFunctions.forEach((func) {
          try {
            func();
          } catch (e) {
            rethrow;
          }
        });
      }
    });

    userId().listen((userId) {
      if (_collections['users'] != null &&
          _collections['users']![userId] != null) {
        _userSubject.add(_collections['users']![userId]);
      }
    });
  }

  void _prepareCollection(String collectionName) {
    if (_collections[collectionName] == null) {
      _collections[collectionName] = {};
      var subject = _collectionsSubject[collectionName] =
          BehaviorSubject<Map<String, dynamic>>();
      _collectionsStreams[collectionName] = subject.stream;
    }
  }

  /// Get [Stream] of `collection` on given a `collectionName`.
  Stream<Map<String, dynamic>> collection(String collectionName) {
    if (_collections[collectionName] == null) {
      _prepareCollection(collectionName);
    }
    return _collectionsStreams[collectionName]!;
  }

  Map<String, dynamic>? collectionCurrentValue(String collectionName) {
    if (_collections[collectionName] == null) {
      _prepareCollection(collectionName);
    }
    return _collectionsSubject[collectionName]!.value;
  }

  // ===========================================================
  // Core

  /// Boolean variable. True if running in client environment.
  bool isClient() {
    return true;
  }

  /// Boolean variable. True if running in server environment.
  bool isServer() {
    return false;
  }

  /// Boolean variable. True if running in a Cordova mobile environment.
  bool isCordova() {
    return false;
  }

  /// Boolean variable. True if running in development environment.
  bool isDevelopment() {
    return !bool.fromEnvironment('dart.vm.product');
  }

  /// Boolean variable. True if running in production environment.
  bool isProduction() {
    return bool.fromEnvironment('dart.vm.product');
  }

  bool isAlreadyRunStartupFunctions = false;
  final List<Function> _startupFunctions = [];

  /// Run code when a client successfully make a connection to server.
  void startup(Function func) {
    _startupFunctions.add(func);
  }

  // Meteor.wrapAsync(func, [context])

  void defer(Function Function() func) {
    Future.delayed(Duration(seconds: 0), func);
  }

  // Meteor.absoluteUrl([path], [options])

  // Meteor.settings

  // Meteor.release

  // ===========================================================
  // Publish and subscribe

  /// Subscribe to a record set. Returns a SubscriptionHandler that provides stop() and ready() methods.
  ///
  /// `name`
  /// Name of the subscription. Matches the name of the server's publish() call.
  ///
  /// `args`
  /// Arguments passed to publisher function on server.
  SubscriptionHandler subscribe(String name,
      {List<dynamic> args = const [],
      Function Function(dynamic error)? onStop,
      Function? onReady}) {
    var handler =
        connection.subscribe(name, args, onStop: onStop, onReady: onReady);
    _subscriptions[handler.subId] = handler;
    return handler;
  }

  // ===========================================================
  // Methods

  /// Invoke a method passing an array of arguments.
  ///
  /// `name` Name of method to invoke
  ///
  /// `args` List of method arguments
  Future<dynamic> call(String name, {List<dynamic> args = const []}) async {
    try {
      return await connection.call(name, args);
    } catch (e) {
      if (e is Map<String, dynamic>) {
        throw MeteorError.parse(e);
      }
      rethrow;
    }
  }

  /// Invoke a method passing an array of arguments.
  ///
  /// `name` Name of method to invoke
  ///
  /// `args` List of method arguments
  Future<dynamic> apply(String name, List<dynamic> args) async {
    try {
      return await connection.apply(name, args);
    } catch (e) {
      if (e is Map<String, dynamic>) {
        throw MeteorError.parse(e);
      }
      rethrow;
    }
  }

  // ===========================================================
  // Server Connections

  /// Get the current connection status.
  Stream<DdpConnectionStatus> status() {
    return _statusStream;
  }

  /// Force an immediate reconnection attempt if the client is not connected to the server.
  /// This method does nothing if the client is already connected.
  void reconnect() {
    connection.reconnect();
  }

  /// Disconnect the client from the server.
  void disconnect() {
    connection.disconnect();
  }

  // ===========================================================
  // Accounts

  /// Get the current user record, or null if no user is logged in. A reactive data source.
  Stream<Map<String, dynamic>> user() {
    return _userStream;
  }

  Map<String, dynamic> userCurrentValue() {
    return _userSubject.value;
  }

  /// Get the current user id, or null if no user is logged in. A reactive data source.
  Stream<String?> userId() {
    return _userIdStream;
  }

  String? userIdCurrentValue() {
    return _userIdSubject.value;
  }

  /// A Map containing user documents.
  Stream<Map<String, dynamic>> get users => _collectionsStreams['users']!;

  /// Current log-in status of login methods (such as Meteor.loginWithPassword, Meteor.loginWithFacebook, or Accounts.createUser).
  /// A reactive data source.
  Stream<UserLogInStatus> logInStatus() {
    return _logInStatusStream;
  }

  /// True if a login method (such as Meteor.loginWithPassword, Meteor.loginWithFacebook, or Accounts.createUser) is currently in progress.
  /// A reactive data source.
  Stream<bool> loggingIn() {
    return _loggingInStream;
  }

  /// Log the user out.
  Future logout() {
    _logInStatus = UserLogInStatus.loggingOut;
    var completer = Completer();
    call('logout').then((result) {
      _userId = null;
      _token = null;
      _tokenExpires = null;
      _logInStatus = UserLogInStatus.loggedOut;
      _logInStatusSubject.add(_logInStatus);
      _userIdSubject.add(_userId);
      completer.complete();
    }).catchError((error) {
      _userId = null;
      _token = null;
      _tokenExpires = null;
      _logInStatus = UserLogInStatus.loggedOut;
      _logInStatusSubject.add(_logInStatus);
      _userIdSubject.add(_userId);
      connection.disconnect();
      Future.delayed(Duration(seconds: 2), () {
        connection.reconnect();
      });
      completer.completeError(error);
    });
    return completer.future;
  }

  /// Log out other clients logged in as the current user, but does not log out the client that calls this function.
  Future logoutOtherClients() {
    var completer = Completer();
    _logInStatus = UserLogInStatus.loggingIn;
    call('getNewToken').then((result) {
      _userId = result['id'];
      _token = result['token'];
      _tokenExpires = result['tokenExpires'];
      _logInStatus = UserLogInStatus.loggedIn;
      _logInStatusSubject.add(_logInStatus);
      _userIdSubject.add(_userId);
      call('removeOtherTokens').then((value) {
        completer.complete();
      });
    }).catchError((error) {
      _logInStatus = UserLogInStatus.loggedOut;
      completer.completeError(error);
    });
    return completer.future;
  }

  /// Log the user in with a password.
  ///
  /// [user]
  /// Either a string interpreted as a username or an email;
  /// or an object with a single key: email, username or id.
  /// Username or email match in a case insensitive manner.
  ///
  /// [password] password
  ///
  /// [delayOnLoginErrorSecond]
  /// If login errors, delay for specificed second before throw an error.
  /// The user's password.
  Future<MeteorClientLoginResult> loginWithPassword(
      String user, String password,
      {int delayOnLoginErrorSecond = 0}) {
    var completer = Completer<MeteorClientLoginResult>();
    _logInStatus = UserLogInStatus.loggingIn;
    _logInStatusSubject.add(_logInStatus);

    var selector;
    if (!user.contains('@')) {
      selector = {'username': user};
    } else {
      selector = {'email': user};
    }

    call('login', args: [
      {
        'user': selector,
        'password': {
          'digest': sha256.convert(utf8.encode(password)).toString(),
          'algorithm': 'sha-256'
        },
      }
    ]).then((result) {
      _userId = result['id'];
      _token = result['token'];
      _tokenExpires = result['tokenExpires'];
      _logInStatus = UserLogInStatus.loggedIn;
      _logInStatusSubject.add(_logInStatus);
      _userIdSubject.add(_userId!);
      completer.complete(MeteorClientLoginResult(
        userId: _userId!,
        token: _token!,
        tokenExpires: _tokenExpires!,
      ));
    }).catchError((error) {
      Future.delayed(Duration(seconds: delayOnLoginErrorSecond), () {
        _userId = null;
        _token = null;
        _tokenExpires = null;
        _logInStatus = UserLogInStatus.loggedOut;
        _logInStatusSubject.add(_logInStatus);
        _userIdSubject.add(_userId);
        completer.completeError(error);
      });
    });
    return completer.future;
  }

  Future<MeteorClientLoginResult?> loginWithToken({
    required String token,
    DateTime? tokenExpires,
  }) {
    _token = token;
    if (tokenExpires == null) {
      _tokenExpires = DateTime.now().add(Duration(hours: 1));
    } else {
      _tokenExpires = tokenExpires;
    }
    return _loginWithExistingToken();
  }

  Future<MeteorClientLoginResult?> _loginWithExistingToken() {
    var completer = Completer<MeteorClientLoginResult?>();
    print('MeteorClient[$hashCode] - Trying to login with existing token...');
    if (_tokenExpires != null) {
      print(
          'MeteorClient[$hashCode] - Token expires ${_tokenExpires!.toString()}');
      print('MeteorClient[$hashCode] - Current time is ${DateTime.now()}');
      print(
        'MeteorClient[$hashCode] - Token expires is after now ${_tokenExpires!.isAfter(DateTime.now())}',
      );
    }

    if (_token != null &&
        _tokenExpires != null &&
        _tokenExpires!.isAfter(DateTime.now())) {
      _logInStatus = UserLogInStatus.loggingIn;
      _logInStatusSubject.add(_logInStatus);
      call('login', args: [
        {'resume': _token}
      ]).then((result) {
        _userId = result['id'];
        _token = result['token'];
        _tokenExpires = result['tokenExpires'];
        _logInStatus = UserLogInStatus.loggedIn;
        _logInStatusSubject.add(_logInStatus);
        _userIdSubject.add(_userId!);
        completer.complete(MeteorClientLoginResult(
          userId: _userId!,
          token: _token!,
          tokenExpires: _tokenExpires!,
        ));
      }).catchError((error) {
        _userId = null;
        _token = null;
        _tokenExpires = null;
        _logInStatus = UserLogInStatus.loggedOut;
        _logInStatusSubject.add(_logInStatus);
        _userIdSubject.add(_userId);
        completer.completeError(error);
      });
    } else {
      completer.complete(null);
    }
    return completer.future;
  }

  // ===========================================================
  // Passwords

  /// Change the current user's password. Must be logged in.
  Future<dynamic> changePassword(String oldPassword, String newPassword) {
    return call('changePassword', args: [oldPassword, newPassword]);
  }

  /// Request a forgot password email.
  ///
  /// [email]
  /// The email address to send a password reset link.
  Future<dynamic> forgotPassword(String email) {
    return call('forgotPassword', args: [
      {'email': email}
    ]);
  }

  /// Reset the password for a user using a token received in email. Logs the user in afterwards.
  ///
  /// [token]
  /// The token retrieved from the reset password URL.
  ///
  /// [newPassword]
  /// A new password for the user. This is not sent in plain text over the wire.
  Future<dynamic> resetPassword(String token, String newPassword) {
    return call('resetPassword', args: [token, newPassword]);
  }
}
