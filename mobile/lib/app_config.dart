import 'dart:io';

class AppConfig {
  static const String _override = String.fromEnvironment('API_BASE_URL');

  /// Priority: --dart-define=API_BASE_URL=... > platform default.
  /// Android physical device: use your PC's LAN IP.
  /// Other platforms: use localhost.
  static String get apiBaseUrl {
    if (_override.isNotEmpty) return _override;

    if (Platform.isAndroid) {
      return 'http://10.14.219.80:8000';
    }

    return 'http://127.0.0.1:8000';
  }
}
