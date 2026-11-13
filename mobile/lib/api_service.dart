import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';

class OtpResult {
  final String? token;
  final String? error;
  const OtpResult(this.token, this.error);
}

class _Res {
  final int status;
  final dynamic data;
  final String? netError; // set only when the server could not be reached
  const _Res(this.status, this.data, this.netError);
  bool get ok => netError == null && status >= 200 && status < 300;
}

/// What actually happened to an SOS. Only `smsAccepted` means the provider took it.
class SosResult {
  final int? alertId;
  final String
  deliveryStatus; // accepted | queued | failed | not_configured | no_contact
  final String? detail;
  final String? locationLink;
  final String? contactPhone;
  const SosResult({
    this.alertId,
    required this.deliveryStatus,
    this.detail,
    this.locationLink,
    this.contactPhone,
  });

  bool get smsAccepted => deliveryStatus == 'accepted';
  bool get queued => deliveryStatus == 'queued';

  factory SosResult.fromJson(Map<String, dynamic> j) => SosResult(
    alertId: (j['id'] as num?)?.toInt(),
    deliveryStatus: '${j['delivery_status'] ?? 'failed'}',
    detail: j['delivery_detail']?.toString(),
    locationLink: j['location_link']?.toString(),
    contactPhone: j['contact_phone']?.toString(),
  );
}

class ApiService {
  static final ApiService _instance = ApiService._();
  factory ApiService() => _instance;
  ApiService._();

  static const Duration _timeout = Duration(seconds: 15);
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _kToken = 'k2_access_token';
  static const String _kSosQueue = 'k2_sos_queue_v1';
  static const String _kWaterQueue = 'k2_water_queue_v1';

  static String? _token;
  static bool _tokenLoaded = false;

  /// Reason for the last failed login().
  static String? lastError;

  bool get hasToken => _token != null;

  // ---------- token ----------
  Future<void> _loadToken() async {
    if (_tokenLoaded) return;
    try {
      _token = await _storage.read(key: _kToken);
    } catch (_) {}
    _tokenLoaded = true;
  }

  Future<void> _saveToken(String? t) async {
    _token = t;
    _tokenLoaded = true;
    try {
      if (t == null) {
        await _storage.delete(key: _kToken);
      } else {
        await _storage.write(key: _kToken, value: t);
      }
    } catch (_) {}
  }

  Future<void> logout() => _saveToken(null);

  Future<bool> hasSavedToken() async {
    await _loadToken();
    return _token != null;
  }

  // ---------- http ----------
  static String _unreachable(String why) =>
      'Cannot reach the K2 server at ${AppConfig.apiBaseUrl} ($why).';

