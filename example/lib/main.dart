import 'package:flutter/material.dart';
import 'package:dart_meteor/dart_meteor.dart';

MeteorClient meteor = MeteorClient.connect(url: 'ws://192.168.1.37:3000');
void main() => runApp(MyApp());

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  MyAppState createState() => MyAppState();
}

class MyAppState extends State<MyApp> {
  String _methodResult = '';

  void _callMethod() {
    meteor.call('helloMethod').then((result) {
      setState(() {
        _methodResult = result.toString();
      });
    }).catchError((err) {
      if (err is MeteorError) {
        setState(() {
          _methodResult = err.message ?? 'Unknown error';
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: Text('Package dart_meteor Example'),
        ),
        body: Container(
          padding: EdgeInsets.all(8.0),
          child: Column(
            children: <Widget>[
              StreamBuilder<DdpConnectionStatus>(
                stream: meteor.status(),
                builder: (context, snapshot) {
                  if (snapshot.hasData && snapshot.data != null) {
                    if (snapshot.data!.status ==
                        DdpConnectionStatusValues.connected) {
                      return ElevatedButton(
                        onPressed: () {
                          meteor.disconnect();
                        },
                        child: Text('Disconnect'),
                      );
                    }
                    return ElevatedButton(
                      onPressed: () {
                        meteor.reconnect();
                      },
                      child: Text('Connect'),
                    );
                  }
                  return Container();
                },
              ),
              StreamBuilder<DdpConnectionStatus>(
                stream: meteor.status(),
                builder: (context, snapshot) {
                  if (snapshot.hasData && snapshot.data != null) {
                    return Text('Meteor Status ${snapshot.data!.toString()}');
                  }
                  return Text('Meteor Status: ---');
                },
              ),
              StreamBuilder(
                  stream: meteor.userId(),
                  builder: (context, snapshot) {
                    if (snapshot.hasData && snapshot.data != null) {
                      return ElevatedButton(
                        onPressed: () {
                          meteor.logout();
                        },
                        child: Text('Logout'),
                      );
                    }
                    return ElevatedButton(
                      onPressed: () {
                        debugPrint('Logging in...');
                        meteor.loginWithPassword('user1', 'password1').then((res) {
                          debugPrint(res.token);
                        });
                      },
                      child: Text('Login'),
                    );
                  }),
              StreamBuilder(
                stream: meteor.user(),
                builder: (context, snapshot) {
                  if (snapshot.hasData && snapshot.data != null) {
                    return Text(snapshot.data.toString());
                  }
                  return Text('User: ----');
                },
              ),
              ElevatedButton(
                onPressed: _callMethod,
                child: Text('Method Call'),
              ),
              Text(_methodResult),
            ],
          ),
        ),
      ),
    );
  }
}
