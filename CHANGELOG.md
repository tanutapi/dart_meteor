# 4.0.0
- Support for the latest Dart/Flutter releases (tested with Dart 3.13). The minimum SDK is now Dart 3.6.
- Verified compatibility with Meteor 3.x servers, including Meteor 3.5.1 (DDP protocol version 1, SHA-256 password login, EJSON `$date` handling).
- Web platform support from the 4.0.0 betas via `web_socket_channel` is included.
- Added a standalone DDP protocol test suite (`test/ddp_mock_server_test.dart`) that runs without a Meteor server or docker.
- Updated dependencies and lint rules (`lints` 6).
- BREAKING: `DdpClient.PING_SEC_INTERVAL` and `DdpClient.PONG_WITHIN_SEC` were renamed to the static constants `DdpClient.pingIntervalSeconds` and `DdpClient.pongTimeoutSeconds`.

# 4.0.0-beta.1, 4.0.0-beta.2
- Adding Web platform support by using the `web_socket_channel`.

# 3.0.0
- BREAKING CHANGE. The `meteor.collection('collectionName')` streams are now `hasData == true` and have an empty map at the beginning.
# 2.1.4
- Acessing to serverId and sessionId
# 2.1.3
- Resend subscription packets on reconnection.
# 2.1.2
- Return MeteorClientLoginResult on logoutOtherClients.
# 2.1.1
- Return null if no current value presents for the 'currentValue'.
# 2.1.0
- Fix a major bug on escaping DateTime when doing method call and subscribe.
# 2.0.4
- Fix bug on meteor.user() does not set back to null after user has been logged out.
## 2.0.3
- Separated login function.

## 2.0.2
- Fix bugs on connecting to Meteor 2.x.x and on logout function.

## 2.0.1
- Fix a $date bug when parsing an array result from methods/collections.

## 2.0.0
- Null safety and some API changes.

## 1.1.2
- Lower crypto package version to match the flutter_test.

## 1.1.1
- Allows both int and String for MeteorError.error

## 1.1.0

- Pin rxdart to 0.24.1 and crypto to 2.1.5.

## 1.0.8

- Allow passing email to loginWithPassword.

## 1.0.7

- **Don't use this release**

## 1.0.5 - 1.0.6

- Pin rxdart version to 0.22.6

## 1.0.1 - 1.0.4

- Update README and example

## 1.0.0 - 1.0.3

- Initial version.