  Future<_Res> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool auth = true,
    Duration? timeout,
  }) async {
    await _loadToken();
    final req = http.Request(method, Uri.parse('${AppConfig.apiBaseUrl}$path'))
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'application/json';
    if (auth && _token != null) req.headers['Authorization'] = 'Bearer $_token';
    if (body != null) req.body = jsonEncode(body);
    try {
      final streamed = await req.send().timeout(timeout ?? _timeout);
      final res = await http.Response.fromStream(streamed);
      dynamic data;
      if (res.bodyBytes.isNotEmpty) {
        try {
          data = jsonDecode(utf8.decode(res.bodyBytes));
        } catch (_) {}
      }
      return _Res(res.statusCode, data, null);
    } on TimeoutException {
      return _Res(0, null, _unreachable('timed out'));
    } on SocketException catch (e) {
      return _Res(0, null, _unreachable(e.message));
    } on http.ClientException catch (e) {
      return _Res(0, null, _unreachable(e.message));
    } catch (e) {
      return _Res(0, null, _unreachable('$e'));
    }
  }

  static String? _detail(dynamic data) {
    if (data is Map && data['detail'] != null) {
      final d = data['detail'];
      if (d is String) return d;
      if (d is List && d.isNotEmpty) {
        return d
            .map((e) {
              if (e is Map) {
                final loc =
                    (e['loc'] as List?)?.where((x) => x != 'body').join('.') ??
                    '';
                return loc.isEmpty ? '${e['msg']}' : '$loc: ${e['msg']}';
              }
              return '$e';
            })
            .join('; ');
      }
    }
    return null;
  }

  Future<List<Map<String, dynamic>>?> _getList(String path) async {
    final r = await _send('GET', path);
    if (!r.ok || r.data is! List) return null;
    return (r.data as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<Map<String, dynamic>?> _getMap(String path) async {
    final r = await _send('GET', path);
    return r.ok && r.data is Map
        ? Map<String, dynamic>.from(r.data as Map)
        : null;
  }

  // ---------- auth ----------
  Future<String?> requestOtp(String email) async {
    final r = await _send(
      'POST',
      '/auth/request-otp',
      auth: false,
      body: {'email': email},
    );
    if (r.netError != null) return r.netError;
    if (!r.ok) {
      return _detail(r.data) ?? 'Could not send the code (HTTP ${r.status}).';
    }
    return null;
  }

  Future<OtpResult> verifyOtp(String email, String code) async {
    final r = await _send(
      'POST',
      '/auth/verify-otp',
      auth: false,
      body: {'email': email, 'code': code},
    );
    if (r.netError != null) return OtpResult(null, r.netError);
    if (!r.ok || r.data is! Map) {
      return OtpResult(
        null,
        _detail(r.data) ?? 'Verification failed (HTTP ${r.status}).',
      );
    }
    return OtpResult('${(r.data as Map)['signup_token']}', null);
  }

  /// Returns null on success, otherwise an error message.
  Future<String?> register({
    required String signupToken,
    required String password,
    required String fullName,
    required String phoneNumber,
    required int heightCm,
    required int weightKg,
    required String bloodGroup,
    String allergies = '',
    String medicalConditions = '',
  }) async {
    final r = await _send(
      'POST',
      '/auth/register',
      auth: false,
      body: {
        'signup_token': signupToken,
        'password': password,
        'full_name': fullName,
        'phone_number': phoneNumber,
        'height_cm': heightCm,
        'weight_kg': weightKg,
        'blood_group': bloodGroup,
        'allergies': allergies,
        'medical_conditions': medicalConditions,
      },
    );
    if (r.netError != null) return r.netError;
    if (!r.ok) {
      return _detail(r.data) ?? 'Registration failed (HTTP ${r.status}).';
    }
    return null;
  }

  Future<bool> login(String email, String password) async {
    lastError = null;
    final r = await _send(
      'POST',
      '/auth/login',
      auth: false,
      body: {'email': email, 'password': password},
    );
    if (r.netError != null) {
      lastError = r.netError;
      return false;
    }
    if (!r.ok) {
      lastError = _detail(r.data) ?? 'Login failed (HTTP ${r.status}).';
      return false;
    }
    final t = r.data is Map
        ? (r.data as Map)['access_token']?.toString()
        : null;
    if (t == null) {
      lastError = 'Server returned no token.';
      return false;
    }
    await _saveToken(t);
    return true;
  }

  Future<Map<String, dynamic>?> getMe() async {
    final r = await _send('GET', '/users/me');
    if (r.status == 401) await _saveToken(null); // expired or invalid token
    return r.ok && r.data is Map
        ? Map<String, dynamic>.from(r.data as Map)
        : null;
  }

  // ---------- contacts ----------
  Future<List<Map<String, dynamic>>?> getContacts() => _getList('/contacts');

  /// Returns null on success, otherwise an error message.
  Future<String?> addContact(
    String name,
    String phone, {
    String relationship = 'Emergency',
  }) async {
    final r = await _send(
      'POST',
      '/contacts',
      body: {'name': name, 'phone_number': phone, 'relationship': relationship},
    );
    if (r.netError != null) return r.netError;
    if (!r.ok) {
      return _detail(r.data) ??
          'Could not save the contact (HTTP ${r.status}).';
    }
    return null;
  }

  Future<bool> makeContactPrimary(int id) async =>
      (await _send('POST', '/contacts/$id/primary')).ok;

  Future<bool> deleteContact(int id) async =>
      (await _send('DELETE', '/contacts/$id')).ok;

  // ---------- hydration ----------
  Future<bool> logWater(int ml) async =>
      (await _send('POST', '/hydration', body: {'amount_ml': ml})).ok;

  Future<Map<String, dynamic>?> getTodayHydration() {
    final off = DateTime.now().timeZoneOffset.inMinutes;
    return _getMap('/hydration/today?tz_offset_minutes=$off');
  }

  /// True when the server stored it. Otherwise queued with a client_id,
  /// so a retry can never double-count.
  Future<bool> logWaterQueued(int ml) async {
    final payload = <String, dynamic>{
      'amount_ml': ml,
      'client_id': _newRequestId(),
      'logged_at': DateTime.now().toUtc().toIso8601String(),
    };
    final r = await _send('POST', '/hydration', body: payload);
    if (r.ok) return true;
    if (r.netError != null || r.status >= 500) {
      final prefs = await SharedPreferences.getInstance();
      final q = prefs.getStringList(_kWaterQueue) ?? <String>[];
      q.add(jsonEncode(payload));
      await prefs.setStringList(_kWaterQueue, q);
    }
    return false;
  }

  Future<void> flushPendingWater() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kWaterQueue) ?? <String>[];
    if (raw.isEmpty) return;
    final remaining = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final r = await _send(
        'POST',
        '/hydration',
        body: Map<String, dynamic>.from(jsonDecode(raw[i]) as Map),
      );
      if (r.ok) continue;
      if (r.netError != null || r.status == 401 || r.status >= 500) {
        remaining.addAll(raw.sublist(i));
        break;
      } // other 4xx: invalid entry, drop it
    }
    await prefs.setStringList(_kWaterQueue, remaining);
  }

  // ---------- vitals ----------
  /// `source` defaults to 'simulated' so demo data is never stored as real.
  Future<bool> logVitals(
    int hr,
    int spo2, {
    String source = 'simulated',
  }) async => (await _send(
    'POST',
    '/vitals',
    body: {'heart_rate': hr, 'spo2': spo2, 'source': source},
  )).ok;

  Future<List<Map<String, dynamic>>?> getVitalsHistory() => _getList('/vitals');

  // ---------- treks ----------
  /// `points` rows are [lat, lon, alt|null, accuracy, epochMillis].
  Future<bool> createTrekWithDetails(
    String name,
    double km,
    double altM, {
    DateTime? start,
    DateTime? end,
    double gainM = 0,
    String status = 'completed',
    List<List<dynamic>> points = const [],
  }) async {
    var pts = points;
    if (pts.length > 1500) {
      final step = (pts.length / 1500).ceil();
      pts = [for (int i = 0; i < pts.length; i += step) pts[i]];
      if (pts.last != points.last) pts.add(points.last);
    }
    final r = await _send(
      'POST',
      '/treks',
      body: {
        'name': name,
        'status': status,
        'total_distance_km': km,
        'max_altitude_m': altM,
        'elevation_gain_m': gainM,
        if (start != null) 'start_date': start.toUtc().toIso8601String(),
        if (end != null) 'end_date': end.toUtc().toIso8601String(),
        'points': pts
            .map(
              (p) => {
                'lat': p[0],
                'lon': p[1],
                'alt': p[2],
                'accuracy': p[3],
                'recorded_at': DateTime.fromMillisecondsSinceEpoch(
                  p[4] as int,
                  isUtc: true,
                ).toIso8601String(),
              },
            )
            .toList(),
      },
    );
    return r.ok;
  }

  Future<List<Map<String, dynamic>>?> getMyTreks() => _getList('/treks');

  Future<Map<String, dynamic>?> getTrek(int id) => _getMap('/treks/$id');

  // ---------- SOS ----------
  static String _newRequestId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 31)}';

  /// If the server is unreachable the alert is queued (result.queued == true)
  /// and NOBODY HAS BEEN NOTIFIED. Show that to the user.
  Future<SosResult> sendSos({
    double? latitude,
    double? longitude,
    double? accuracyM,
    DateTime? locationTime,
    required String trigger, // 'manual' | 'auto'
  }) async {
    final payload = <String, dynamic>{
      'trigger': trigger,
      'client_request_id': _newRequestId(),
      'client_created_at': DateTime.now().toUtc().toIso8601String(),
      if (latitude != null && longitude != null) ...{
        'latitude': latitude,
        'longitude': longitude,
      },
      if (accuracyM != null) 'accuracy_m': accuracyM,
      if (locationTime != null)
        'location_time': locationTime.toUtc().toIso8601String(),
    };
    final r = await _send('POST', '/sos', body: payload);
    if (r.netError != null) {
      await _enqueueSos(payload);
      return const SosResult(
        deliveryStatus: 'queued',
        detail:
            'No connection to the server. Alert saved on this phone and not yet sent.',
      );
    }
    if (r.status == 401) {
      return const SosResult(
        deliveryStatus: 'failed',
        detail:
            'You are not signed in to the server, so the alert could not be sent.',
      );
    }
    if (!r.ok || r.data is! Map) {
      return SosResult(
        deliveryStatus: 'failed',
        detail: _detail(r.data) ?? 'Server error (HTTP ${r.status}).',
      );
    }
    return SosResult.fromJson(Map<String, dynamic>.from(r.data as Map));
  }

  Future<bool> cancelSos(int alertId) async =>
      (await _send('POST', '/sos/$alertId/cancel')).ok;

  Future<void> _enqueueSos(Map<String, dynamic> payload) async {
    final prefs = await SharedPreferences.getInstance();
    final q = prefs.getStringList(_kSosQueue) ?? <String>[];
    q.add(jsonEncode(payload));
    await prefs.setStringList(_kSosQueue, q);
  }

  Future<int> pendingSosCount() async =>
      ((await SharedPreferences.getInstance()).getStringList(_kSosQueue) ?? [])
          .length;

  /// Retries queued alerts (same request id, so the server never duplicates).
  Future<int> flushQueuedSos() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kSosQueue) ?? <String>[];
    if (raw.isEmpty) return 0;
    final remaining = <String>[];
    var sent = 0;
    for (var i = 0; i < raw.length; i++) {
      final r = await _send(
        'POST',
        '/sos',
        body: Map<String, dynamic>.from(jsonDecode(raw[i]) as Map),
      );
      if (r.ok) {
        sent++;
      } else if (r.netError != null || r.status == 401) {
        remaining.addAll(raw.sublist(i));
        break;
      } else if (r.status >= 500) {
        remaining.add(raw[i]);
      } // other 4xx: invalid payload, drop it
    }
    await prefs.setStringList(_kSosQueue, remaining);
    return sent;
  }

  // ---------- checklist ----------
  Future<List<String>?> getChecklist() async {
    final r = await _send('GET', '/checklist');
    if (!r.ok || r.data is! Map) return null;
    return ((r.data as Map)['checked'] as List).map((e) => '$e').toList();
  }

  Future<bool> putChecklist(List<String> checked) async =>
      (await _send('PUT', '/checklist', body: {'checked': checked})).ok;

  // ---------- camps ----------
  Future<Map<String, dynamic>?> getCamps() => _getMap('/camps');

  Future<bool> putCamps({
    required int reachedStage,
    required List<Map<String, dynamic>> waypoints,
    required List<Map<String, dynamic>> events,
  }) async => (await _send(
    'PUT',
    '/camps',
    body: {
      'reached_stage': reachedStage,
      'waypoints': waypoints,
      'events': events,
    },
  )).ok;

  // ---------- help stations ----------
  Future<List<Map<String, dynamic>>?> getHelpStations({
    double? lat,
    double? lon,
  }) => _getList(
    lat != null && lon != null
        ? '/help-stations?lat=$lat&lon=$lon'
        : '/help-stations',
  );

  // ---------- logout ----------
  /// Signs out and deletes everything on this phone that belongs to the user.
  Future<void> signOutAndClear() async {
    await _saveToken(null);
    final prefs = await SharedPreferences.getInstance();
    for (final k in [
      _kSosQueue,
      _kWaterQueue,
      'k2_checklist_checked_v1',
      'k2_checklist_dirty_v1',
      'k2_waypoints_v1',
      'k2_reached_stage_v1',
      'k2_camps_dirty_v1',
      'k2_camp_events_v1',
      'k2_trek_history_v1',
      'k2_active_trek_v1',
      'k2_vitals_readings_v1',
      'k2_profile_cache',
    ]) {
      await prefs.remove(k);
    }
  }
}
