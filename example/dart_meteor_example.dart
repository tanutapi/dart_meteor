import 'package:dart_meteor/dart_meteor.dart';

main() async {
  MeteorClient meteor = MeteorClient.connect(url: 'https://yourdomain.com');

  meteor.startup(() async {
    try {
      await meteor.loginWithPassword('yourusername', 'yourpassword');
    } catch (err) {
      print(err);
    }
  });

  meteor.user().listen((user) {
    print('User: $user');
  });

  meteor.users.listen((data) {
    print(data);
  });

  meteor.status().listen((status) {
    if (!status.connected) {
      Future.delayed(Duration(seconds: 5), () {
        meteor.reconnect();
      });
    }
  });
}
