import 'package:flutter/material.dart';
import 'package:dart_meteor/dart_meteor.dart';

MeteorClient meteor = MeteorClient.connect(url: 'https://yourdomain.com');
void main() => runApp(MyApp());

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _methodResult = '';

  void _callMethod() {
    meteor.call('helloMethod', []).then((result) {
      setState(() {
        _methodResult = result.toString();
      });
    }).catchError((err) {
      if (err is MeteorError) {
        setState(() {
          _methodResult = err.message;
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
                  if (snapshot.hasData) {
                    if (snapshot.data.status ==
                        DdpConnectionStatusValues.connected) {
                      return RaisedButton(
                        child: Text('Disconnect'),
                        onPressed: () {
                          meteor.disconnect();
                        },
                      );
                    }
                    return RaisedButton(
                      child: Text('Connect'),
                      onPressed: () {
                        meteor.reconnect();
                      },
                    );
                  }
                  return Container();
                },
              ),
              StreamBuilder<DdpConnectionStatus>(
                stream: meteor.status(),
                builder: (context, snapshot) {
                  if (snapshot.hasData) {
                    return Text('Meteor Status ${snapshot.data.toString()}');
                  }
                  return Text('Meteor Status: ---');
                },
              ),
              StreamBuilder(
                  stream: meteor.userId(),
                  builder: (context, snapshot) {
                    if (snapshot.hasData) {
                      return RaisedButton(
                        child: Text('Logout'),
                        onPressed: () {
                          meteor.logout();
                        },
                      );
                    }
                    return RaisedButton(
                      child: Text('Login'),
                      onPressed: () {
                        meteor.loginWithPassword(
                            'yourusername', 'yourpassword');
                      },
                    );
                  }),
              StreamBuilder(
                stream: meteor.user(),
                builder: (context, snapshot) {
                  if (snapshot.hasData) {
                    return Text(snapshot.data.toString());
                  }
                  return Text('User: ----');
                },
              ),
              RaisedButton(
                child: Text('Method Call'),
                onPressed: _callMethod,
              ),
              Text(_methodResult),
            ],
          ),
        ),
      ),
    );
  }
}
