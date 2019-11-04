# dart_meteor_example_app

An example flutter project that use dart_meteor package.

## Getting Started

Make a change in lib/main.dart to point to your meteor backend. You can use both http://, https://, ws:// or wsss://.
```dart
import 'package:flutter/material.dart';
import 'package:dart_meteor/dart_meteor.dart';

MeteorClient meteor = MeteorClient.connect(url: 'https://yourdomain.com');
void main() => runApp(MyApp());
```

Run flutter create in this example folder:
```
flutter create .
```

Run pub get in this example folder:
```
flutter pub get
```

Open Android emulator or iOS simulator then run the flutter:
```
flutter run
```
