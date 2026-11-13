import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:google_fonts/google_fonts.dart';
import 'database/database_helper.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as latlong;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'weather_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// The primary emergency contact's number. Set at login and updated from the SOS tab.
final ValueNotifier<String> primaryContactPhone = ValueNotifier<String>('');
const String _kProfileCache = 'k2_profile_cache';
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  await DatabaseHelper.instance.database;
  print("✅ SQLite Connected Successfully");

  runApp(const K2UiApp());
}

// ==========================================
// K2 EARTHY MOUNTAIN COLOR SYSTEM
// ==========================================
class AppColors {
  static const Color forest = Color(0xFF17221D);
  static const Color charcoal = Color(0xFF1B1C1A);
  static const Color stone = Color(0xFFD8D0C2);
  static const Color gold = Color(0xFFC79A32);
  static const Color snow = Color(0xFFF3F1EA);
  static const Color skyBlue = Color(0xFF5FA8C9);
  static const Color green = Colors.greenAccent;
  static const Color red = Colors.redAccent;
  static const Color darkOverlay = Color(0xAA11141A);

  static const Color cardDark = Color(0xFF121418);
  static const Color cardBorder = Color(0xFF2A2D34);
}

class K2UiApp extends StatelessWidget {
  const K2UiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'K2 Expedition Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.charcoal,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.gold,
          secondary: AppColors.skyBlue,
          surface: AppColors.darkOverlay,
          error: AppColors.red,
        ),
        textTheme: GoogleFonts.interTextTheme(Theme.of(context).textTheme)
            .copyWith(
              headlineMedium: GoogleFonts.oswald(
                color: AppColors.snow,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
              titleLarge: GoogleFonts.oswald(
                color: AppColors.snow,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                fontSize: 20,
              ),
              titleMedium: GoogleFonts.oswald(
                color: AppColors.stone,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
                fontSize: 14,
              ),
              bodyMedium: GoogleFonts.inter(color: AppColors.stone),
            ),
      ),
      home: const AuthScreen(),
    );
  }
}

// ==========================================
// MOCK HARDWARE & STATE (SIMULATOR)
// ==========================================
enum AltitudeState { normal, exhaustion, hypoxia }

class MockVitalsRepository {
  final _random = Random();
  AltitudeState currentState = AltitudeState.normal;
  final _controller = StreamController<Map<String, double>>.broadcast();
  Timer? _timer;

  MockVitalsRepository() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _controller.add(_generatePhysiologicalData());
    });
  }

  void dispose() {
    _timer?.cancel();
    _controller.close();
  }

  Stream<Map<String, double>> get vitalsStream => _controller.stream;

  Map<String, double> _generatePhysiologicalData() {
    double spo2, brpm, hr;
    switch (currentState) {
      case AltitudeState.hypoxia:
        spo2 = 78.0;
        brpm = 26.0;
        hr = 115.0;
        break;
      case AltitudeState.exhaustion:
        spo2 = 88.0;
        brpm = 20.0;
        hr = 95.0;
        break;
      case AltitudeState.normal:
      default:
        spo2 = 97.0;
        brpm = 14.0;
        hr = 65.0;
        break;
    }
    return {
      'spo2': (spo2 + (_random.nextDouble() * 2 - 1)).clamp(0.0, 100.0),
      'brpm': brpm + (_random.nextDouble() * 3 - 1.5),
      'hr': hr + (_random.nextDouble() * 4 - 2),
    };
  }
}

class AffirmationService {
  static final List<String> affirmations = [
    "Respect the mountain. Trust your preparation.",
    "One step at a time. One breath at a time.",
    "You are stronger than you think.",
    "Stay calm. Stay focused. Keep moving.",
    "Courage is moving forward even when the path is difficult.",
    "We cannot defeat the mountain. We can prepare for what it brings.",
    "The summit is earned one step at a time.",
  ];

  static String getRandomAffirmation() {
    return affirmations[Random().nextInt(affirmations.length)];
  }
}

// ==========================================
// 1. AUTHENTICATION (API-BACKED, RESPONSIVE)
// ==========================================
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

///class auth --
class _AuthScreenState extends State<AuthScreen> {
  bool isLogin = true;
  bool _busy = false;
  int _step = 0; // sign-up: 0 email, 1 code, 2 details
  String _signupToken = '';
  int _resendIn = 0;
  Timer? _resendTimer;
  final _formKey = GlobalKey<FormState>();

  final _emailC = TextEditingController();
  final _codeC = TextEditingController();
  final _passC = TextEditingController();
  final _confirmC = TextEditingController();
  final _nameC = TextEditingController();
  final _phoneC = TextEditingController(text: '+');
  final _heightC = TextEditingController();
  final _weightC = TextEditingController();
  final _bloodC = TextEditingController();
  final _healthC = TextEditingController();
  final _allergiesC = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tryAutoLogin();
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    for (final c in [
      _emailC,
      _codeC,
      _passC,
      _confirmC,
      _nameC,
      _phoneC,
      _heightC,
      _weightC,
      _bloodC,
      _healthC,
      _allergiesC,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String _orDefault(dynamic v, String fallback) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? fallback : s;
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('❌ $msg'), backgroundColor: AppColors.red),
    );
  }

  void _info(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.forest),
    );
  }

  // ---------- validators ----------
  String? _vEmail(String? v) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim())
      ? null
      : 'Enter a valid email';

  String? _vPhone(String? v) =>
      RegExp(
        r'^\+[1-9]\d{7,14}$',
      ).hasMatch((v ?? '').replaceAll(RegExp(r'[\s\-().]'), ''))
      ? null
      : 'Include the country code, e.g. +919812345678';

  String? _vNewPass(String? v) {
    final s = v ?? '';
    if (s.length < 8) return 'At least 8 characters';
    if (!RegExp(r'[A-Za-z]').hasMatch(s) || !RegExp(r'\d').hasMatch(s)) {
      return 'Use both letters and numbers';
    }
    return null;
  }

  // ---------- auto login ----------
  Future<void> _tryAutoLogin() async {
    final api = ApiService();
    if (!await api.hasSavedToken()) return;
    final me = await api.getMe();
    if (!mounted) return;
    if (me != null) {
      await _enter(me);
      return;
    }
    // Server unreachable (a rejected token was already cleared): use the cached profile.
    if (!await api.hasSavedToken()) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kProfileCache);
      if (raw == null) return;
      _open(Map<String, String>.from(jsonDecode(raw) as Map));
    } catch (_) {}
  }

  Future<void> _enter(Map<String, dynamic> me) async {
    final contacts = await ApiService().getContacts();
    var phone = '';
    if (contacts != null && contacts.isNotEmpty) {
      final primary = contacts.firstWhere(
        (c) => c['is_primary'] == true,
        orElse: () => contacts.first,
      );
      phone = '${primary['phone_number'] ?? ''}';
    }
    final profile = <String, String>{
      'name': _orDefault(me['full_name'], 'Trekker'),
      'height': '${me['height_cm'] ?? ''}',
      'weight': '${me['weight_kg'] ?? ''}',
      'blood': '${me['blood_group'] ?? ''}',
      'phone': phone,
      'health': _orDefault(me['medical_conditions'], 'None reported'),
      'allergies': _orDefault(me['allergies'], 'No known allergies'),
    };
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kProfileCache, jsonEncode(profile));
    } catch (_) {}
    _open(profile);
  }

  void _open(Map<String, String> p) {
    if (!mounted) return;
    primaryContactPhone.value = p['phone'] ?? '';
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => MainNavigationScreen(
          userName: p['name'] ?? 'Trekker',
          height: p['height'] ?? '',
          weight: p['weight'] ?? '',
          bloodType: p['blood'] ?? '',
          emergencyPhone: p['phone'] ?? '',
          healthCondition: p['health'] ?? 'None reported',
          allergies: p['allergies'] ?? 'No known allergies',
        ),
      ),
    );
  }

  // ---------- actions ----------
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _busy) return;
    setState(() => _busy = true);
    try {
      if (isLogin) {
        await _login();
      } else if (_step == 0) {
        await _requestCode();
      } else if (_step == 1) {
        await _verifyCode();
      } else {
        await _register();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _login() async {
    final api = ApiService();
    final ok = await api.login(_emailC.text.trim(), _passC.text);
    if (!ok) {
      _showError(ApiService.lastError ?? 'Login failed.');
      return;
    }
    final me = await api.getMe();
    if (me == null) {
      _showError('Signed in, but your profile could not be loaded. Try again.');
      return;
    }
    await _enter(me);
  }

  void _startResend() {
    _resendTimer?.cancel();
    setState(() => _resendIn = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _resendIn--);
      if (_resendIn <= 0) t.cancel();
    });
  }

  Future<void> _requestCode() async {
    final email = _emailC.text.trim();
    final err = await ApiService().requestOtp(email);
    if (err != null) {
      _showError(err);
      return;
    }
    _codeC.clear();
    setState(() => _step = 1);
    _startResend();
    _info('Code sent to $email. Check your spam folder too.');
  }

  Future<void> _resend() async {
    if (_resendIn > 0 || _busy) return;
    setState(() => _busy = true);
    final err = await ApiService().requestOtp(_emailC.text.trim());
    if (mounted) setState(() => _busy = false);
    if (err != null) {
      _showError(err);
    } else {
      _startResend();
      _info('A new code was sent.');
    }
  }

  Future<void> _verifyCode() async {
    final r = await ApiService().verifyOtp(
      _emailC.text.trim(),
      _codeC.text.trim(),
    );
    if (r.token == null) {
      _showError(r.error ?? 'Verification failed.');
      return;
    }
    _signupToken = r.token!;
    setState(() => _step = 2);
  }

  Future<void> _register() async {
    final api = ApiService();
    final email = _emailC.text.trim();
    final err = await api.register(
      signupToken: _signupToken,
      password: _passC.text,
      fullName: _nameC.text.trim(),
      phoneNumber: _phoneC.text.trim(),
      heightCm: int.tryParse(_heightC.text.trim()) ?? 0,
      weightKg: int.tryParse(_weightC.text.trim()) ?? 0,
      bloodGroup: _bloodC.text.trim(),
      allergies: _allergiesC.text.trim(),
      medicalConditions: _healthC.text.trim(),
    );
    if (err != null) {
      _showError(err);
      if (err.contains('expired')) setState(() => _step = 0);
      return;
    }
    if (!await api.login(email, _passC.text)) {
      _showError('Account created, but login failed. Please log in.');
      setState(() {
        isLogin = true;
        _step = 0;
      });
      return;
    }
    final me = await api.getMe();
    if (me == null) {
      _showError('Account created. Please log in.');
      setState(() {
        isLogin = true;
        _step = 0;
      });
      return;
    }
    await _enter(me);
  }

  // ---------- UI ----------
  Widget _field(
    String label,
    IconData icon,
    TextEditingController c, {
    TextInputType? type,
    bool obscure = false,
    bool required = true,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: c,
      obscureText: obscure,
      keyboardType: type,
      style: const TextStyle(color: AppColors.snow),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: AppColors.stone),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide.none,
        ),
        filled: true,
        fillColor: Colors.black.withOpacity(0.6),
        labelStyle: const TextStyle(color: AppColors.stone),
      ),
      validator:
          validator ??
          (required
              ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null
              : null),
    );
  }

  List<Widget> _fields() {
    const gap = SizedBox(height: 12);
    final email = _field(
      'Email',
      Icons.email,
      _emailC,
      type: TextInputType.emailAddress,
      validator: _vEmail,
    );

    if (isLogin) {
      return [
        email,
        gap,
        _field('Password', Icons.lock, _passC, obscure: true),
      ];
    }
    if (_step == 0) {
      return [
        email,
        gap,
        Text(
          'We will email you a 6-digit code to confirm this address.',
          style: GoogleFonts.inter(color: AppColors.stone, fontSize: 12),
        ),
      ];
    }
    if (_step == 1) {
      return [
        Text(
          'Enter the 6-digit code sent to\n${_emailC.text.trim()}',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(color: AppColors.snow, fontSize: 14),
        ),
        gap,
        _field(
          'Verification code',
          Icons.pin,
          _codeC,
          type: TextInputType.number,
          validator: (v) => RegExp(r'^\d{6}$').hasMatch((v ?? '').trim())
              ? null
              : 'Enter the 6 digits',
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () => setState(() => _step = 0),
              child: const Text(
                'Use a different email',
                style: TextStyle(color: AppColors.stone, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: (_resendIn > 0 || _busy) ? null : _resend,
              child: Text(
                _resendIn > 0 ? 'Resend in ${_resendIn}s' : 'Resend code',
                style: const TextStyle(color: AppColors.gold, fontSize: 12),
              ),
            ),
          ],
        ),
      ];
    }
    return [
      Text(
        'Email verified: ${_emailC.text.trim()}',
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(color: AppColors.green, fontSize: 12),
      ),
      gap,
      _field('Full name', Icons.person, _nameC),
      gap,
      _field(
        'Your phone number',
        Icons.phone,
        _phoneC,
        type: TextInputType.phone,
        validator: _vPhone,
      ),
      gap,
      Row(
        children: [
          Expanded(
            child: _field(
              'Height (cm)',
              Icons.height,
              _heightC,
              type: TextInputType.number,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _field(
              'Weight (kg)',
              Icons.monitor_weight,
              _weightC,
              type: TextInputType.number,
            ),
          ),
        ],
      ),
      gap,
      _field('Blood group', Icons.bloodtype, _bloodC),
      gap,
      _field(
        'Health conditions',
        Icons.medical_information,
        _healthC,
        required: false,
      ),
      gap,
      _field(
        'Crucial allergies',
        Icons.warning_amber,
        _allergiesC,
        required: false,
      ),
      gap,
      _field(
        'Create a password',
        Icons.lock,
        _passC,
        obscure: true,
        validator: _vNewPass,
      ),
      gap,
      _field(
        'Confirm password',
        Icons.lock_outline,
        _confirmC,
        obscure: true,
        validator: (v) => v == _passC.text ? null : 'Passwords do not match',
      ),
      const SizedBox(height: 8),
      Text(
        'You add an emergency contact later, in the SOS tab.',
        style: GoogleFonts.inter(color: AppColors.stone, fontSize: 11),
      ),
    ];
  }

  String get _buttonLabel {
    if (isLogin) return 'BEGIN ASCENT';
    return const [
      'SEND VERIFICATION CODE',
      'VERIFY CODE',
      'CREATE IDENTITY',
    ][_step];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              image: DecorationImage(
                image: AssetImage('assets/22824.jpg'),
                fit: BoxFit.cover,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withOpacity(0.5),
                  Colors.black.withOpacity(0.95),
                ],
                stops: const [0.0, 0.4, 1.0],
              ),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 60),
                      const Text(
                        '🏔️ K2',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 48,
                          color: AppColors.snow,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2.0,
                        ),
                      ),
                      Text(
                        'MOUNTAIN COMPANION',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.oswald(
                          fontSize: 16,
                          color: AppColors.stone,
                          letterSpacing: 4.0,
                        ),
                      ),
                      const SizedBox(height: 40),
                      ..._fields(),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.gold,
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.charcoal,
                                ),
                              )
                            : Text(
                                _buttonLabel,
                                style: GoogleFonts.oswald(
                                  color: AppColors.charcoal,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                  letterSpacing: 1.2,
                                ),
                              ),
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () {
                                setState(() {
                                  isLogin = !isLogin;
                                  _step = 0;
                                });
                                _formKey.currentState?.reset();
                              },
                        child: Text(
                          isLogin
                              ? 'New trekker? Sign up'
                              : 'Already a member? Login',
                          style: const TextStyle(color: AppColors.stone),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '"Respect every step."',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          color: AppColors.stone,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// 2. MAIN NAVIGATION
// ==========================================
class MainNavigationScreen extends StatefulWidget {
  final String userName,
      height,
      weight,
      bloodType,
      emergencyPhone,
      healthCondition,
      allergies;
  const MainNavigationScreen({
    super.key,
    required this.userName,
    required this.height,
    required this.weight,
    required this.bloodType,
    required this.emergencyPhone,
    required this.healthCondition,
    required this.allergies,
  });

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: primaryContactPhone,
      builder: (context, phone, _) => _buildScaffold(phone),
    );
  }

  Widget _buildScaffold(String phone) {
    final List<Widget> screens = [
      DashboardScreen(
        userName: widget.userName,
        emergencyPhone: primaryContactPhone.value,
      ),
      const JourneyHomeScreen(),
      const MindsetHomeScreen(),
      EmergencyHubScreen(
        userName: widget.userName,
        emergencyPhone: primaryContactPhone.value,
        bloodType: widget.bloodType,
        healthCondition: widget.healthCondition,
        allergies: widget.allergies,
      ),
      ProfileScreen(
        userName: widget.userName,
        height: widget.height,
        weight: widget.weight,
        bloodType: widget.bloodType,
        healthCondition: widget.healthCondition,
        allergies: widget.allergies,
        emergencyPhone: primaryContactPhone.value,
      ),
    ];

    return Scaffold(
      backgroundColor: AppColors.charcoal,
      body: screens[_currentIndex],
      bottomNavigationBar: Container(
        padding: const EdgeInsets.only(bottom: 16, top: 12),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.9),
          border: const Border(
            top: BorderSide(color: Colors.white10, width: 1),
          ),
        ),
        child: SafeArea(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildNavItem(Icons.landscape, 'EXPEDITION', 0),
              _buildNavItem(Icons.history_rounded, 'JOURNEY', 1),
              _buildNavItem(Icons.psychology_rounded, 'MINDSET', 2),
              _buildNavItem(Icons.warning_rounded, 'SOS', 3, isEmergency: true),
              _buildNavItem(Icons.person_rounded, 'TREKKER', 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(
    IconData icon,
    String label,
    int index, {
    bool isEmergency = false,
  }) {
    bool isSelected = _currentIndex == index;
    Color iconColor = isSelected
        ? (isEmergency ? Colors.redAccent : AppColors.gold)
        : AppColors.stone.withOpacity(0.5);

    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSelected) const Text('🏔️', style: TextStyle(fontSize: 10)),
          if (!isSelected) const SizedBox(height: 12),
          Icon(icon, color: iconColor, size: 24),
          const SizedBox(height: 4),
          Text(
            label,
            style: GoogleFonts.oswald(
              color: iconColor,
              fontSize: 10,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// 3. DASHBOARD (REAL WEATHER, DESCEND & SAVE, MOUNTAIN SAFETY)
// ==========================================
class DashboardScreen extends StatefulWidget {
  final String userName;
  final String emergencyPhone;
  const DashboardScreen({
    super.key,
    required this.userName,
    required this.emergencyPhone,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late MockVitalsRepository _vitalsRepo;

  // Real weather
  MountainWeather? _weatherData;
  bool _weatherLoading = true;
  Timer? _weatherTimer;
  double _waterConsumedLiters = 0;
  final double _dailyWaterGoal = 4.0;
  final List<Map<String, dynamic>> _waterLogs = [];

  // Camp progress now comes from the GPS tracker (waypoints or manual confirmation).
  int get _currentRouteStage => TrekTracker.instance.reachedStage;
  String _affirmation = AffirmationService.getRandomAffirmation();
  Timer? _affirmationTimer;

  Future<void> _loadWeather() async {
    if (mounted) setState(() => _weatherLoading = true);
    try {
      final w = await WeatherService.fetchCurrent();
      if (!mounted) return;
      setState(() {
        _weatherData = w;
        _weatherLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _weatherLoading = false); // keeps last known data
    }
  }

  @override
  void initState() {
    super.initState();
    _loadHydration();
    ChecklistStore.instance.addListener(_onChecklistChange);
    ChecklistStore.instance.load();
    _loadWeather();
    TrekTracker.instance.addListener(_onTrackerChange);
    TrekTracker.instance.init();
    _weatherTimer = Timer.periodic(
      const Duration(minutes: 10),
      (_) => _loadWeather(),
    );
    _vitalsRepo = MockVitalsRepository();

    _affirmationTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      if (!mounted) return;
      setState(() {
        _affirmation = AffirmationService.getRandomAffirmation();
      });
    });
  }

  @override
  void dispose() {
    _weatherTimer?.cancel();
    ChecklistStore.instance.removeListener(_onChecklistChange);
    TrekTracker.instance.removeListener(_onTrackerChange);
    _vitalsRepo.dispose();
    _affirmationTimer?.cancel();
    super.dispose();
  }

  void _onChecklistChange() {
    if (mounted) setState(() {});
  }

  Future<void> _loadHydration() async {
    try {
      await ApiService().flushPendingWater();

      if (!mounted) return;

      final res = await ApiService().getTodayHydration();

      if (res == null || !mounted) return;

      final entries = (res['entries'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      setState(() {
        _waterConsumedLiters = ((res['total_ml'] as num?) ?? 0) / 1000;

        _waterLogs
          ..clear()
          ..addAll(
            entries.map((e) {
              final t =
                  (DateTime.tryParse('${e['logged_at']}') ?? DateTime.now())
                      .toLocal();

              return {
                'time':
                    '${t.hour.toString().padLeft(2, '0')}:'
                    '${t.minute.toString().padLeft(2, '0')}',
                'amount': (e['amount_ml'] as num?)?.toInt() ?? 0,
              };
            }),
          );
      });
    } catch (e) {
      debugPrint('Hydration loading failed: $e');
    }
  }

  Widget _buildNotifItem(String title, String message, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.charcoal,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 42,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.oswald(
                    color: AppColors.snow,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  message,
                  style: GoogleFonts.inter(
                    color: AppColors.stone,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openNotifications() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.charcoal,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '🔔 NOTIFICATIONS',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 24),
              _buildNotifItem(
                '⚠️ Mountain Conditions',
                _weatherData == null
                    ? 'Weather data loading…'
                    : '${_weatherData!.tempC.round()}°C, '
                          'wind ${_weatherData!.windKmh.round()} km/h, '
                          'avalanche risk (est.) ${_weatherData!.avalanche.label}',
                Colors.orangeAccent,
              ),
              _buildNotifItem(
                '💧 Hydration',
                'You are ${_waterConsumedLiters.toStringAsFixed(1)}L '
                    '/ ${_dailyWaterGoal.toStringAsFixed(1)}L today',
                AppColors.skyBlue,
              ),
              _buildNotifItem(
                '🏔️ Trek',
                'Last confirmed: '
                    '${TrekTracker.stageLabels[_currentRouteStage]}.',
                AppColors.snow,
              ),
              ValueListenableBuilder<String>(
                valueListenable: primaryContactPhone,
                builder: (context, phone, child) {
                  final hasContact = phone.trim().isNotEmpty;
                  return _buildNotifItem(
                    hasContact ? '✓ Safety Check' : '⚠️ Safety Check',
                    hasContact
                        ? 'Emergency contact saved: $phone'
                        : 'No emergency contact set. Add one in the SOS tab.',
                    hasContact ? AppColors.green : Colors.orangeAccent,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _resumeTrek() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.charcoal,
        title: Text(
          'RESUMING EXPEDITION',
          style: GoogleFonts.oswald(
            color: AppColors.snow,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'Loading route data from Base to Camp 1...',
          style: GoogleFonts.inter(color: AppColors.stone),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const TrekTrackerScreen(),
                ),
              );
            },
            child: const Text(
              'PROCEED',
              style: TextStyle(color: AppColors.gold),
            ),
          ),
        ],
      ),
    );
  }

  void _openLiveVitals() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => LiveVitalsScreen(vitalsRepo: _vitalsRepo),
      ),
    );
  }

  void _openJourneyMap() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const TrekTrackerScreen()),
    );
  }

  void _openGpsNavigation() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const GpsNavigationScreen()),
    );
  }

  void _openWeatherBrief() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const WeatherBriefScreen()),
    );
  }

  // ---------- DESCEND & SAVE JOURNEY ----------
  void _descendAndSave() {
    final t = TrekTracker.instance;
    final tracking = t.isActive;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.charcoal,
        title: Text(
          'DESCEND & SAVE?',
          style: GoogleFonts.oswald(
            color: AppColors.snow,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          tracking
              ? 'This ends your GPS trek (${formatKm(t.distanceM)}, ${formatDuration(t.elapsed.inSeconds)}) and saves it to your Journey.'
              : 'No GPS trek is being recorded, so there is no distance to save. Start tracking first, or save this journey with 0 km and no route.',
          style: GoogleFonts.inter(color: AppColors.stone),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'CANCEL',
              style: TextStyle(color: AppColors.stone),
            ),
          ),
          if (!tracking)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _openJourneyMap();
              },
              child: const Text(
                'OPEN TRACKER',
                style: TextStyle(color: AppColors.skyBlue),
              ),
            ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.gold),
            onPressed: () {
              Navigator.pop(ctx);
              _saveJourney();
            },
            child: Text(
              tracking ? 'SAVE' : 'SAVE (NO GPS)',
              style: const TextStyle(color: AppColors.charcoal),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveJourney() async {
    final t = TrekTracker.instance;
    final name = 'K2 EXPEDITION — ${TrekTracker.stageLabels[t.reachedStage]}';
    SavedTrek? trek;
    if (t.isActive) {
      trek = await t.finish(name: name);
    } else {
      final now = DateTime.now();
      trek = SavedTrek(
        id: '${now.millisecondsSinceEpoch}',
        name: name,
        start: now,
        end: now,
        distanceM: 0,
        movingSec: 0,
        elapsedSec: 0,
        gainM: 0,
        maxAlt: null,
        points: const [],
      );
    }
    final synced = trek == null ? false : await persistTrekToJourney(trek);
    t.confirmStageManually(0); // a new expedition starts again at base

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.forest,
        content: Text(
          synced
              ? 'Journey saved. Safe descent!'
              : 'Saved on this device. Cloud sync failed, check your connection.',
        ),
        action: SnackBarAction(
          label: 'VIEW',
          textColor: AppColors.gold,
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const JourneyHomeScreen()),
          ),
        ),
      ),
    );
  }

  void _openHydrationTracker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.charcoal,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.85,
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'HYDRATION',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    "Today's intake",
                    style: GoogleFonts.inter(
                      color: AppColors.stone,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_waterConsumedLiters.toStringAsFixed(1)} L / ${_dailyWaterGoal.toStringAsFixed(1)} L',
                    style: GoogleFonts.oswald(
                      color: AppColors.snow,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: _waterConsumedLiters / _dailyWaterGoal,
                    backgroundColor: Colors.white10,
                    color: AppColors.skyBlue,
                    minHeight: 12,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  const SizedBox(height: 32),

                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [250, 500, 750, 1000].map((amount) {
                      return ActionChip(
                        label: Text(
                          '+$amount ml',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        backgroundColor: AppColors.forest,
                        side: const BorderSide(color: AppColors.skyBlue),
                        onPressed: () async {
                          setState(() {
                            _waterConsumedLiters += (amount / 1000);
                            _waterLogs.insert(0, {
                              'time':
                                  "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}",
                              'amount': amount,
                            });
                          });
                          setModalState(() {});
                          DatabaseHelper.instance.insertWater({
                            'user_id': 1,
                            'amount': amount / 1000,
                            'timestamp': DateTime.now().toIso8601String(),
                          });
                          final ok = await ApiService().logWaterQueued(amount);
                          if (!ok && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Saved on this phone. It will sync when the server is reachable.',
                                ),
                                backgroundColor: AppColors.forest,
                              ),
                            );
                          }
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 32),
                  const Divider(color: Colors.white10),
                  const SizedBox(height: 16),
                  Text(
                    'Today\'s logs',
                    style: GoogleFonts.inter(
                      color: AppColors.stone,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _waterLogs.length,
                      itemBuilder: (context, index) {
                        final log = _waterLogs[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                log['time'],
                                style: GoogleFonts.oswald(
                                  color: AppColors.stone,
                                  fontSize: 16,
                                ),
                              ),
                              Text(
                                '${log['amount']} ml',
                                style: GoogleFonts.inter(
                                  color: AppColors.snow,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  Center(
                    child: Text(
                      'Remaining: ${(_dailyWaterGoal - _waterConsumedLiters).clamp(0, 10).toStringAsFixed(1)} L',
                      style: GoogleFonts.oswald(
                        color: AppColors.skyBlue,
                        fontSize: 18,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showManualTrekDialog() {
    final nameCtrl = TextEditingController();
    final distCtrl = TextEditingController();
    final altCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.forest,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          title: Text(
            "LOG ROUTE",
            style: GoogleFonts.oswald(
              color: AppColors.snow,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: AppColors.snow),
                decoration: const InputDecoration(
                  labelText: "Trek Name",
                  labelStyle: TextStyle(color: AppColors.stone),
                ),
              ),
              TextField(
                controller: distCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: AppColors.snow),
                decoration: const InputDecoration(
                  labelText: "Distance (km)",
                  labelStyle: TextStyle(color: AppColors.stone),
                ),
              ),
              TextField(
                controller: altCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: AppColors.snow),
                decoration: const InputDecoration(
                  labelText: "Max Altitude (m)",
                  labelStyle: TextStyle(color: AppColors.stone),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "CANCEL",
                style: TextStyle(color: AppColors.stone),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gold,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              onPressed: () async {
                if (nameCtrl.text.isEmpty) return;
                await DatabaseHelper.instance.insertTrek({
                  'user_id': 1,
                  'trek_name': nameCtrl.text.trim(),
                  'start_date': DateTime.now()
                      .subtract(const Duration(hours: 6))
                      .toIso8601String(),
                  'end_date': DateTime.now().toIso8601String(),
                  'distance': double.tryParse(distCtrl.text) ?? 0.0,
                  'max_altitude': int.tryParse(altCtrl.text) ?? 0,
                  'status': 'Completed',
                });
                await ApiService().createTrekWithDetails(
                  nameCtrl.text.trim(),
                  double.tryParse(distCtrl.text) ?? 0.0,
                  double.tryParse(altCtrl.text) ?? 0.0,
                );
                if (!mounted) return;
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Route saved to local & cloud database!'),
                    backgroundColor: AppColors.forest,
                  ),
                );
              },
              child: Text(
                "SAVE",
                style: GoogleFonts.oswald(
                  color: AppColors.charcoal,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _openModernChecklist() {
    final store = ChecklistStore.instance;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return AnimatedBuilder(
          animation: store,
          builder: (context, _) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.85,
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                color: AppColors.charcoal,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'EXPEDITION GEAR',
                        style: GoogleFonts.oswald(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: AppColors.snow,
                          letterSpacing: 1.2,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.skyBlue.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${store.done} / ${store.total} READY',
                          style: const TextStyle(
                            color: AppColors.skyBlue,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    store.unsynced
                        ? 'Saved on this phone. Not synced to the server yet.'
                        : 'All changes synced.',
                    style: GoogleFonts.inter(
                      color: AppColors.stone,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final cat in ChecklistStore.categories) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 16, bottom: 4),
                            child: Text(
                              '${cat.emoji} ${cat.title.toUpperCase()}  (${store.doneIn(cat)}/${cat.items.length})',
                              style: GoogleFonts.oswald(
                                color: AppColors.gold,
                                fontSize: 13,
                                letterSpacing: 1.0,
                              ),
                            ),
                          ),
                          for (final item in cat.items)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              onTap: () => store.toggle(item),
                              leading: Icon(
                                store.isChecked(item)
                                    ? Icons.check_box
                                    : Icons.check_box_outline_blank,
                                color: store.isChecked(item)
                                    ? AppColors.gold
                                    : AppColors.stone,
                              ),
                              title: Text(
                                item,
                                style: GoogleFonts.inter(
                                  color: store.isChecked(item)
                                      ? AppColors.snow
                                      : AppColors.stone,
                                  fontSize: 14,
                                  decoration: store.isChecked(item)
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _openNutritionGuide() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.85,
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            color: AppColors.charcoal,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'TREK NUTRITION',
                style: GoogleFonts.oswald(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: AppColors.snow,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Fuel your climb.',
                style: GoogleFonts.inter(
                  color: AppColors.stone,
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 32),
              Expanded(
                child: ListView(
                  children: [
                    _buildNutritionTip(
                      'ENERGY NEEDS',
                      'Long climbs greatly increase energy requirements. Eat regularly.',
                      Icons.local_fire_department,
                      AppColors.red,
                    ),
                    _buildNutritionTip(
                      'HYDRATION',
                      'Drink according to exertion, weather, and individual needs. Avoid dehydration.',
                      Icons.water_drop,
                      AppColors.skyBlue,
                    ),
                    _buildNutritionTip(
                      'TRAIL FOOD',
                      '• Trail mix\n• Energy bars\n• Dried fruit\n• Carbohydrate foods',
                      Icons.shopping_bag,
                      AppColors.gold,
                    ),
                    _buildNutritionTip(
                      'CAMP MEALS',
                      'Prioritize practical, energy-dense meals containing carbs and protein.',
                      Icons.restaurant,
                      AppColors.green,
                    ),
                    _buildNutritionTip(
                      'ALTITUDE SAFETY',
                      'Reduced appetite is common. Monitor for nausea or extreme fatigue.',
                      Icons.warning_amber_rounded,
                      Colors.orangeAccent,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNutritionTip(
    String title,
    String desc,
    IconData icon,
    Color color,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.stone, size: 24),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.oswald(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: AppColors.snow,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: GoogleFonts.inter(color: AppColors.stone, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openClimbAnalysis() {
    final t = TrekTracker.instance;
    final w = _weatherData;
    String m(double? v) => v == null ? '—' : '${v.round()} m';
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.charcoal,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        Widget row(String k, String v, {Color? c}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(k, style: GoogleFonts.inter(color: AppColors.stone)),
              Flexible(
                child: Text(
                  v,
                  textAlign: TextAlign.right,
                  style: GoogleFonts.oswald(
                    color: c ?? AppColors.snow,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        );
        return Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'CLIMB ANALYSIS',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.forest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  children: [
                    row('Current altitude (GPS)', m(t.currentAltitude)),
                    const Divider(color: Colors.white10, height: 8),
                    row('Highest altitude this trek', m(t.maxAltitude)),
                    row(
                      'Elevation gain',
                      t.maxAltitude == null ? '—' : '+${t.gainM.round()} m',
                    ),
                    row(
                      'GPS accuracy',
                      t.lastAccuracy == null
                          ? 'No fix'
                          : '±${t.lastAccuracy!.round()} m',
                    ),
                    row(
                      'Avalanche risk (estimated)',
                      w?.avalanche.label ?? '—',
                      c: w?.avalanche.color,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'GPS altitude can be off by 10 to 30 m or more, and is smoothed over three readings. Treat it as a guide, not a surveyed height.',
                style: GoogleFonts.inter(
                  color: AppColors.stone,
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                  height: 1.4,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = _weatherData;
    final trk = TrekTracker.instance;
    final altNow = trk.currentAltitude;
    final toNext = trk.distanceToNextM();
    final completedChecklist = ChecklistStore.instance.done;
    bool isMobile = MediaQuery.of(context).size.width < 800;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset('assets/22824.jpg', fit: BoxFit.cover),
          ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.35),
                    Colors.black.withOpacity(0.55),
                    Colors.black.withOpacity(0.90),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                isMobile ? 16 : 40,
                isMobile ? 20 : 40,
                isMobile ? 16 : 40,
                40,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '🏔️ Hey, ${widget.userName} 👋',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w600,
                          color: AppColors.snow,
                          fontSize: 16,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.notifications_active,
                          color: AppColors.snow,
                        ),
                        onPressed: _openNotifications,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'MOUNTAIN MINDSET',
                    style: GoogleFonts.oswald(
                      color: AppColors.stone,
                      fontSize: 12,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 500),
                    child: Text(
                      '"$_affirmation"',
                      key: ValueKey(_affirmation),
                      style: GoogleFonts.inter(
                        color: AppColors.snow,
                        fontStyle: FontStyle.italic,
                        fontSize: 16,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 48),
                  Text(
                    'YOUR NEXT ADVENTURE',
                    style: GoogleFonts.oswald(
                      color: AppColors.stone,
                      fontSize: 12,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'K2 EXPEDITION',
                    style: GoogleFonts.oswald(
                      color: AppColors.snow,
                      fontSize: isMobile ? 36 : 48,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.0,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your journey begins here.',
                    style: GoogleFonts.inter(
                      color: AppColors.stone,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: _resumeTrek,
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('CONTINUE TREK'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFD4A72C),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 48),
                  const Divider(color: Colors.white12),
                  const SizedBox(height: 24),
                  Center(
                    child: Text(
                      'MOUNTAIN CONDITIONS',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildConditionStat(
                        '🌡️',
                        w == null ? '--' : '${w.tempC.round()}°C',
                        'WEATHER',
                        w?.conditionText ??
                            (_weatherLoading ? 'Loading…' : 'Offline'),
                        false,
                      ),
                      _buildConditionStat(
                        '💨',
                        w == null ? '--' : '${w.windKmh.round()} km/h',
                        'WIND',
                        w?.windLabel ?? '',
                        (w?.windKmh ?? 0) >= 40,
                      ),
                      _buildConditionStat(
                        '❄️',
                        w?.avalanche.label ?? '--',
                        'AVALANCHE',
                        'ESTIMATED',
                        w != null && w.avalanche.index >= 2,
                      ),
                    ],
                  ),
                  if (w != null) ...[
                    const SizedBox(height: 12),
                    Center(
                      child: Text(
                        '${w.locationNote} • ${w.elevationM.round()} m • updated ${TimeOfDay.fromDateTime(w.fetchedAt).format(context)}',
                        style: GoogleFonts.inter(
                          color: AppColors.stone,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  const Divider(color: Colors.white12),
                  const SizedBox(height: 48),
                  Text(
                    '🏔️ YOUR EXPEDITION',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 24),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildRouteNode('BASE', 0),
                      _buildRouteLine(0),
                      _buildRouteNode('CAMP 1', 1),
                      _buildRouteLine(1),
                      _buildRouteNode('CAMP 2', 2),
                      _buildRouteLine(2),
                      _buildRouteNode('SUMMIT', 3),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${TrekTracker.stageLabels[_currentRouteStage]} confirmed',
                            style: GoogleFonts.inter(
                              color: AppColors.snow,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '${(_currentRouteStage / 3 * 100).toInt()}% of camps confirmed',
                            style: GoogleFonts.inter(
                              color: AppColors.stone,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            altNow == null ? '— m' : '${altNow.round()} m',
                            style: GoogleFonts.oswald(
                              color: AppColors.gold,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            toNext == null
                                ? (trk.nextStage == null
                                      ? 'Summit stage'
                                      : 'Set camp waypoints')
                                : '${formatKm(toNext)} to ${TrekTracker.stageLabels[trk.nextStage!]}',
                            style: GoogleFonts.inter(
                              color: AppColors.stone,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildGpsStrip(),
                  const SizedBox(height: 48),
                  StreamBuilder<Map<String, double>>(
                    stream: _vitalsRepo.vitalsStream,
                    builder: (context, snapshot) {
                      final data =
                          snapshot.data ??
                          {'hr': 65.0, 'brpm': 14.0, 'spo2': 97.0};

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SecretDevMenuTrigger(
                            onStateChanged: (newState) => setState(
                              () => _vitalsRepo.currentState = newState,
                            ),
                            child: Text(
                              'TRAIL STATUS',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          const SizedBox(height: 16),
                          ReactiveSafetyBanner(spo2: data['spo2']!),
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Expanded(
                                child: _buildInteractiveCard(
                                  '❤️',
                                  '${data['hr']?.toInt()} BPM',
                                  'Vitals (DEMO)',
                                  'SpO₂: ${data['spo2']?.toInt()}% • ${data['brpm']?.toInt()} RPM',
                                  'VIEW VITALS',
                                  _openLiveVitals,
                                  AppColors.red,
                                  [0.3, 0.4, 0.3, 0.5, 0.8, 0.2, 0.4, 0.3],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _buildInteractiveCard(
                                  '🥛',
                                  '${_waterConsumedLiters.toStringAsFixed(1)} L',
                                  'Hydration',
                                  '${(_waterConsumedLiters / _dailyWaterGoal * 100).toInt()}% goal',
                                  'LOG WATER',
                                  _openHydrationTracker,
                                  AppColors.skyBlue,
                                  [0.2, 0.3, 0.5, 0.4, 0.6, 0.5, 0.7, 0.8],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _buildInteractiveCard(
                                  '🥾',
                                  trk.hasTodayGps
                                      ? formatKm(trk.todayDistanceM)
                                      : '—',
                                  'Distance',
                                  trk.hasTodayGps
                                      ? 'Recorded today by GPS'
                                      : 'No GPS distance recorded',
                                  'OPEN TRACKER',
                                  _openJourneyMap,
                                  AppColors.green,
                                  trk.sparkDistance(),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _buildInteractiveCard(
                                  '⛰️',
                                  altNow == null ? '—' : '${altNow.round()} m',
                                  'Altitude',
                                  altNow == null
                                      ? 'No altitude fix'
                                      : 'GPS • ${TrekTracker.stageLabels[_currentRouteStage]}',
                                  'VIEW ALTIMETER',
                                  _openClimbAnalysis,
                                  AppColors.gold,
                                  trk.sparkAltitude(),
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 48),
                  Text(
                    'TREK TOOLKIT',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _buildToolBox(
                          '🎒 TREK CHECKLIST',
                          '$completedChecklist of ${ChecklistStore.instance.total} ready',
                          'VIEW',
                          _openModernChecklist,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildToolBox(
                          '🍴 NUTRITION',
                          'Fuel your climb',
                          'EXPLORE',
                          _openNutritionGuide,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildToolBox(
                          '🧭 NAVIGATION',
                          'GPS Active',
                          'OPEN MAP',
                          _openGpsNavigation,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildToolBox(
                          '🌦 WEATHER',
                          w == null
                              ? 'Loading…'
                              : '${w.tempC.round()}°C Wind ${w.windKmh.round()}km/h',
                          'FORECAST',
                          _openWeatherBrief,
                        ),
                      ),
                    ],
                  ),

                  // DESCEND & SAVE JOURNEY + MOUNTAIN SAFETY
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _descendAndSave,
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('DESCEND & SAVE JOURNEY'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD4A72C),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  MountainSafetyCard(
                    weather: w,
                    loading: _weatherLoading,
                    hasEmergencyContact: primaryContactPhone.value
                        .trim()
                        .isNotEmpty,
                    onRefresh: _loadWeather,
                  ),
                  const SizedBox(height: 48),

                  // THE INSPIRATION VIDEO PLAYER SECTION
                  Text(
                    'THE INSPIRATION',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const VideoPlayerScreen(
                          title: 'THE INSPIRATION',
                          asset: 'assets/Video_Project.mp4',
                        ),
                      ),
                    ),
                    child: Container(
                      height: 200,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white10),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.asset('assets/22824.jpg', fit: BoxFit.cover),
                            Container(color: Colors.black.withOpacity(0.5)),
                            const Center(
                              child: Icon(
                                Icons.play_circle_fill,
                                size: 64,
                                color: AppColors.stone,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    '"Mountains don\'t promise safety.\nThey teach us to respect every step."',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontStyle: FontStyle.italic,
                      color: AppColors.stone,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onTrackerChange() {
    if (!mounted) return;
    setState(() {});
    final e = TrekTracker.instance.takeEvent();
    if (e != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: AppColors.forest, content: Text(e)),
      );
    }
  }

  Widget _buildGpsStrip() {
    final t = TrekTracker.instance;
    final acc = t.lastAccuracy;
    String text;
    Color color;
    switch (t.state) {
      case TrackState.tracking:
        text =
            'GPS tracking  •  ${formatKm(t.distanceM)}${acc == null ? '' : '  •  ±${acc.round()} m'}';
        color = AppColors.green;
        break;
      case TrackState.paused:
        text = 'Trek paused  •  ${formatKm(t.distanceM)}';
        color = AppColors.gold;
        break;
      case TrackState.idle:
        text = acc == null
            ? 'GPS idle. Open the tracker to start a trek.'
            : 'GPS idle  •  last fix ±${acc.round()} m';
        color = AppColors.stone;
        break;
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Icon(Icons.gps_fixed, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(color: AppColors.snow, fontSize: 11),
            ),
          ),
          TextButton(
            onPressed: _openJourneyMap,
            style: TextButton.styleFrom(foregroundColor: AppColors.gold),
            child: Text(
              t.isActive ? 'TRACKER' : 'START',
              style: GoogleFonts.oswald(fontSize: 12, letterSpacing: 1),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CampWaypointsScreen()),
            ),
            style: TextButton.styleFrom(foregroundColor: AppColors.skyBlue),
            child: Text(
              'CAMPS',
              style: GoogleFonts.oswald(fontSize: 12, letterSpacing: 1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInteractiveCard(
    String emoji,
    String value,
    String title,
    String subtitle,
    String btnText,
    VoidCallback onTap,
    Color sparkColor,
    List<double> dataPoints,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Text(
                title.toUpperCase(),
                style: GoogleFonts.oswald(
                  color: AppColors.snow,
                  fontSize: 12,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: GoogleFonts.oswald(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.snow,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: GoogleFonts.inter(fontSize: 11, color: AppColors.stone),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 24,
            width: double.infinity,
            child: CustomPaint(
              painter: _SparklinePainter(
                color: sparkColor,
                dataPoints: dataPoints,
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.arrow_forward, size: 14),
            label: Text(
              btnText,
              style: GoogleFonts.oswald(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
              ),
            ),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.gold,
              padding: EdgeInsets.zero,
              alignment: Alignment.centerLeft,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConditionStat(
    String emoji,
    String val,
    String title,
    String subtitle,
    bool isWarning,
  ) {
    return Column(
      children: [
        Text(
          val,
          style: GoogleFonts.oswald(
            color: isWarning ? AppColors.gold : AppColors.snow,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          title,
          style: GoogleFonts.oswald(
            color: AppColors.stone,
            fontSize: 10,
            letterSpacing: 1.0,
          ),
        ),
        Text(
          subtitle,
          style: GoogleFonts.inter(
            color: isWarning ? AppColors.gold : AppColors.stone,
            fontSize: 12,
            fontWeight: isWarning ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _buildRouteNode(String label, int stageIndex) {
    bool isCompleted = stageIndex <= _currentRouteStage;
    bool isCurrent = stageIndex == _currentRouteStage;

    return GestureDetector(
      onTap: () => confirmStageDialog(context, stageIndex),
      child: Column(
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: isCurrent || isCompleted
                  ? AppColors.snow
                  : AppColors.stone,
            ),
          ),
          const SizedBox(height: 8),
          Icon(
            isCompleted && !isCurrent
                ? Icons.check
                : (isCurrent ? Icons.circle : Icons.circle_outlined),
            size: 16,
            color: isCurrent
                ? AppColors.gold
                : (isCompleted
                      ? AppColors.stone
                      : AppColors.stone.withOpacity(0.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteLine(int stageIndex) {
    bool isCompleted = stageIndex < _currentRouteStage;
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(top: 22),
        height: 1,
        color: isCompleted ? AppColors.stone : AppColors.stone.withOpacity(0.2),
      ),
    );
  }

  Widget _buildToolBox(
    String title,
    String subtitle,
    String btnText,
    VoidCallback onTap,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.oswald(
              color: AppColors.snow,
              fontSize: 12,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            subtitle,
            style: GoogleFonts.inter(fontSize: 11, color: AppColors.stone),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.arrow_forward, size: 14),
            label: Text(
              btnText,
              style: GoogleFonts.oswald(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
              ),
            ),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.gold,
              padding: EdgeInsets.zero,
              alignment: Alignment.centerLeft,
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// MOUNTAIN SAFETY CARD (REAL WEATHER + ESTIMATED AVALANCHE RISK)
// ==========================================
class MountainSafetyCard extends StatelessWidget {
  final MountainWeather? weather;
  final bool loading;
  final bool hasEmergencyContact;
  final VoidCallback onRefresh;

  const MountainSafetyCard({
    super.key,
    required this.weather,
    required this.loading,
    required this.hasEmergencyContact,
    required this.onRefresh,
  });

  Widget _row(IconData icon, String text, Color color) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            text,
            style: GoogleFonts.inter(color: AppColors.snow, fontSize: 14),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final w = weather;
    final av = w?.avalanche;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.charcoal.withOpacity(0.92),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        children: [
          const Text('🏔️', style: TextStyle(fontSize: 36)),
          const SizedBox(height: 12),
          Text(
            'MOUNTAIN SAFETY',
            style: GoogleFonts.oswald(
              color: AppColors.snow,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'KNOW THE MOUNTAIN.\nRESPECT THE MOUNTAIN.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              color: AppColors.stone,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          if (w != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              decoration: BoxDecoration(
                color: w.verdictColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: w.verdictColor.withOpacity(0.5)),
              ),
              child: Text(
                w.verdictTitle,
                textAlign: TextAlign.center,
                style: GoogleFonts.oswald(
                  color: w.verdictColor,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
            ),
          const SizedBox(height: 12),
          _row(
            w != null ? Icons.check : Icons.hourglass_empty,
            w != null
                ? 'Weather checked: ${w.tempC.round()}°C, gusts ${w.gustKmh.round()} km/h'
                : (loading ? 'Checking weather…' : 'Weather unavailable'),
            w != null ? AppColors.snow : Colors.orangeAccent,
          ),
          _row(
            hasEmergencyContact ? Icons.check : Icons.warning_amber_rounded,
            hasEmergencyContact
                ? 'Emergency contacts ready'
                : 'No emergency contact set',
            hasEmergencyContact ? AppColors.snow : Colors.orangeAccent,
          ),
          _row(
            av == null || av.index < 2
                ? Icons.check
                : Icons.warning_amber_rounded,
            av == null
                ? 'Avalanche conditions: unknown'
                : 'Avalanche risk (estimated): ${av.label}'
                      '${w!.snowfallCm >= 1 ? ' • ${w.snowfallCm.toStringAsFixed(0)} cm recent snow' : ''}',
            av?.color ?? Colors.orangeAccent,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: loading ? null : onRefresh,
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(loading ? 'UPDATING…' : 'REFRESH CONDITIONS'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.gold,
              side: const BorderSide(color: AppColors.gold),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Estimate from live weather, recent snowfall and wind. Not an official avalanche bulletin. Always check local forecasts.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              color: AppColors.stone,
              fontSize: 10,
              fontStyle: FontStyle.italic,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// SUPPORTING SCREENS & UTILITIES
// ==========================================
class SecretDevMenuTrigger extends StatefulWidget {
  final Widget child;
  final Function(AltitudeState) onStateChanged;

  const SecretDevMenuTrigger({
    super.key,
    required this.child,
    required this.onStateChanged,
  });

  @override
  State<SecretDevMenuTrigger> createState() => _SecretDevMenuTriggerState();
}

class _SecretDevMenuTriggerState extends State<SecretDevMenuTrigger> {
  int _tapCount = 0;
  Timer? _tapTimer;

  void _handleTap() {
    _tapCount++;
    _tapTimer?.cancel();

    if (_tapCount >= 5) {
      _tapCount = 0;
      _showDeveloperMenu(context);
    } else {
      _tapTimer = Timer(const Duration(milliseconds: 500), () {
        _tapCount = 0;
      });
    }
  }

  void _showDeveloperMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.charcoal,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          border: Border.all(color: AppColors.stone.withOpacity(0.2)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'K2 DEVELOPER MODE',
              textAlign: TextAlign.center,
              style: GoogleFonts.oswald(
                color: AppColors.snow,
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 2.0,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Simulation State',
              style: GoogleFonts.inter(color: AppColors.stone),
            ),
            const SizedBox(height: 12),
            _buildDevButton('🟢 NORMAL', AppColors.green, () {
              widget.onStateChanged(AltitudeState.normal);
              Navigator.pop(context);
            }),
            const SizedBox(height: 8),
            _buildDevButton('🟠 EXHAUSTION', Colors.orangeAccent, () {
              widget.onStateChanged(AltitudeState.exhaustion);
              Navigator.pop(context);
            }),
            const SizedBox(height: 8),
            _buildDevButton('🔴 HYPOXIA', AppColors.red, () {
              widget.onStateChanged(AltitudeState.hypoxia);
              Navigator.pop(context);
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildDevButton(String label, Color color, VoidCallback onTap) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withOpacity(0.5)),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      ),
      onPressed: onTap,
      child: Text(
        label,
        style: GoogleFonts.oswald(fontWeight: FontWeight.bold, fontSize: 16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: widget.child,
    );
  }
}

class ReactiveSafetyBanner extends StatelessWidget {
  final double spo2;
  const ReactiveSafetyBanner({super.key, required this.spo2});

  @override
  Widget build(BuildContext context) {
    Color bannerColor;
    String title;
    String subtitle;
    IconData icon;

    if (spo2 >= 95) {
      bannerColor = AppColors.green;
      title = 'DEMO DATA · NORMAL RANGE';
      subtitle =
          'Simulated values, not a real measurement. Do not use this to judge how you are.';
      icon = Icons.science_outlined;
    } else if (spo2 >= 85) {
      bannerColor = Colors.orangeAccent;
      title = 'DEMO DATA · LOW RANGE';
      subtitle = 'Simulated values, not a real measurement.';
      icon = Icons.science_outlined;
    } else {
      bannerColor = AppColors.red;
      title = 'DEMO DATA · CRITICAL RANGE';
      subtitle = 'Simulated values, not a real measurement.';
      icon = Icons.science_outlined;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bannerColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: bannerColor.withOpacity(0.5), width: 2),
      ),
      child: Row(
        children: [
          Icon(icon, color: bannerColor, size: 32),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.oswald(
                    color: bannerColor,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(color: AppColors.snow, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class LiveVitalsScreen extends StatefulWidget {
  final MockVitalsRepository vitalsRepo;
  const LiveVitalsScreen({super.key, required this.vitalsRepo});

  @override
  State<LiveVitalsScreen> createState() => _LiveVitalsScreenState();
}

class _LiveVitalsScreenState extends State<LiveVitalsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      appBar: AppBar(
        title: Text(
          'LIVE VITALS',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        backgroundColor: Colors.transparent,
      ),
      body: StreamBuilder<Map<String, double>>(
        stream: widget.vitalsRepo.vitalsStream,
        builder: (context, snapshot) {
          final data =
              snapshot.data ?? {'hr': 65.0, 'brpm': 14.0, 'spo2': 97.0};
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                ),
                onPressed: () async {
                  int hr = data['hr']?.toInt() ?? 70;
                  int spo2 = data['spo2']?.toInt() ?? 95;
                  bool success = await ApiService().logVitals(hr, spo2);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(success ? 'Vitals synced!' : 'Sync failed'),
                    ),
                  );
                },
                icon: const Icon(Icons.cloud_upload, color: AppColors.charcoal),
                label: const Text(
                  'SYNC CURRENT VITALS',
                  style: TextStyle(color: AppColors.charcoal),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ==========================================
// 4. JOURNEY — ONLY REAL, SAVED EXPEDITIONS
// ==========================================
//
// Journey shows treks the user actually saved (via "Descend & Save
// Journey"). It loads from the API first and falls back to the local
// SQLite copy when the server is unreachable. No mock data.

class ExpeditionRecord {
  final String id;
  final String title;
  final String subtitle;
  final String status; // Completed, In Progress, Abandoned
  final double distanceKm;
  final Duration duration;
  final int maxAltitudeM;
  final int elevationGainM;
  final DateTime date;
  final int avgHeartRate;
  final int maxHeartRate;
  final int avgSpo2;
  final int minSpo2;
  final int avgBreathingRate;
  final double waterConsumedLiters;
  final String tempSummary;
  final String windSummary;
  final String conditionsSummary;
  final List<String> campsPlanned;
  final int campsReachedCount;
  final List<latlong.LatLng> routePoints;
  final bool fromServer;

  const ExpeditionRecord({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.distanceKm,
    required this.duration,
    required this.maxAltitudeM,
    required this.elevationGainM,
    required this.date,
    required this.avgHeartRate,
    required this.maxHeartRate,
    required this.avgSpo2,
    required this.minSpo2,
    required this.avgBreathingRate,
    required this.waterConsumedLiters,
    required this.tempSummary,
    required this.windSummary,
    required this.conditionsSummary,
    required this.campsPlanned,
    required this.campsReachedCount,
    required this.routePoints,
    this.fromServer = false,
  });
  // below this --
  factory ExpeditionRecord.fromDb(Map<String, dynamic> m) {
    final start = DateTime.tryParse('${m['start_date']}') ?? DateTime.now();
    final end = DateTime.tryParse('${m['end_date']}') ?? start;
    return ExpeditionRecord(
      id: '${m['id'] ?? start.millisecondsSinceEpoch}',
      title: '${m['trek_name'] ?? 'TREK'}'.toUpperCase(),
      subtitle: 'Saved ${start.day}/${start.month}/${start.year}',
      status: '${m['status'] ?? 'Completed'}',
      distanceKm: (m['distance'] as num?)?.toDouble() ?? 0,
      duration: end.difference(start),
      maxAltitudeM: (m['max_altitude'] as num?)?.toInt() ?? 0,
      elevationGainM: 0,
      date: start,
      avgHeartRate: 0,
      maxHeartRate: 0,
      avgSpo2: 0,
      minSpo2: 0,
      avgBreathingRate: 0,
      waterConsumedLiters: 0,
      tempSummary: '—',
      windSummary: '—',
      conditionsSummary: '—',
      campsPlanned: const ['Base', 'Camp 1', 'Camp 2', 'Summit'],
      campsReachedCount: 0,
      routePoints: const [latlong.LatLng(35.8825, 76.5133)],
    );
  }
  factory ExpeditionRecord.fromApi(Map<String, dynamic> m) {
    final start =
        DateTime.tryParse('${m['start_date'] ?? m['created_at']}')?.toLocal() ??
        DateTime.now();
    final end = DateTime.tryParse('${m['end_date']}')?.toLocal() ?? start;
    const labels = {
      'completed': 'Completed',
      'abandoned': 'Abandoned',
      'in_progress': 'In Progress',
    };
    final status = labels['${m['status']}'] ?? 'Completed';

    return ExpeditionRecord(
      id: '${m['id']}',
      title: '${m['name'] ?? 'TREK'}'.toUpperCase(),
      subtitle: 'Saved ${start.day}/${start.month}/${start.year}',
      status: status,
      distanceKm: (m['total_distance_km'] as num?)?.toDouble() ?? 0,
      duration: end.difference(start),
      maxAltitudeM: (m['max_altitude_m'] as num?)?.toInt() ?? 0,
      elevationGainM: (m['elevation_gain_m'] as num?)?.toInt() ?? 0,
      date: start,
      avgHeartRate: 0,
      maxHeartRate: 0,
      avgSpo2: 0,
      minSpo2: 0,
      avgBreathingRate: 0,
      waterConsumedLiters: 0,
      tempSummary: '—',
      windSummary: '—',
      conditionsSummary: '—',
      campsPlanned: const ['Base', 'Camp 1', 'Camp 2', 'Summit'],
      campsReachedCount: 0,
      routePoints: const [latlong.LatLng(35.8825, 76.5133)],
      fromServer: true,
    );
  }
  String get durationLabel {
    if (duration.inMinutes < 1) return '—';
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60);
    return '${h}h ${m}m';
  }
}

class JourneyHomeScreen extends StatefulWidget {
  const JourneyHomeScreen({super.key});
  @override
  State<JourneyHomeScreen> createState() => _JourneyHomeScreenState();
}

class _JourneyHomeScreenState extends State<JourneyHomeScreen> {
  late Future<List<ExpeditionRecord>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<ExpeditionRecord>> _load() async {
    final fromApi = await ApiService().getMyTreks();
    final List<ExpeditionRecord> list;
    if (fromApi != null) {
      list = fromApi
          .map((m) => ExpeditionRecord.fromApi(Map<String, dynamic>.from(m)))
          .toList();
    } else {
      // Server unreachable: show what is stored on this device.
      final rows = await DatabaseHelper.instance.getTreks();
      list = rows.map((r) => ExpeditionRecord.fromDb(r)).toList();
    }
    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      body: SafeArea(
        child: FutureBuilder<List<ExpeditionRecord>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.gold),
              );
            }
            final records = snap.data ?? [];
            return ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
              children: [
                Text(
                  '🏔️ JOURNEY',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'Where have you been?',
                  style: GoogleFonts.inter(
                    color: AppColors.stone,
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 20),
                if (records.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppColors.cardDark,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.cardBorder),
                    ),
                    child: Text(
                      'No journeys yet. Tap "Descend & Save Journey" on the Expedition tab to record your first one.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        color: AppColors.stone,
                        height: 1.5,
                      ),
                    ),
                  )
                else ...[
                  _aggregate(records),
                  const SizedBox(height: 28),
                  Text(
                    'MY JOURNEYS',
                    style: GoogleFonts.oswald(
                      color: AppColors.stone,
                      fontSize: 12,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...records.map(
                    (r) => Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: JourneyCard(record: r),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _aggregate(List<ExpeditionRecord> all) {
    final dist = all.fold<double>(0, (s, e) => s + e.distanceKm);
    final hours = all
        .fold<Duration>(Duration.zero, (s, e) => s + e.duration)
        .inHours;
    final highest = all.map((e) => e.maxAltitudeM).reduce(max);
    Widget stat(String v, String l) => Column(
      children: [
        Text(
          v,
          style: GoogleFonts.oswald(
            color: AppColors.gold,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(l, style: GoogleFonts.inter(color: AppColors.stone, fontSize: 9)),
      ],
    );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          stat('${all.length}', 'TREKS'),
          stat('${dist.toStringAsFixed(1)} km', 'TOTAL DIST.'),
          stat('${hours}h', 'ON TRAIL'),
          stat('$highest m', 'HIGHEST'),
        ],
      ),
    );
  }
}

class JourneyCard extends StatelessWidget {
  final ExpeditionRecord record;
  const JourneyCard({super.key, required this.record});

  Color get _statusColor {
    switch (record.status) {
      case 'Completed':
        return AppColors.green;
      case 'Abandoned':
        return AppColors.red;
      default:
        return AppColors.gold;
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ExpeditionDetailScreen(record: record),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.cardDark,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    '🏔️ ${record.title}',
                    style: GoogleFonts.oswald(
                      color: AppColors.snow,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _statusColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _statusColor.withOpacity(0.5)),
                  ),
                  child: Text(
                    record.status,
                    style: GoogleFonts.inter(
                      color: _statusColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              record.subtitle,
              style: GoogleFonts.inter(color: AppColors.stone, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.route, size: 14, color: AppColors.stone),
                const SizedBox(width: 6),
                Text(
                  '${record.distanceKm} km',
                  style: GoogleFonts.inter(color: AppColors.snow, fontSize: 13),
                ),
                const SizedBox(width: 16),
                Icon(Icons.timer_outlined, size: 14, color: AppColors.stone),
                const SizedBox(width: 6),
                Text(
                  record.durationLabel,
                  style: GoogleFonts.inter(color: AppColors.snow, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.terrain, size: 14, color: AppColors.stone),
                const SizedBox(width: 6),
                Text(
                  'Max altitude: ${record.maxAltitudeM}m',
                  style: GoogleFonts.inter(
                    color: AppColors.stone,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  'VIEW EXPEDITION',
                  style: GoogleFonts.oswald(
                    color: AppColors.gold,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.arrow_forward,
                  size: 14,
                  color: AppColors.gold,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ExpeditionDetailScreen extends StatelessWidget {
  final ExpeditionRecord record;
  const ExpeditionDetailScreen({super.key, required this.record});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      appBar: AppBar(
        title: Text(
          '🗺️ EXPEDITION DETAILS',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.map_outlined, color: AppColors.snow),
            tooltip: 'Open route on map',
            onPressed: () => openRecordRoute(context, record),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
        children: [
          Text(
            record.title,
            style: GoogleFonts.oswald(
              color: AppColors.snow,
              fontSize: 26,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            record.subtitle,
            style: GoogleFonts.inter(color: AppColors.stone, fontSize: 13),
          ),
          const SizedBox(height: 20),
          _buildMiniRouteMap(context),
          const SizedBox(height: 24),
          _buildRouteStages(),
          const SizedBox(height: 32),
          Row(
            children: [
              Expanded(
                child: _bigStat(
                  record.distanceKm.toString() + ' km',
                  'DISTANCE',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: _bigStat(record.durationLabel, 'DURATION')),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _bigStat('${record.maxAltitudeM} m', 'MAX ALTITUDE'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _bigStat(
                  '+${record.elevationGainM} m',
                  'ELEVATION GAIN',
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
          if (record.avgHeartRate > 0) ...[
            _sectionCard(
              title: 'HEART RATE',
              icon: Icons.favorite,
              color: AppColors.red,
              rows: [
                _kv('Average', '${record.avgHeartRate} BPM'),
                _kv('Maximum', '${record.maxHeartRate} BPM'),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (record.avgSpo2 > 0) ...[
            _sectionCard(
              title: 'VITALS',
              icon: Icons.monitor_heart_outlined,
              color: AppColors.skyBlue,
              rows: [
                _kv('SpO₂ average', '${record.avgSpo2}%'),
                _kv('SpO₂ lowest', '${record.minSpo2}%'),
                _kv('Breathing average', '${record.avgBreathingRate} RPM'),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (record.waterConsumedLiters > 0) ...[
            _sectionCard(
              title: 'WATER',
              icon: Icons.water_drop_outlined,
              color: AppColors.skyBlue,
              rows: [
                _kv(
                  'Total consumed',
                  '${record.waterConsumedLiters.toStringAsFixed(1)} L',
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (record.tempSummary != '—') ...[
            _sectionCard(
              title: 'WEATHER',
              icon: Icons.cloud_outlined,
              color: AppColors.gold,
              rows: [
                _kv('Temperature', record.tempSummary),
                _kv('Wind', record.windSummary),
                _kv('Conditions', record.conditionsSummary),
              ],
            ),
            const SizedBox(height: 16),
          ],
          _campsReachedCard(),
        ],
      ),
    );
  }

  Widget _buildMiniRouteMap(BuildContext context) {
    return GestureDetector(
      onTap: () => openRecordRoute(context, record),
      child: Container(
        height: 160,
        decoration: BoxDecoration(
          color: AppColors.forest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white10),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              Icons.terrain,
              size: 56,
              color: AppColors.stone.withOpacity(0.4),
            ),
            Positioned(
              bottom: 12,
              right: 12,
              child: Row(
                children: const [
                  Icon(Icons.map, size: 14, color: AppColors.gold),
                  SizedBox(width: 4),
                  Text(
                    'OPEN ROUTE MAP',
                    style: TextStyle(
                      color: AppColors.gold,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRouteStages() {
    final stages = record.campsPlanned;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(stages.length * 2 - 1, (i) {
        if (i.isOdd) {
          final segmentIndex = (i - 1) ~/ 2;
          bool reached = segmentIndex < record.campsReachedCount - 1;
          return Expanded(
            child: Container(
              margin: const EdgeInsets.only(top: 8),
              height: 1,
              color: reached
                  ? AppColors.stone
                  : AppColors.stone.withOpacity(0.2),
            ),
          );
        }
        final stageIndex = i ~/ 2;
        bool reached = stageIndex < record.campsReachedCount;
        return Column(
          children: [
            Icon(
              reached ? Icons.check_circle : Icons.circle_outlined,
              size: 16,
              color: reached
                  ? AppColors.gold
                  : AppColors.stone.withOpacity(0.4),
            ),
            const SizedBox(height: 6),
            Text(
              stages[stageIndex].toUpperCase(),
              style: GoogleFonts.inter(
                fontSize: 10,
                color: reached ? AppColors.snow : AppColors.stone,
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _bigStat(String value, String label) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: GoogleFonts.oswald(
              color: AppColors.snow,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: GoogleFonts.inter(
              color: AppColors.stone,
              fontSize: 10,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required IconData icon,
    required Color color,
    required List<Widget> rows,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text(
                title,
                style: GoogleFonts.oswald(
                  color: AppColors.snow,
                  fontSize: 13,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...rows,
        ],
      ),
    );
  }

  Widget _kv(String key, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            key,
            style: GoogleFonts.inter(color: AppColors.stone, fontSize: 12),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: GoogleFonts.inter(
                color: AppColors.snow,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _campsReachedCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CAMPS REACHED',
            style: GoogleFonts.oswald(
              color: AppColors.snow,
              fontSize: 13,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 12),
          ...List.generate(record.campsPlanned.length, (i) {
            bool reached = i < record.campsReachedCount;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                children: [
                  Icon(
                    reached ? Icons.check : Icons.circle_outlined,
                    size: 16,
                    color: reached ? AppColors.green : AppColors.stone,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    record.campsPlanned[i],
                    style: GoogleFonts.inter(
                      color: reached ? AppColors.snow : AppColors.stone,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ==========================================
// 5. MINDSET — STRESS CHECK, AUDIO, VIDEOS, STORIES
// ==========================================

enum StressLevel { calm, good, neutral, stressed, overwhelmed }

extension StressLevelX on StressLevel {
  String get emoji {
    switch (this) {
      case StressLevel.calm:
        return '😌';
      case StressLevel.good:
        return '🙂';
      case StressLevel.neutral:
        return '😐';
      case StressLevel.stressed:
        return '😟';
      case StressLevel.overwhelmed:
        return '😰';
    }
  }

  String get label {
    switch (this) {
      case StressLevel.calm:
        return 'Calm';
      case StressLevel.good:
        return 'Good';
      case StressLevel.neutral:
        return 'Neutral';
      case StressLevel.stressed:
        return 'Stressed';
      case StressLevel.overwhelmed:
        return 'Overwhelmed';
    }
  }

  String get resultLabel {
    switch (this) {
      case StressLevel.calm:
        return 'LOW';
      case StressLevel.good:
        return 'LOW';
      case StressLevel.neutral:
        return 'MODERATE';
      case StressLevel.stressed:
        return 'ELEVATED';
      case StressLevel.overwhelmed:
        return 'HIGH';
    }
  }

  Color get color {
    switch (this) {
      case StressLevel.calm:
      case StressLevel.good:
        return AppColors.green;
      case StressLevel.neutral:
        return AppColors.gold;
      case StressLevel.stressed:
        return Colors.orangeAccent;
      case StressLevel.overwhelmed:
        return AppColors.red;
    }
  }

  List<String> get suggestions {
    switch (this) {
      case StressLevel.calm:
      case StressLevel.good:
        return [
          'Keep the pace you\'re at',
          'Log today\'s conditions in your journal',
          'Listen to a motivation track before your next stage',
        ];
      case StressLevel.neutral:
        return [
          '5-minute breathing exercise',
          'Take a short rest',
          'Listen to guided meditation',
          'Write in your journal',
        ];
      case StressLevel.stressed:
        return [
          '5-minute breathing exercise',
          'Slow your pace and rest at the next safe point',
          'Listen to a stress-relief audio track',
          'Talk to a teammate or your emergency contact',
        ];
      case StressLevel.overwhelmed:
        return [
          'Stop and rest immediately at a safe location',
          'Use the 4-7-8 breathing exercise',
          'Consider turning back or waiting for support',
          'Let your emergency contact know how you\'re feeling',
        ];
    }
  }
}

class MindsetHomeScreen extends StatelessWidget {
  const MindsetHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
          children: [
            Text('🧠 MINDSET', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'How are you, mentally?',
              style: GoogleFonts.inter(
                color: AppColors.stone,
                fontSize: 14,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 24),
            _MindsetEntryCard(
              emoji: '🧭',
              title: 'STRESS CHECK',
              subtitle: 'A quick, honest check-in on how you\'re feeling',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const StressCheckScreen()),
              ),
            ),
            const SizedBox(height: 16),
            _MindsetEntryCard(
              emoji: '🎧',
              title: 'GUIDED AUDIO',
              subtitle:
                  'Breathing, meditation, sleep, pre-climb focus, stress relief, motivation',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GuidedAudioScreen()),
              ),
            ),
            const SizedBox(height: 16),
            _MindsetEntryCard(
              emoji: '🎥',
              title: 'MEDITATION',
              subtitle: 'Short guided videos to reset and refocus',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const MeditationVideosScreen(),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _MindsetEntryCard(
              emoji: '🏔️',
              title: 'VOICES FROM THE MOUNTAINS',
              subtitle: 'Trekker stories and lessons from real expeditions',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TrekkerStoriesScreen()),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.3),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline,
                    color: AppColors.stone,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'This is a wellness check-in, not a medical diagnosis. '
                      'If you\'re struggling, talk to a real person too.',
                      style: GoogleFonts.inter(
                        color: AppColors.stone,
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MindsetEntryCard extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MindsetEntryCard({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.cardDark,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.oswald(
                      color: AppColors.snow,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      color: AppColors.stone,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios,
              size: 14,
              color: AppColors.gold,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------- STRESS CHECK ----------------

class StressQuestion {
  final String text;
  const StressQuestion(this.text);
}

const List<StressQuestion> _stressQuestions = [
  StressQuestion(
    'How much have worry or racing thoughts about the climb affected your focus today?',
  ),
  StressQuestion('How hard has it been to relax, rest or sleep?'),
  StressQuestion(
    'How tense or irritable have you felt with your teammates or yourself?',
  ),
  StressQuestion(
    'How much have you felt that the conditions or demands are more than you can handle?',
  ),
  StressQuestion(
    'How often have you noticed a racing heartbeat, tight chest or fast breathing while resting?',
  ),
  StressQuestion('Have you had a headache, nausea or dizziness?'),
];

const List<String> _stressAnswerLabels = [
  'Not at all',
  'A little',
  'Quite a bit',
  'Very much',
];

class StressCheckScreen extends StatefulWidget {
  const StressCheckScreen({super.key});
  @override
  State<StressCheckScreen> createState() => _StressCheckScreenState();
}

class _StressCheckScreenState extends State<StressCheckScreen> {
  int _index = 0;
  bool _done = false;
  final List<int?> _answers = List<int?>.filled(_stressQuestions.length, null);
  final List<Map<String, dynamic>> _history = [];

  int get _score => _answers.fold<int>(0, (s, a) => s + (a ?? 0));
  int get _maxScore => _stressQuestions.length * 3;

  StressLevel get _level {
    final pct = _score / _maxScore;
    if (pct < 0.15) return StressLevel.calm;
    if (pct < 0.30) return StressLevel.good;
    if (pct < 0.50) return StressLevel.neutral;
    if (pct < 0.70) return StressLevel.stressed;
    return StressLevel.overwhelmed;
  }

  // Headache / nausea / dizziness, or strong physical symptoms at rest,
  // overlap with altitude sickness, so we flag it separately.
  bool get _altitudeFlag => (_answers[5] ?? 0) >= 2 || (_answers[4] ?? 0) >= 3;

  void _next() {
    if (_answers[_index] == null) return;
    if (_index < _stressQuestions.length - 1) {
      setState(() => _index++);
    } else {
      setState(() {
        _done = true;
        _history.insert(0, {
          'level': _level,
          'score': _score,
          'time': TimeOfDay.now().format(context),
        });
      });
    }
  }

  void _back() {
    if (_index > 0) setState(() => _index--);
  }

  void _restart() {
    setState(() {
      _done = false;
      _index = 0;
      for (int i = 0; i < _answers.length; i++) {
        _answers[i] = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      appBar: AppBar(
        title: Text(
          'STRESS CHECK',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _done ? _buildResult() : _buildQuestion(),
        ),
      ),
    );
  }

  Widget _buildQuestion() {
    final q = _stressQuestions[_index];
    final selected = _answers[_index];
    final isLast = _index == _stressQuestions.length - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'QUESTION ${_index + 1} OF ${_stressQuestions.length}',
          style: GoogleFonts.oswald(
            color: AppColors.stone,
            fontSize: 12,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 10),
        LinearProgressIndicator(
          value: (_index + 1) / _stressQuestions.length,
          backgroundColor: Colors.white10,
          color: AppColors.gold,
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
        ),
        const SizedBox(height: 28),
        Text(
          q.text,
          style: GoogleFonts.inter(
            color: AppColors.snow,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 24),
        ...List.generate(_stressAnswerLabels.length, (i) {
          final isSel = selected == i;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _answers[_index] = i),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: isSel
                      ? AppColors.gold.withOpacity(0.15)
                      : AppColors.cardDark,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSel ? AppColors.gold : AppColors.cardBorder,
                    width: isSel ? 2 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      _stressAnswerLabels[i],
                      style: GoogleFonts.inter(
                        color: AppColors.snow,
                        fontSize: 16,
                        fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    const Spacer(),
                    if (isSel)
                      const Icon(
                        Icons.check_circle,
                        color: AppColors.gold,
                        size: 20,
                      ),
                  ],
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 12),
        Row(
          children: [
            if (_index > 0)
              Expanded(
                child: OutlinedButton(
                  onPressed: _back,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.stone,
                    side: const BorderSide(color: AppColors.cardBorder),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('BACK'),
                ),
              ),
            if (_index > 0) const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                onPressed: selected == null ? null : _next,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  disabledBackgroundColor: AppColors.gold.withOpacity(0.3),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                child: Text(
                  isLast ? 'SEE MY RESULT' : 'NEXT',
                  style: GoogleFonts.oswald(
                    color: AppColors.charcoal,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildResult() {
    final level = _level;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'YOUR CURRENT STATE',
          style: GoogleFonts.oswald(
            color: AppColors.stone,
            fontSize: 12,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: level.color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: level.color.withOpacity(0.5)),
          ),
          child: Row(
            children: [
              Text(level.emoji, style: const TextStyle(fontSize: 36)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Stress level: ${level.resultLabel}',
                      style: GoogleFonts.oswald(
                        color: level.color,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Score $_score of $_maxScore, from your 6 answers',
                      style: GoogleFonts.inter(
                        color: AppColors.stone,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_altitudeFlag) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orangeAccent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orangeAccent.withOpacity(0.6)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.orangeAccent,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Headache, nausea, dizziness or a racing heart at rest can '
                    'also be signs of altitude sickness. Do not go higher while '
                    'symptoms are getting worse. Rest, drink fluids, and descend '
                    'or get medical help if they persist or worsen, or if you '
                    'have confusion, loss of balance or breathlessness at rest.',
                    style: GoogleFonts.inter(
                      color: AppColors.snow,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 28),
        Text(
          'TRY',
          style: GoogleFonts.oswald(
            color: AppColors.stone,
            fontSize: 12,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        ...level.suggestions.map(
          (s) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  ', style: TextStyle(color: AppColors.gold)),
                Expanded(
                  child: Text(
                    s,
                    style: GoogleFonts.inter(
                      color: AppColors.snow,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (level == StressLevel.overwhelmed) ...[
          const SizedBox(height: 4),
          Text(
            'If you feel unsafe or cannot cope, tell a teammate now and contact '
            'your emergency contact or local emergency services.',
            style: GoogleFonts.inter(
              color: AppColors.red,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const BreathingScreen()),
                ),
                icon: const Icon(Icons.air, size: 16),
                label: const Text('BREATHE'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.skyBlue,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const GuidedAudioScreen()),
                ),
                icon: const Icon(Icons.headphones, size: 16),
                label: const Text('AUDIO'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.skyBlue,
                  side: const BorderSide(color: AppColors.skyBlue),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
        if (_history.length > 1) ...[
          const SizedBox(height: 28),
          Text(
            'EARLIER CHECKS THIS SESSION',
            style: GoogleFonts.oswald(
              color: AppColors.stone,
              fontSize: 12,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          ..._history
              .skip(1)
              .map(
                (h) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Text(
                        (h['level'] as StressLevel).emoji,
                        style: const TextStyle(fontSize: 16),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${h['time']}  •  ${(h['level'] as StressLevel).resultLabel}  •  score ${h['score']}',
                        style: GoogleFonts.inter(
                          color: AppColors.stone,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        ],
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.3),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white10),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline, color: AppColors.stone, size: 16),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'This is a wellness check, not a medical diagnosis.',
                  style: GoogleFonts.inter(
                    color: AppColors.stone,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: TextButton(
            onPressed: _restart,
            child: const Text(
              'CHECK AGAIN',
              style: TextStyle(color: AppColors.stone),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------- 4-7-8 BREATHING EXERCISE ----------------

class BreathingScreen extends StatefulWidget {
  const BreathingScreen({super.key});
  @override
  State<BreathingScreen> createState() => _BreathingScreenState();
}

class _BreathingScreenState extends State<BreathingScreen> {
  static const List<String> _names = ['BREATHE IN', 'HOLD', 'BREATHE OUT'];
  static const List<int> _secs = [4, 7, 8];
  static const int _totalCycles = 4;

  Timer? _timer;
  bool _running = false;
  bool _finished = false;
  int _phase = 0;
  int _left = 4;
  int _cycle = 1;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start() {
    _timer?.cancel();
    setState(() {
      _running = true;
      _finished = false;
      _phase = 0;
      _left = _secs[0];
      _cycle = 1;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
  }

  void _stop() {
    _timer?.cancel();
    setState(() {
      _running = false;
      _finished = false;
      _phase = 2;
    });
  }

  void _tick(Timer t) {
    if (!mounted) return;
    setState(() {
      _left--;
      if (_left <= 0) {
        _phase++;
        if (_phase >= 3) {
          _phase = 0;
          _cycle++;
          if (_cycle > _totalCycles) {
            t.cancel();
            _running = false;
            _finished = true;
            _phase = 2;
            return;
          }
        }
        _left = _secs[_phase];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final big = _running && _phase <= 1;
    final size = big ? 230.0 : 130.0;
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      appBar: AppBar(
        title: Text(
          '4-7-8 BREATHING',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                _running
                    ? 'Cycle $_cycle of $_totalCycles'
                    : (_finished
                          ? 'Well done. Notice how you feel.'
                          : 'Breathe in for 4, hold for 7, breathe out for 8.'),
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(color: AppColors.stone, fontSize: 14),
              ),
              Expanded(
                child: Center(
                  child: AnimatedContainer(
                    duration: Duration(seconds: _running ? _secs[_phase] : 1),
                    curve: Curves.easeInOut,
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          AppColors.skyBlue.withOpacity(0.55),
                          AppColors.skyBlue.withOpacity(0.12),
                        ],
                      ),
                      border: Border.all(color: AppColors.skyBlue, width: 2),
                    ),
                    child: Center(
                      child: _running
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _names[_phase],
                                  style: GoogleFonts.oswald(
                                    color: AppColors.snow,
                                    fontSize: 18,
                                    letterSpacing: 2,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  '$_left',
                                  style: GoogleFonts.oswald(
                                    color: AppColors.snow,
                                    fontSize: 40,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            )
                          : Icon(
                              _finished ? Icons.check : Icons.air,
                              color: AppColors.snow,
                              size: 40,
                            ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _running ? _stop : _start,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _running
                        ? AppColors.cardBorder
                        : AppColors.gold,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  child: Text(
                    _running ? 'STOP' : (_finished ? 'BREATHE AGAIN' : 'START'),
                    style: GoogleFonts.oswald(
                      color: _running ? AppColors.snow : AppColors.charcoal,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'If you feel dizzy or light-headed, stop and breathe normally.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: AppColors.stone,
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- GUIDED AUDIO ----------------

class AudioTrack {
  final String title;
  final String description;
  final String assetOrUrl;
  final bool isNetwork;
  const AudioTrack({
    required this.title,
    required this.description,
    required this.assetOrUrl,
    this.isNetwork = true,
  });
}

class AudioCategory {
  final String emoji;
  final String title;
  final List<AudioTrack> tracks;
  const AudioCategory({
    required this.emoji,
    required this.title,
    required this.tracks,
  });
}

class GuidedAudioScreen extends StatefulWidget {
  const GuidedAudioScreen({super.key});
  @override
  State<GuidedAudioScreen> createState() => _GuidedAudioScreenState();
}

class _GuidedAudioScreenState extends State<GuidedAudioScreen> {
  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _watchdog;

  AudioTrack? _current;
  PlayerState _state = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _loading = false;
  bool _dragging = false;
  String? _error;

  // Placeholder royalty-free soundtracks hosted at soundhelix.com. They work
  // today, but they are music, not guided narration. To use your own audio,
  // add files under assets/audio/ (declare them in pubspec.yaml) and set
  // assetOrUrl: 'audio/your_file.mp3', isNetwork: false.
  static const String _base = 'https://www.soundhelix.com/examples/mp3/';
  final List<AudioCategory> _categories = const [
    AudioCategory(
      emoji: '🫁',
      title: 'Breathing',
      tracks: [
        AudioTrack(
          title: '4-7-8 Breathing',
          description: 'Slow, steady pacing',
          assetOrUrl: '${_base}SoundHelix-Song-1.mp3',
        ),
        AudioTrack(
          title: 'Box Breathing for Altitude',
          description: 'Even, calm rhythm',
          assetOrUrl: '${_base}SoundHelix-Song-2.mp3',
        ),
      ],
    ),
    AudioCategory(
      emoji: '🧘',
      title: 'Meditation',
      tracks: [
        AudioTrack(
          title: 'Mountain Breathing',
          description: 'Gentle background track',
          assetOrUrl: '${_base}SoundHelix-Song-3.mp3',
        ),
        AudioTrack(
          title: 'Body Scan at Altitude',
          description: 'Soft, spacious track',
          assetOrUrl: '${_base}SoundHelix-Song-4.mp3',
        ),
      ],
    ),
    AudioCategory(
      emoji: '🌙',
      title: 'Sleep / Rest',
      tracks: [
        AudioTrack(
          title: 'Camp Wind Down',
          description: 'Slow evening track',
          assetOrUrl: '${_base}SoundHelix-Song-5.mp3',
        ),
        AudioTrack(
          title: 'High Camp Sleep Aid',
          description: 'Quiet, steady track',
          assetOrUrl: '${_base}SoundHelix-Song-6.mp3',
        ),
      ],
    ),
    AudioCategory(
      emoji: '🏔️',
      title: 'Pre-Climb Focus',
      tracks: [
        AudioTrack(
          title: 'Before First Light',
          description: 'Focused, building track',
          assetOrUrl: '${_base}SoundHelix-Song-7.mp3',
        ),
      ],
    ),
    AudioCategory(
      emoji: '😰',
      title: 'Stress Relief',
      tracks: [
        AudioTrack(
          title: 'Calm the Storm',
          description: 'Soothing track',
          assetOrUrl: '${_base}SoundHelix-Song-8.mp3',
        ),
      ],
    ),
    AudioCategory(
      emoji: '🔥',
      title: 'Motivation',
      tracks: [
        AudioTrack(
          title: 'One More Step',
          description: 'Upbeat, driving track',
          assetOrUrl: '${_base}SoundHelix-Song-9.mp3',
        ),
      ],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _subs.add(
      _player.onPlayerStateChanged.listen((s) {
        if (!mounted) return;
        setState(() {
          _state = s;
          if (s == PlayerState.playing) {
            _loading = false;
            _watchdog?.cancel();
          }
        });
      }),
    );
    _subs.add(
      _player.onPositionChanged.listen((p) {
        if (mounted && !_dragging) setState(() => _position = p);
      }),
    );
    _subs.add(
      _player.onDurationChanged.listen((d) {
        if (mounted) setState(() => _duration = d);
      }),
    );
    _subs.add(
      _player.onPlayerComplete.listen((_) {
        if (!mounted) return;
        setState(() {
          _position = Duration.zero;
          _state = PlayerState.completed;
        });
      }),
    );
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player.stop();
    _player.dispose();
    super.dispose();
  }

  Future<void> _startTrack(AudioTrack track) async {
    _watchdog?.cancel();
    setState(() {
      _current = track;
      _loading = true;
      _error = null;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    try {
      await _player.stop();
      await _player.play(
        track.isNetwork
            ? UrlSource(track.assetOrUrl)
            : AssetSource(track.assetOrUrl),
      );
      _watchdog = Timer(const Duration(seconds: 20), () {
        if (mounted && _loading) {
          _player.stop();
          setState(() {
            _loading = false;
            _error =
                'Could not start "${track.title}". Check your internet connection and try again.';
          });
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not play "${track.title}": $e';
      });
    }
  }

  Future<void> _onTrackTap(AudioTrack track) async {
    final same = _current?.title == track.title && _error == null;
    if (!same) {
      await _startTrack(track);
      return;
    }
    if (_state == PlayerState.playing) {
      await _pause();
    } else if (_state == PlayerState.paused) {
      await _resume();
    } else {
      await _startTrack(track);
    }
  }

  Future<void> _pause() async {
    try {
      await _player.pause();
    } catch (_) {}
  }

  Future<void> _resume() async {
    try {
      await _player.resume();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not resume: $e');
    }
  }

  Future<void> _stopPlayback() async {
    _watchdog?.cancel();
    try {
      await _player.stop();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _current = null;
      _loading = false;
      _error = null;
      _position = Duration.zero;
      _duration = Duration.zero;
      _state = PlayerState.stopped;
    });
  }

  Future<void> _seekBy(int seconds) async {
    if (_duration == Duration.zero) return;
    var ms = _position.inMilliseconds + seconds * 1000;
    ms = ms.clamp(0, _duration.inMilliseconds).toInt();
    try {
      await _player.seek(Duration(milliseconds: ms));
    } catch (_) {}
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  Widget _nowPlayingBar() {
    final t = _current;
    if (t == null) return const SizedBox.shrink();
    final maxMs = max(_duration.inMilliseconds, 1).toDouble();
    final posMs = _position.inMilliseconds.clamp(0, maxMs.toInt()).toDouble();
    final playing = _state == PlayerState.playing;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        color: AppColors.cardDark,
        border: Border(top: BorderSide(color: AppColors.cardBorder)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      color: AppColors.snow,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close player',
                  icon: const Icon(Icons.close, color: AppColors.stone),
                  onPressed: _stopPlayback,
                ),
              ],
            ),
            if (_error != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.red.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.red.withOpacity(0.5)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _error!,
                        style: GoogleFonts.inter(
                          color: AppColors.snow,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _startTrack(t),
                      child: const Text(
                        'RETRY',
                        style: TextStyle(color: AppColors.gold),
                      ),
                    ),
                  ],
                ),
              ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: AppColors.gold,
                inactiveTrackColor: Colors.white12,
                thumbColor: AppColors.gold,
              ),
              child: Slider(
                min: 0,
                max: maxMs,
                value: posMs,
                onChangeStart: _duration == Duration.zero
                    ? null
                    : (_) => _dragging = true,
                onChanged: _duration == Duration.zero
                    ? null
                    : (v) => setState(
                        () => _position = Duration(milliseconds: v.round()),
                      ),
                onChangeEnd: _duration == Duration.zero
                    ? null
                    : (v) async {
                        _dragging = false;
                        try {
                          await _player.seek(Duration(milliseconds: v.round()));
                        } catch (_) {}
                      },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _fmt(_position),
                    style: GoogleFonts.inter(
                      color: AppColors.stone,
                      fontSize: 11,
                    ),
                  ),
                  Text(
                    _duration == Duration.zero ? '--:--' : _fmt(_duration),
                    style: GoogleFonts.inter(
                      color: AppColors.stone,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Back 10 seconds',
                  icon: const Icon(Icons.replay_10, color: AppColors.snow),
                  onPressed: () => _seekBy(-10),
                ),
                const SizedBox(width: 8),
                _loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: AppColors.gold,
                          ),
                        ),
                      )
                    : IconButton(
                        tooltip: playing ? 'Pause' : 'Play',
                        iconSize: 48,
                        icon: Icon(
                          playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: AppColors.gold,
                        ),
                        onPressed: () => _onTrackTap(t),
                      ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Forward 10 seconds',
                  icon: const Icon(Icons.forward_10, color: AppColors.snow),
                  onPressed: () => _seekBy(10),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      appBar: AppBar(
        title: Text(
          'GUIDED AUDIO',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        backgroundColor: Colors.transparent,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(24),
              itemCount: _categories.length + 1,
              itemBuilder: (context, catIndex) {
                if (catIndex == 0) {
                  return Container(
                    margin: const EdgeInsets.only(bottom: 24),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.info_outline,
                          color: AppColors.stone,
                          size: 16,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'These are placeholder relaxation soundtracks streamed '
                            'over the internet. Swap in your own guided recordings '
                            'in the track list.',
                            style: GoogleFonts.inter(
                              color: AppColors.stone,
                              fontSize: 11,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                final cat = _categories[catIndex - 1];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(cat.emoji, style: const TextStyle(fontSize: 20)),
                          const SizedBox(width: 8),
                          Text(
                            cat.title.toUpperCase(),
                            style: GoogleFonts.oswald(
                              color: AppColors.snow,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ...cat.tracks.map((track) {
                        final isCurrent = _current?.title == track.title;
                        final isPlaying =
                            isCurrent && _state == PlayerState.playing;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => _onTrackTap(track),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: isCurrent
                                    ? AppColors.skyBlue.withOpacity(0.12)
                                    : AppColors.cardDark,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isCurrent
                                      ? AppColors.skyBlue
                                      : AppColors.cardBorder,
                                ),
                              ),
                              child: Row(
                                children: [
                                  isCurrent && _loading
                                      ? const SizedBox(
                                          width: 28,
                                          height: 28,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 3,
                                            color: AppColors.gold,
                                          ),
                                        )
                                      : Icon(
                                          isPlaying
                                              ? Icons.pause_circle_filled
                                              : Icons.play_circle_filled,
                                          color: AppColors.gold,
                                          size: 32,
                                        ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          track.title,
                                          style: GoogleFonts.inter(
                                            color: AppColors.snow,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          track.description,
                                          style: GoogleFonts.inter(
                                            color: AppColors.stone,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                );
              },
            ),
          ),
          _nowPlayingBar(),
        ],
      ),
    );
  }
}

class MeditationVideo {
  final String title;
  final String lengthLabel;
  final String description;
  final String? asset;
  const MeditationVideo({
    required this.title,
    required this.lengthLabel,
    required this.description,
    this.asset,
  });
}

class MeditationVideosScreen extends StatelessWidget {
  const MeditationVideosScreen({super.key});

  static const List<MeditationVideo> _videos = [
    MeditationVideo(
      title: 'Mountain Breathing',
      lengthLabel: '5 MIN',
      description: 'A short breath-led reset you can do at any camp.',
    ),
    MeditationVideo(
      title: 'Calm Before the Climb',
      lengthLabel: '10 MIN',
      description: 'Settle your mind before a summit push.',
    ),
    MeditationVideo(
      title: 'Focus & Presence',
      lengthLabel: '8 MIN',
      description: 'Refocus attention on the next step, not the whole climb.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      appBar: AppBar(
        title: Text(
          'MEDITATION',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: ListView.builder(
          padding: const EdgeInsets.all(24),
          itemCount: _videos.length,
          itemBuilder: (context, index) {
            final v = _videos[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  if (v.asset == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('This video has not been added yet.'),
                        backgroundColor: AppColors.forest,
                      ),
                    );
                    return;
                  }
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          VideoPlayerScreen(title: v.title, asset: v.asset),
                    ),
                  );
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.cardDark,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 140,
                        decoration: const BoxDecoration(
                          color: AppColors.forest,
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(8),
                          ),
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.play_circle_fill,
                            size: 48,
                            color: AppColors.stone,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Text(
                                  '▶ ',
                                  style: TextStyle(color: AppColors.gold),
                                ),
                                Text(
                                  '${v.lengthLabel} — ${v.title}',
                                  style: GoogleFonts.oswald(
                                    color: AppColors.snow,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              v.description,
                              style: GoogleFonts.inter(
                                color: AppColors.stone,
                                fontSize: 12,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class TrekkerStory {
  final String title;
  final String quote;
  final String category;
  const TrekkerStory({
    required this.title,
    required this.quote,
    required this.category,
  });
}

class TrekkerStoriesScreen extends StatelessWidget {
  const TrekkerStoriesScreen({super.key});

  static const TrekkerStory featured = TrekkerStory(
    title: 'Respect the Mountain',
    quote: '"Respect the mountain. Respect your limits."',
    category: 'Featured Trekker',
  );

  static const List<TrekkerStory> more = [
    TrekkerStory(
      title: 'Expedition Preparation',
      quote: 'What months of planning look like before day one.',
      category: 'Preparation',
    ),
    TrekkerStory(
      title: 'Mountain Survival Stories',
      quote: 'What it takes to make it through a whiteout.',
      category: 'Survival',
    ),
    TrekkerStory(
      title: 'Mental Resilience',
      quote: 'How trekkers keep going when the body wants to stop.',
      category: 'Mindset',
    ),
    TrekkerStory(
      title: 'Trekker Experiences',
      quote: 'First-hand accounts from the trail.',
      category: 'Experience',
    ),
    TrekkerStory(
      title: 'Lessons From Failed Climbs',
      quote: 'What turning back can teach you.',
      category: 'Lessons',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      appBar: AppBar(
        title: Text(
          'VOICES FROM THE MOUNTAINS',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'FEATURED TREKKER',
              style: GoogleFonts.oswald(
                color: AppColors.stone,
                fontSize: 12,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Playing "${featured.title}"...'),
                    backgroundColor: AppColors.forest,
                  ),
                );
              },
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.forest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  children: [
                    Container(
                      height: 180,
                      decoration: const BoxDecoration(
                        color: AppColors.cardDark,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(8),
                        ),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.play_circle_fill,
                          size: 56,
                          color: AppColors.gold,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            featured.quote,
                            style: GoogleFonts.inter(
                              color: AppColors.snow,
                              fontSize: 15,
                              fontStyle: FontStyle.italic,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: const [
                              Icon(
                                Icons.play_arrow,
                                size: 16,
                                color: AppColors.gold,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'WATCH',
                                style: TextStyle(
                                  color: AppColors.gold,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'MORE FROM THE MOUNTAINS',
              style: GoogleFonts.oswald(
                color: AppColors.stone,
                fontSize: 12,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            ...more.map(
              (story) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Playing "${story.title}"...'),
                        backgroundColor: AppColors.forest,
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.cardDark,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.cardBorder),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.videocam_outlined,
                          color: AppColors.gold,
                          size: 22,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                story.title,
                                style: GoogleFonts.inter(
                                  color: AppColors.snow,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                              Text(
                                story.quote,
                                style: GoogleFonts.inter(
                                  color: AppColors.stone,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 6. SOS / EMERGENCY HUB — WITH SAFE AUTO-DETECTION (REAL WEATHER)
// ==========================================
//
// Automatic detection asks the trekker to confirm they're OK before
// anything escalates, which guards against sensor noise, false
// alarms, and connectivity gaps rather than firing on a single
// abnormal reading. Weather now comes from the same live feed as
// the Dashboard.

enum HubStatus { monitoring, checking, alerted }

class MountainWeatherSnapshot {
  final double tempC;
  final double windKmh;
  final String avalancheRisk;

  const MountainWeatherSnapshot({
    required this.tempC,
    required this.windKmh,
    required this.avalancheRisk,
  });

  // Fallback used until the live weather feed responds.
  static const current = MountainWeatherSnapshot(
    tempC: -8,
    windKmh: 24,
    avalancheRisk: 'HIGH',
  );

  bool get isSevere =>
      tempC <= -5 ||
      windKmh >= 20 ||
      avalancheRisk == 'HIGH' ||
      avalancheRisk == 'CONSIDERABLE';

  String get summary =>
      '$tempC°C • $windKmh km/h wind • $avalancheRisk avalanche risk';
}

class HelpStation {
  final String name;
  final String kind;
  final String source;
  final String status; // 'verified' | 'unverified'
  final double? distanceKm; // straight-line, not route distance
  final String? phone;
  final String? radioChannel;
  final DateTime? lastVerified;

  const HelpStation({
    required this.name,
    required this.kind,
    required this.source,
    required this.status,
    this.distanceKm,
    this.phone,
    this.radioChannel,
    this.lastVerified,
  });

  bool get verified => status == 'verified';

  factory HelpStation.fromJson(Map<String, dynamic> j) => HelpStation(
    name: '${j['name']}',
    kind: '${j['kind']}',
    source: '${j['source']}',
    status: '${j['verification_status']}',
    distanceKm: (j['distance_km'] as num?)?.toDouble(),
    phone: j['phone']?.toString(),
    radioChannel: j['radio_channel']?.toString(),
    lastVerified: DateTime.tryParse('${j['last_verified']}'),
  );
}

class EmergencyHubScreen extends StatefulWidget {
  final String userName;
  final String emergencyPhone;
  final String bloodType;
  final String healthCondition;
  final String allergies;

  const EmergencyHubScreen({
    super.key,
    required this.userName,
    required this.emergencyPhone,
    required this.bloodType,
    required this.healthCondition,
    required this.allergies,
  });

  @override
  State<EmergencyHubScreen> createState() => _EmergencyHubScreenState();
}

// below this ---
class _EmergencyHubScreenState extends State<EmergencyHubScreen> {
  late MockVitalsRepository _vitalsRepo;
  HubStatus _status = HubStatus.monitoring;
  Timer? _confirmWindowTimer;
  int _confirmSecondsLeft = 30;
  StreamSubscription<Map<String, double>>? _sub;

  int _consecutiveAbnormalReadings = 0;
  static const int _abnormalReadingsThreshold = 4;

  MountainWeatherSnapshot _weather = MountainWeatherSnapshot.current;
  bool _alertSent = false;
  List<HelpStation>? _stations; // null = not loaded or server unreachable
  List<Map<String, dynamic>>? _contacts;
  bool _stationsLoading = true;

  SosResult? _sosResult;
  bool _sosBusy = false;
  double? _sosLat, _sosLon;

  Map<String, double> _lastVitals = {'hr': 65.0, 'brpm': 14.0, 'spo2': 97.0};

  @override
  void initState() {
    super.initState();
    _vitalsRepo = MockVitalsRepository();
    _loadStations();
    _loadContacts();
    _sub = _vitalsRepo.vitalsStream.listen(_onVitals);

    WeatherService.fetchCurrent()
        .then((w) {
          if (!mounted) return;
          setState(
            () => _weather = MountainWeatherSnapshot(
              tempC: w.tempC,
              windKmh: w.windKmh,
              avalancheRisk: w.avalanche.label,
            ),
          );
        })
        .catchError((_) {});

    // Retry any SOS alerts that were queued while offline.
    ApiService().flushQueuedSos();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _confirmWindowTimer?.cancel();
    _vitalsRepo.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    final rows = await ApiService().getContacts();
    if (!mounted) return;
    setState(() => _contacts = rows);
    if (rows != null) {
      final primary = rows.where((c) => c['is_primary'] == true).toList();
      primaryContactPhone.value = primary.isNotEmpty
          ? '${primary.first['phone_number']}'
          : (rows.isNotEmpty ? '${rows.first['phone_number']}' : '');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.forest),
    );
  }

  Future<void> _call(String phone) async {
    final ok = await launchUrl(Uri(scheme: 'tel', path: phone));
    if (!ok) _snack('Could not open the phone app.');
  }

  Future<void> _addContactDialog() async {
    final name = TextEditingController();
    final phone = TextEditingController(text: '+');
    final rel = TextEditingController();
    InputDecoration dec(String l) => InputDecoration(
      labelText: l,
      labelStyle: const TextStyle(color: AppColors.stone),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.charcoal,
        title: Text(
          'ADD EMERGENCY CONTACT',
          style: GoogleFonts.oswald(
            color: AppColors.snow,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                style: const TextStyle(color: AppColors.snow),
                decoration: dec('Name'),
              ),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: AppColors.snow),
                decoration: dec('Phone with country code (+91…)'),
              ),
              TextField(
                controller: rel,
                style: const TextStyle(color: AppColors.snow),
                decoration: dec('Relationship (optional)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'CANCEL',
              style: TextStyle(color: AppColors.stone),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.gold),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'SAVE',
              style: TextStyle(color: AppColors.charcoal),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (name.text.trim().isEmpty) {
      _snack('Enter a name.');
      return;
    }
    final err = await ApiService().addContact(
      name.text.trim(),
      phone.text.trim(),
      relationship: rel.text.trim().isEmpty ? 'Emergency' : rel.text.trim(),
    );
    _snack(err ?? 'Contact saved.');
  }

  void _openContacts() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.charcoal,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final list = _contacts;
          Future<void> refresh() async {
            await _loadContacts();
            setSheet(() {});
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              24,
              24,
              24 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'EMERGENCY CONTACTS',
                  style: Theme.of(ctx).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  'SOS texts the PRIMARY contact.',
                  style: GoogleFonts.inter(
                    color: AppColors.stone,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                if (list == null)
                  Text(
                    'Could not load contacts (server unreachable).',
                    style: GoogleFonts.inter(color: Colors.orangeAccent),
                  )
                else if (list.isEmpty)
                  Text(
                    'No contacts yet.',
                    style: GoogleFonts.inter(color: AppColors.stone),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final c in list)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              '${c['name']}${c['is_primary'] == true ? '  (PRIMARY)' : ''}',
                              style: GoogleFonts.inter(
                                color: AppColors.snow,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              '${c['phone_number']}  •  ${c['relationship'] ?? ''}',
                              style: GoogleFonts.inter(
                                color: AppColors.stone,
                                fontSize: 12,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Call',
                                  icon: const Icon(
                                    Icons.call,
                                    color: AppColors.green,
                                  ),
                                  onPressed: () =>
                                      _call('${c['phone_number']}'),
                                ),
                                if (c['is_primary'] != true)
                                  IconButton(
                                    tooltip: 'Make primary',
                                    icon: const Icon(
                                      Icons.star_border,
                                      color: AppColors.gold,
                                    ),
                                    onPressed: () async {
                                      await ApiService().makeContactPrimary(
                                        (c['id'] as num).toInt(),
                                      );
                                      await refresh();
                                    },
                                  ),
                                IconButton(
                                  tooltip: 'Delete',
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: AppColors.stone,
                                  ),
                                  onPressed: () async {
                                    await ApiService().deleteContact(
                                      (c['id'] as num).toInt(),
                                    );
                                    await refresh();
                                  },
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.gold,
                      foregroundColor: Colors.black,
                    ),
                    onPressed: () async {
                      await _addContactDialog();
                      await refresh();
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('ADD CONTACT'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _loadStations() async {
    final tracker = TrekTracker.instance;
    if (tracker.lastPosition == null) await tracker.refreshPosition();
    final p = tracker.lastPosition;
    final rows = await ApiService().getHelpStations(
      lat: p?.latitude,
      lon: p?.longitude,
    );
    if (!mounted) return;
    setState(() {
      _stations = rows?.map(HelpStation.fromJson).toList();
      _stationsLoading = false;
    });
  }

  void _onVitals(Map<String, double> data) {
    if (!mounted) return;
    _lastVitals = data;
    bool abnormal = (data['spo2'] ?? 100) < 85 || (data['hr'] ?? 0) > 130;

    // Auto-escalation only considers vitals when the mountain
    // weather is also bad. Manual SOS is never gated on weather.
    bool conditionForAutoTrigger = abnormal && _weather.isSevere;

    if (conditionForAutoTrigger) {
      _consecutiveAbnormalReadings++;
    } else {
      _consecutiveAbnormalReadings = 0;
      if (_status == HubStatus.monitoring) return;
    }

    if (_status == HubStatus.monitoring &&
        _consecutiveAbnormalReadings >= _abnormalReadingsThreshold) {
      _beginConfirmWindow();
    }
  }

  void _beginConfirmWindow() {
    setState(() {
      _status = HubStatus.checking;
      _confirmSecondsLeft = 30;
    });
    _confirmWindowTimer?.cancel();
    _confirmWindowTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _confirmSecondsLeft--);
      if (_confirmSecondsLeft <= 0) {
        t.cancel();
        _escalateToAlert();
      }
    });
  }

  void _confirmImOk() {
    _confirmWindowTimer?.cancel();
    _consecutiveAbnormalReadings = 0;
    setState(() => _status = HubStatus.monitoring);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Good to hear. Monitoring continues.'),
        backgroundColor: AppColors.forest,
      ),
    );
  }

  void _escalateToAlert() => _dispatchSos('auto');

  void _cancelAlert() {
    // Marks the alert cancelled on the server. It cannot recall an SMS already sent.
    final id = _sosResult?.alertId;
    if (id != null) ApiService().cancelSos(id);
    _consecutiveAbnormalReadings = 0;
    setState(() {
      _status = HubStatus.monitoring;
      _alertSent = false;
      _sosResult = null;
    });
  }

  Future<void> _dispatchSos(String trigger) async {
    setState(() {
      _status = HubStatus.alerted;
      _alertSent = false;
      _sosBusy = true;
      _sosResult = null;
    });
    final tracker = TrekTracker.instance;
    Position? pos = tracker.lastPosition;
    DateTime? ts = pos?.timestamp;
    final fresh =
        pos != null &&
        ts != null &&
        DateTime.now().difference(ts).inMinutes < 2;
    if (!fresh) {
      try {
        if (await tracker.ensurePermission()) {
          pos = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
          ).timeout(const Duration(seconds: 10));
          ts = pos.timestamp;
        }
      } catch (_) {} // keep the last known position, if any
    }
    final res = await ApiService().sendSos(
      latitude: pos?.latitude,
      longitude: pos?.longitude,
      accuracyM: pos?.accuracy,
      locationTime: ts,
      trigger: trigger,
    );
    if (!mounted) return;
    setState(() {
      _sosLat = pos?.latitude;
      _sosLon = pos?.longitude;
      _sosResult = res;
      _sosBusy = false;
      _alertSent = res.smsAccepted;
    });
  }

  String _sosSummary() {
    if (_sosBusy) return 'Sending your alert to the server…';
    final r = _sosResult;
    if (r == null) return 'Preparing alert…';
    final to = r.contactPhone ?? primaryContactPhone.value;
    switch (r.deliveryStatus) {
      case 'accepted':
        return 'Alert recorded. The SMS provider accepted a message to $to. Delivery to the phone is NOT confirmed, so call them if you can.';
      case 'queued':
        return 'No connection. The alert is saved on this phone and will send automatically when you are online. NOBODY HAS BEEN NOTIFIED YET. Call your contact or local emergency services directly.';
      case 'not_configured':
        return 'Alert recorded on the server, but SMS sending is not set up. NOBODY HAS BEEN TEXTED. Call your contact directly.';
      case 'no_contact':
        return 'No emergency contact is saved, so nobody was notified. Add one, and call local emergency services directly.';
      default:
        return 'Alert could not be delivered: ${r.detail ?? 'unknown error'}. Call your contact or local emergency services directly.';
    }
  }

  void _manualSOS() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.charcoal,
        title: Text(
          'SEND SOS?',
          style: GoogleFonts.oswald(
            color: AppColors.red,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'This records an SOS with your current location on the K2 server and '
          'texts your primary emergency contact. You will see exactly what was '
          'and was not delivered.',
          style: GoogleFonts.inter(color: AppColors.stone),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'CANCEL',
              style: TextStyle(color: AppColors.stone),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () {
              Navigator.pop(context);
              _dispatchSos('manual');
            },
            child: const Text('SEND SOS'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Column(
                  children: [
                    const Text('🚨', style: TextStyle(fontSize: 48)),
                    const SizedBox(height: 8),
                    Text(
                      'EMERGENCY HUB',
                      style: GoogleFonts.oswald(
                        color: AppColors.snow,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _buildStatusBanner(),
              const SizedBox(height: 24),
              _buildHealthProfileCard(),
              const SizedBox(height: 32),
              Center(
                child: GestureDetector(
                  onTap: _manualSOS,
                  child: Container(
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.red.withOpacity(0.15),
                      border: Border.all(color: AppColors.red, width: 3),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.warning_rounded,
                            color: AppColors.red,
                            size: 36,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'SOS',
                            style: GoogleFonts.oswald(
                              color: AppColors.red,
                              fontWeight: FontWeight.bold,
                              fontSize: 20,
                              letterSpacing: 2.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              _buildDetectionExplainerCard(),
              const SizedBox(height: 24),
              _buildContactCard(),
              const SizedBox(height: 16),
              _buildHelpStationCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBanner() {
    switch (_status) {
      case HubStatus.monitoring:
        return _statusContainer(
          color: AppColors.green,
          icon: Icons.check_circle_outline,
          title: 'CURRENT STATUS: MONITORING',
          subtitle: _weather.isSevere
              ? 'Vitals normal (simulated demo). Weather is rough (${_weather.summary}) — auto-alert is armed.'
              : 'Vitals normal (simulated demo). Weather is mild — auto-alert is on standby.',
        );
      case HubStatus.checking:
        return _statusContainer(
          color: Colors.orangeAccent,
          icon: Icons.warning_amber_rounded,
          title: '⚠️ LOW VITALS + BAD WEATHER',
          subtitle:
              "Your vitals dipped while conditions are severe (${_weather.summary}). Checking on you...",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              Text(
                'If there is no response in $_confirmSecondsLeft s, an SOS with your '
                'location will be sent to your emergency contact.',
                style: GoogleFonts.inter(color: AppColors.snow, fontSize: 12),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _confirmImOk,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text(
                    "I'M OK",
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      case HubStatus.alerted:
        return _statusContainer(
          color: AppColors.red,
          icon: Icons.emergency,
          title: '🚨 EMERGENCY PROTOCOL ACTIVE',
          subtitle: _sosSummary(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              if (_sosBusy)
                const Center(
                  child: CircularProgressIndicator(color: AppColors.red),
                )
              else
                _buildEmergencyPackage(),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _cancelAlert,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.stone,
                    side: const BorderSide(color: AppColors.stone),
                  ),
                  child: const Text('CANCEL / STAND DOWN'),
                ),
              ),
            ],
          ),
        );
    }
  }

  Widget _statusContainer({
    required Color color,
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? child,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.6), width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.oswald(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: GoogleFonts.inter(color: AppColors.snow, fontSize: 12),
          ),
          if (child != null) child,
        ],
      ),
    );
  }

  Widget _buildHealthProfileCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'HEALTH PROFILE',
            style: GoogleFonts.oswald(
              color: AppColors.snow,
              fontSize: 13,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 12),
          _profileRow('Blood group', widget.bloodType),
          _profileRow('Allergies', widget.allergies),
          _profileRow('Medical conditions', widget.healthCondition),
          _profileRow('Emergency contact', primaryContactPhone.value),
        ],
      ),
    );
  }

  Widget _profileRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        children: [
          const Icon(Icons.check, size: 14, color: AppColors.green),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: GoogleFonts.inter(color: AppColors.stone, fontSize: 12),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? 'Not provided' : value,
              style: GoogleFonts.inter(
                color: AppColors.snow,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetectionExplainerCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'HOW AUTOMATIC DETECTION WORKS',
            style: GoogleFonts.oswald(
              color: AppColors.stone,
              fontSize: 11,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 10),
          _flowStep(
            '1',
            'Vitals are watched continuously (HR, SpO₂, breathing). Currently SIMULATED DEMO data.',
          ),
          _flowStep(
            '2',
            'Mountain weather is checked against the same feed as the Dashboard.',
          ),
          _flowStep(
            '3',
            'Auto-alert only arms when BOTH are true: vitals are low AND weather is severe — not either alone.',
          ),
          _flowStep(
            '4',
            "You're asked to confirm you're OK before anything is sent.",
          ),
          _flowStep(
            '5',
            'No response in time sends an SOS with your location to your emergency contact.',
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: (_weather.isSevere ? AppColors.red : AppColors.green)
                  .withOpacity(0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: (_weather.isSevere ? AppColors.red : AppColors.green)
                    .withOpacity(0.4),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _weather.isSevere
                      ? Icons.cloud_off
                      : Icons.wb_cloudy_outlined,
                  size: 14,
                  color: _weather.isSevere ? AppColors.red : AppColors.green,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Current mountain weather: ${_weather.summary}',
                    style: GoogleFonts.inter(
                      color: AppColors.snow,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Manual SOS below always works, regardless of weather. This guards '
            'against sensor noise, brief false alarms, and connectivity gaps.',
            style: GoogleFonts.inter(
              color: AppColors.stone,
              fontSize: 11,
              fontStyle: FontStyle.italic,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _flowStep(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.gold.withOpacity(0.2),
            ),
            child: Text(
              number,
              style: const TextStyle(
                color: AppColors.gold,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                color: AppColors.snow,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactCard() {
    final phone = primaryContactPhone.value;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.phone_in_talk,
                color: AppColors.skyBlue,
                size: 24,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Primary Emergency Contact',
                      style: GoogleFonts.inter(
                        color: AppColors.stone,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      phone.isEmpty ? 'Not set' : phone,
                      style: GoogleFonts.oswald(
                        color: phone.isEmpty
                            ? Colors.orangeAccent
                            : AppColors.snow,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              if (phone.isNotEmpty)
                IconButton(
                  tooltip: 'Call',
                  icon: const Icon(Icons.call, color: AppColors.green),
                  onPressed: () => _call(phone),
                ),
            ],
          ),
          if (phone.isEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Add an emergency contact. SOS cannot text anyone without one.',
              style: GoogleFonts.inter(
                color: Colors.orangeAccent,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _openContacts,
            icon: const Icon(Icons.people_outline, size: 16),
            label: Text(
              phone.isEmpty ? 'ADD EMERGENCY CONTACT' : 'MANAGE CONTACTS',
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.gold,
              side: const BorderSide(color: AppColors.gold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpStationCard() {
    final small = GoogleFonts.inter(color: AppColors.stone, fontSize: 11);
    Widget body;
    if (_stationsLoading) {
      body = Text('Looking up help stations…', style: small);
    } else if (_stations == null) {
      body = Text(
        'Could not load help stations (server unreachable). Do not assume help is nearby.',
        style: small,
      );
    } else if (_stations!.isEmpty) {
      body = Text(
        'No help stations are on record yet. Do not assume help is nearby.',
        style: small,
      );
    } else {
      final s = _stations!.first;
      final d = s.distanceKm;
      final parts = <String>[
        d == null
            ? 'distance unknown (no GPS fix)'
            : '${d.toStringAsFixed(1)} km straight-line',
        if (s.radioChannel != null && s.radioChannel!.isNotEmpty)
          s.radioChannel!,
        if (s.phone != null && s.phone!.isNotEmpty) s.phone!,
      ];
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.name,
            style: GoogleFonts.oswald(
              color: AppColors.snow,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(parts.join('  •  '), style: small),
          const SizedBox(height: 2),
          Text(
            s.verified
                ? 'VERIFIED${s.lastVerified == null ? '' : ' ${formatDate(s.lastVerified!)}'} • Source: ${s.source}'
                : 'UNVERIFIED • Source: ${s.source}',
            style: GoogleFonts.inter(
              color: s.verified ? AppColors.green : Colors.orangeAccent,
              fontSize: 11,
            ),
          ),
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.local_hospital_outlined,
            color: AppColors.green,
            size: 24,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Nearest Trekker Help Station', style: small),
                const SizedBox(height: 4),
                body,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmergencyPackage() {
    final now = TimeOfDay.now();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.red.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '🚨 K2 EMERGENCY ALERT',
            style: GoogleFonts.oswald(
              color: AppColors.red,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Trekker: ${widget.userName}   •   Time: ${now.format(context)}',
            style: GoogleFonts.inter(color: AppColors.stone, fontSize: 11),
          ),
          const Divider(color: Colors.white10, height: 24),
          _pkgSection('SMS TARGET', [
            '📞 ${_sosResult?.contactPhone ?? primaryContactPhone.value}',
            'Help stations are shown for reference only and are NOT notified.',
          ]),
          _pkgSection('LOCATION', [
            _sosLat == null
                ? 'No GPS fix available'
                : 'Latitude: ${_sosLat!.toStringAsFixed(5)}',
            if (_sosLon != null) 'Longitude: ${_sosLon!.toStringAsFixed(5)}',
            if (_sosResult?.locationLink != null) _sosResult!.locationLink!,
          ]),
          _pkgSection('TRIGGER (SIMULATED DEMO)', [
            'Vitals: ${_lastVitals['spo2']?.toInt()}% SpO₂ • ${_lastVitals['hr']?.toInt()} BPM',
            'Weather: ${_weather.summary}',
          ]),
          _pkgSection('CURRENT VITALS (SIMULATED DEMO)', [
            '❤️ Heart rate: ${_lastVitals['hr']?.toInt()} BPM',
            '🫁 Breathing: ${_lastVitals['brpm']?.toInt()} RPM',
            '🩸 SpO₂: ${_lastVitals['spo2']?.toInt()}%',
          ]),
          _pkgSection('HEALTH INFORMATION', [
            'Blood group: ${widget.bloodType}',
            'Known conditions: ${widget.healthCondition}',
            'Allergies: ${widget.allergies}',
          ]),
          const SizedBox(height: 4),
          Text(
            _sosSummary(),
            style: GoogleFonts.inter(
              color: AppColors.snow,
              fontSize: 11,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pkgSection(String title, List<String> lines) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.oswald(
              color: AppColors.gold,
              fontSize: 11,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 4),
          ...lines.map(
            (l) => Text(
              l,
              style: GoogleFonts.inter(color: AppColors.snow, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// TREKKER ID — unique, attractive digital identity card
// ==========================================
class TrekkerIdGenerator {
  static String buildId(String name, String bloodType) {
    final seed =
        '${name.trim().toUpperCase()}|${bloodType.trim().toUpperCase()}';
    int hash = 0;
    for (final codeUnit in seed.codeUnits) {
      hash = (hash * 31 + codeUnit) & 0x7FFFFFFF;
    }
    if (hash == 0) hash = 1;
    final hex = hash.toRadixString(16).toUpperCase().padLeft(8, '0');
    return 'K2-${hex.substring(0, 4)}-${hex.substring(4, 8)}';
  }

  // Decorative "scan pattern" — purely visual, not a real QR code.
  static List<bool> scanPattern(String id, int cells) {
    int hash = id.codeUnits.fold<int>(0, (a, b) => (a * 33 + b) & 0x7FFFFFFF);
    final rand = Random(hash);
    return List.generate(cells, (_) => rand.nextBool());
  }
}

class _ScanPatternPainter extends CustomPainter {
  final List<bool> pattern;
  final int columns;
  final Color color;

  _ScanPatternPainter({
    required this.pattern,
    required this.columns,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rows = (pattern.length / columns).ceil();
    final cellW = size.width / columns;
    final cellH = size.height / rows;
    final paint = Paint()..color = color;
    for (int i = 0; i < pattern.length; i++) {
      if (!pattern[i]) continue;
      final col = i % columns;
      final row = i ~/ columns;
      canvas.drawRect(
        Rect.fromLTWH(col * cellW, row * cellH, cellW * 0.82, cellH * 0.82),
        paint,
      );
    }
    // Corner anchors, like a real QR code's finder patterns.
    _drawAnchor(canvas, Offset.zero, cellW * 3);
    _drawAnchor(canvas, Offset(size.width - cellW * 3, 0), cellW * 3);
    _drawAnchor(canvas, Offset(0, size.height - cellW * 3), cellW * 3);
  }

  void _drawAnchor(Canvas canvas, Offset topLeft, double s) {
    final outer = Paint()..color = color;
    final inner = Paint()..color = Colors.transparent;
    canvas.drawRect(Rect.fromLTWH(topLeft.dx, topLeft.dy, s, s), outer);
    canvas.drawRect(
      Rect.fromLTWH(
        topLeft.dx + s * 0.2,
        topLeft.dy + s * 0.2,
        s * 0.6,
        s * 0.6,
      ),
      Paint()..color = AppColors.charcoal,
    );
    canvas.drawRect(
      Rect.fromLTWH(
        topLeft.dx + s * 0.35,
        topLeft.dy + s * 0.35,
        s * 0.3,
        s * 0.3,
      ),
      inner..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _ScanPatternPainter oldDelegate) => false;
}

class TrekkerIdCard extends StatelessWidget {
  final String userName;
  final String bloodType;
  final String trekkerId;
  final String height;
  final String weight;
  final String healthCondition;
  final String allergies;
  final String emergencyPhone;

  const TrekkerIdCard({
    super.key,
    required this.userName,
    required this.bloodType,
    required this.trekkerId,
    this.height = '',
    this.weight = '',
    this.healthCondition = '',
    this.allergies = '',
    this.emergencyPhone = '',
  });

  Widget _cell(String label, String value, {Color? valueColor}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.oswald(
              color: AppColors.gold.withOpacity(0.85),
              fontSize: 9,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value.trim().isEmpty ? '—' : value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              color: valueColor ?? AppColors.snow,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _medRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: GoogleFonts.inter(
                color: AppColors.stone.withOpacity(0.9),
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.trim().isEmpty ? 'None' : value,
              style: GoogleFonts.inter(
                color: AppColors.snow,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pattern = TrekkerIdGenerator.scanPattern(trekkerId, 49);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.gold.withOpacity(0.8), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: AppColors.gold.withOpacity(0.18),
            blurRadius: 28,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Stack(
        children: [
          // Mountain photo background
          Positioned.fill(
            child: Image.asset(
              'assets/22824.jpg',
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            ),
          ),
          // Black-to-clear gradient keeps text readable, photo shows through
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.black.withOpacity(0.96),
                    AppColors.charcoal.withOpacity(0.90),
                    AppColors.forest.withOpacity(0.70),
                  ],
                ),
              ),
            ),
          ),
          // Gold strip at the top
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 5,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.gold,
                    const Color(0xFFF1D27A),
                    AppColors.gold.withOpacity(0.3),
                  ],
                ),
              ),
            ),
          ),
          // Faint mountain watermark
          Positioned(
            right: -24,
            bottom: 40,
            child: Icon(
              Icons.landscape,
              size: 170,
              color: AppColors.gold.withOpacity(0.06),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 26, 22, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '🏔️  K2 EXPEDITION PERMIT',
                      style: GoogleFonts.oswald(
                        color: AppColors.gold,
                        fontSize: 12,
                        letterSpacing: 2.2,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.green.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: AppColors.green.withOpacity(0.5),
                        ),
                      ),
                      child: const Text(
                        'VERIFIED',
                        style: TextStyle(
                          color: AppColors.green,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Identity row: photo, name, permit number, scan pattern
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 76,
                      height: 76,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [AppColors.gold, Color(0xFFF1D27A)],
                        ),
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'assets/22824.jpg',
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            userName.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.oswald(
                              color: AppColors.snow,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'PERMIT NO.',
                            style: GoogleFonts.oswald(
                              color: AppColors.stone.withOpacity(0.7),
                              fontSize: 9,
                              letterSpacing: 1.5,
                            ),
                          ),
                          Text(
                            trekkerId,
                            style: GoogleFonts.oswald(
                              color: AppColors.gold,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 2.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: AppColors.gold.withOpacity(0.35),
                        ),
                      ),
                      child: SizedBox(
                        width: 58,
                        height: 58,
                        child: CustomPaint(
                          painter: _ScanPatternPainter(
                            pattern: pattern,
                            columns: 7,
                            color: AppColors.snow,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 18),
                Container(
                  height: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        AppColors.gold.withOpacity(0.7),
                        AppColors.gold.withOpacity(0.05),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Body details
                Row(
                  children: [
                    _cell('HEIGHT', height.trim().isEmpty ? '' : '$height cm'),
                    _cell('WEIGHT', weight.trim().isEmpty ? '' : '$weight kg'),
                    _cell('BLOOD GROUP', bloodType, valueColor: AppColors.red),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Icon(
                      Icons.phone_in_talk,
                      size: 14,
                      color: AppColors.skyBlue,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'EMERGENCY CONTACT',
                      style: GoogleFonts.oswald(
                        color: AppColors.gold.withOpacity(0.85),
                        fontSize: 9,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      emergencyPhone.trim().isEmpty ? '—' : emergencyPhone,
                      style: GoogleFonts.inter(
                        color: AppColors.snow,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),

                // Medical band
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.red.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.red.withOpacity(0.35)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.medical_services_outlined,
                            size: 14,
                            color: AppColors.red,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'MEDICAL INFORMATION',
                            style: GoogleFonts.oswald(
                              color: AppColors.red,
                              fontSize: 10,
                              letterSpacing: 1.6,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      _medRow('Conditions', healthCondition),
                      _medRow('Allergies', allergies),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Center(
                  child: Text(
                    'K2 EXPEDITION PRO',
                    style: GoogleFonts.oswald(
                      color: AppColors.stone.withOpacity(0.55),
                      fontSize: 10,
                      letterSpacing: 3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// The profile screen is now just the permit card. Name, blood group,
// height, weight, conditions and allergies all live on the card, so there
// is no duplicate text underneath it.
class ProfileScreen extends StatelessWidget {
  final String userName, height, weight, bloodType, healthCondition, allergies;
  final String emergencyPhone;
  const ProfileScreen({
    super.key,
    required this.userName,
    required this.height,
    required this.weight,
    required this.bloodType,
    required this.healthCondition,
    required this.allergies,
    this.emergencyPhone = '',
  });

  @override
  Widget build(BuildContext context) {
    final trekkerId = TrekkerIdGenerator.buildId(userName, bloodType);
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      appBar: AppBar(
        title: Text(
          'TREKKER PROFILE',
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TrekkerIdCard(
            userName: userName,
            bloodType: bloodType,
            trekkerId: trekkerId,
            height: height,
            weight: weight,
            healthCondition: healthCondition,
            allergies: allergies,
            emergencyPhone: emergencyPhone,
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => confirmLogout(context),
            icon: const Icon(Icons.logout, size: 18),
            label: Text(
              'LOG OUT',
              style: GoogleFonts.oswald(letterSpacing: 1.2),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.stone,
              side: BorderSide(color: AppColors.stone.withOpacity(0.4)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class JourneyMapScreen extends StatefulWidget {
  final latlong.LatLng? initialCenter;
  const JourneyMapScreen({super.key, this.initialCenter});

  @override
  State<JourneyMapScreen> createState() => _JourneyMapScreenState();
}

class _JourneyMapScreenState extends State<JourneyMapScreen> {
  final MapController _mapController = MapController();
  late latlong.LatLng _currentPosition;
  bool _isLoadingLocation = true;
  String _locationStatus = "Acquiring GPS fix...";

  @override
  void initState() {
    super.initState();
    _currentPosition =
        widget.initialCenter ?? const latlong.LatLng(35.8825, 76.5133);
    _determineLivePosition();
  }

  Future<void> _determineLivePosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _locationStatus = 'Location services disabled.';
        _isLoadingLocation = false;
      });
      return;
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          _locationStatus = 'Location permissions denied.';
          _isLoadingLocation = false;
        });
        return;
      }
    }
    Position position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    setState(() {
      _currentPosition = latlong.LatLng(position.latitude, position.longitude);
      _locationStatus =
          "GPS Locked: ${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}";
      _isLoadingLocation = false;
    });
    _mapController.move(_currentPosition, 14.0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      appBar: AppBar(
        title: Text(
          'LIVE JOURNEY MAP',
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              _locationStatus,
              style: GoogleFonts.inter(fontSize: 12, color: AppColors.stone),
            ),
          ),
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _currentPosition,
                initialZoom: 14.0,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.flutter_application_1',
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _currentPosition,
                      width: 80,
                      height: 80,
                      child: const Icon(
                        Icons.location_on,
                        color: AppColors.red,
                        size: 40,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class GpsNavigationScreen extends StatefulWidget {
  const GpsNavigationScreen({super.key});
  @override
  State<GpsNavigationScreen> createState() => _GpsNavigationScreenState();
}

class _GpsNavigationScreenState extends State<GpsNavigationScreen> {
  String _locationStatus = "Acquiring Satellite Lock...";
  String _latLongStr = "Lat: -- | Long: --";
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _determinePosition();
  }

  Future<void> _determinePosition() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      setState(() {
        _latLongStr =
            "Lat: ${position.latitude.toStringAsFixed(4)} | Lon: ${position.longitude.toStringAsFixed(4)}";
        _locationStatus =
            "GPS Signal Locked (Alt: ${position.altitude.toInt()} m)";
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _locationStatus = "Failed to acquire GPS fix.";
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      appBar: AppBar(
        title: Text(
          'GPS NAVIGATION',
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.explore, size: 100, color: AppColors.skyBlue),
            const SizedBox(height: 24),
            Text(
              _locationStatus,
              style: GoogleFonts.oswald(color: AppColors.snow, fontSize: 20),
            ),
            const SizedBox(height: 16),
            Text(
              _latLongStr,
              style: GoogleFonts.inter(
                color: AppColors.gold,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 32),
            if (_isLoading)
              const CircularProgressIndicator(color: AppColors.gold)
            else
              ElevatedButton.icon(
                onPressed: _determinePosition,
                icon: const Icon(Icons.refresh),
                label: const Text("REFRESH GPS"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  foregroundColor: Colors.black,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class WeatherBriefScreen extends StatelessWidget {
  const WeatherBriefScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      appBar: AppBar(
        title: Text(
          'MOUNTAIN WEATHER',
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      body: Center(
        child: Text(
          'Weather Feed Active',
          style: GoogleFonts.inter(color: AppColors.stone),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final Color color;
  final List<double> dataPoints;

  _SparklinePainter({required this.color, required this.dataPoints});

  @override
  void paint(Canvas canvas, Size size) {
    if (dataPoints.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    final path = ui.Path();
    final widthStep = size.width / (dataPoints.length - 1);
    final maxHeight = size.height;

    for (int i = 0; i < dataPoints.length; i++) {
      final x = i * widthStep;
      final y = maxHeight - (dataPoints[i] * maxHeight);
      if (i == 0)
        path.moveTo(x, y);
      else
        path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ==========================================
// PERSISTENT STORES (checklist, vitals, GPS tracker)
// ==========================================
// These are app-wide singletons so state survives tab switches, and
// they save to SharedPreferences so it survives closing the app.

String formatDuration(int totalSeconds) {
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)}';
}

String formatPace(double movingSec, double distanceM) {
  if (distanceM < 50 || movingSec <= 0) return '—';
  final secPerKm = movingSec / (distanceM / 1000);
  final m = secPerKm ~/ 60;
  final s = (secPerKm % 60).round();
  return '$m:${s.toString().padLeft(2, '0')} /km';
}

String formatKm(double meters) => '${(meters / 1000).toStringAsFixed(2)} km';

String formatDate(DateTime d) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

String formatTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';

// ---------------- CHECKLIST ----------------

class ChecklistCategory {
  final String emoji;
  final String title;
  final List<String> items;
  const ChecklistCategory(this.emoji, this.title, this.items);
}

class ChecklistStore extends ChangeNotifier {
  ChecklistStore._();
  static final ChecklistStore instance = ChecklistStore._();
  static const String _prefsKey = 'k2_checklist_checked_v1';

  static const List<ChecklistCategory> categories = [
    ChecklistCategory('🧥', 'Clothing & Insulation', [
      'Moisture-wicking base layer (top and bottom)',
      'Insulating fleece mid-layer',
      'Down or synthetic insulated jacket',
      'Waterproof shell jacket and trousers',
      'Warm hat and balaclava or neck gaiter',
      'Liner gloves and insulated mittens',
      'Waterproof insulated trekking or mountaineering boots',
      'Spare wool socks (at least 2 pairs)',
      'Gaiters',
      'UV-rated sunglasses and goggles',
    ]),
    ChecklistCategory('🍲', 'Food & Hydration', [
      'Insulated water bottles or hydration system (3 L or more)',
      'Water purification tablets or filter',
      'High-energy snacks (bars, nuts, dried fruit)',
      'Electrolyte or rehydration tablets',
      'Insulated flask for hot drinks',
      'Stove, fuel and lighter for camp meals',
      'Dehydrated or ready-to-eat camp meals',
    ]),
    ChecklistCategory('🧭', 'Navigation & Communication', [
      'Offline maps downloaded to your phone',
      'Compass and printed route map',
      'GPS device or phone with spare battery',
      'Power bank and charging cables',
      'Headlamp with spare batteries',
      'Satellite communicator or personal locator beacon (PLB)',
    ]),
    ChecklistCategory('⛑️', 'First Aid & Medication', [
      'First aid kit',
      'Personal prescription medication with a spare supply',
      'Altitude sickness medication (as advised by your doctor)',
      'Blister care and medical tape',
      'Pain relief and anti-diarrhoea medication',
      'Sunscreen (SPF 50+) and lip balm',
      'Finger pulse oximeter (optional)',
    ]),
    ChecklistCategory('🆘', 'Emergency & Survival Equipment', [
      'Emergency bivouac bag or thermal blanket',
      'Whistle and signal mirror',
      'Multi-tool or knife',
      'Fire starter (waterproof matches or lighter)',
      'Avalanche transceiver, probe and shovel (if in avalanche terrain)',
      'Ice axe and crampons (if the route requires)',
      'Helmet, harness and rope (technical sections)',
      'Trekking poles',
    ]),
    ChecklistCategory('📄', 'Personal Documents & Permits', [
      'Passport and visa',
      'Climbing or trekking permit',
      'Travel and rescue / evacuation insurance papers',
      'Emergency contact and medical information card',
      'Cash in local currency',
      'Itinerary shared with someone at home',
    ]),
  ];

  final Set<String> _checked = {};
  bool _loaded = false;

  int get total => categories.fold<int>(0, (s, c) => s + c.items.length);
  int get done => categories.fold<int>(
    0,
    (s, c) => s + c.items.where((i) => _checked.contains(i)).length,
  );
  bool isChecked(String item) => _checked.contains(item);

  int doneIn(ChecklistCategory c) =>
      c.items.where((i) => _checked.contains(i)).length;

  static const String _dirtyKey = 'k2_checklist_dirty_v1';
  bool _dirty = false;
  bool _syncing = false;
  int _version = 0;
  bool get unsynced => _dirty;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _checked
        ..clear()
        ..addAll(prefs.getStringList(_prefsKey) ?? <String>[]);
      _dirty = prefs.getBool(_dirtyKey) ?? false;
    } catch (_) {}
    _loaded = true;
    notifyListeners();
    await sync();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, _checked.toList());
      await prefs.setBool(_dirtyKey, _dirty);
    } catch (_) {}
  }

  /// Unsynced local changes are pushed to the server. Otherwise the server copy wins.
  Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;
    final startVersion = _version;
    var again = false;
    try {
      final api = ApiService();
      if (_dirty) {
        final ok = await api.putChecklist(_checked.toList());
        if (ok && _version == startVersion) {
          _dirty = false;
          await _save();
        }
      } else {
        final server = await api.getChecklist();
        if (server != null && _version == startVersion) {
          _checked
            ..clear()
            ..addAll(server);
          await _save();
        }
      }
    } catch (_) {
    } finally {
      _syncing = false;
    }
    if (_dirty && _version != startVersion) again = true; // changed mid-request
    notifyListeners();
    if (again) await sync();
  }

  Future<void> toggle(String item) async {
    if (!_checked.add(item)) _checked.remove(item);
    _version++;
    _dirty = true;
    notifyListeners();
    await _save();
    await sync();
  }

  Future<void> resetAll() async {
    _checked.clear();
    _version++;
    _dirty = true;
    notifyListeners();
    await _save();
    await sync();
  }

  /// Called on logout: forget this user's checklist in memory.
  void resetMemory() {
    _checked.clear();
    _loaded = false;
    _dirty = false;
    _version++;
    notifyListeners();
  }
}

// ---------------- VITALS ----------------

enum SyncStatus { local, synced, failed }

class VitalReading {
  final String id;
  final DateTime time;
  final double hr;
  final double spo2;
  final double brpm;
  final String source; // 'SIMULATED' unless a real sensor is connected
  SyncStatus status;

  VitalReading({
    required this.id,
    required this.time,
    required this.hr,
    required this.spo2,
    required this.brpm,
    required this.source,
    this.status = SyncStatus.local,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'time': time.millisecondsSinceEpoch,
    'hr': hr,
    'spo2': spo2,
    'brpm': brpm,
    'source': source,
    'status': status.name,
  };

  factory VitalReading.fromJson(Map<String, dynamic> j) => VitalReading(
    id: '${j['id']}',
    time: DateTime.fromMillisecondsSinceEpoch((j['time'] as num).toInt()),
    hr: (j['hr'] as num).toDouble(),
    spo2: (j['spo2'] as num).toDouble(),
    brpm: (j['brpm'] as num).toDouble(),
    source: '${j['source'] ?? 'SIMULATED'}',
    status: SyncStatus.values.firstWhere(
      (s) => s.name == j['status'],
      orElse: () => SyncStatus.local,
    ),
  );
}

class RemoteVitalsResult {
  final List<Map<String, dynamic>>? rows;
  final String? error;
  const RemoteVitalsResult(this.rows, this.error);
}

class VitalsStore extends ChangeNotifier {
  VitalsStore._();
  static final VitalsStore instance = VitalsStore._();
  static const String _prefsKey = 'k2_vitals_readings_v1';
  static const int _maxReadings = 500;

  final List<VitalReading> readings = []; // newest first
  bool _loaded = false;
  bool syncing = false;

  int get pendingCount =>
      readings.where((r) => r.status != SyncStatus.synced).length;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        readings
          ..clear()
          ..addAll(
            (jsonDecode(raw) as List).map(
              (e) => VitalReading.fromJson(Map<String, dynamic>.from(e as Map)),
            ),
          );
      }
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(readings.map((r) => r.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> addReading({
    required double hr,
    required double spo2,
    required double brpm,
    String source = 'SIMULATED',
  }) async {
    final now = DateTime.now();
    readings.insert(
      0,
      VitalReading(
        id: '${now.microsecondsSinceEpoch}',
        time: now,
        hr: hr,
        spo2: spo2,
        brpm: brpm,
        source: source,
      ),
    );
    if (readings.length > _maxReadings) {
      readings.removeRange(_maxReadings, readings.length);
    }
    notifyListeners();
    await _save();
  }

  /// Sends unsynced readings (oldest first) to FastAPI. Returns a summary.
  /// Note: ApiService.logVitals currently carries only HR and SpO2.
  Future<String> syncPending() async {
    if (syncing) return 'Sync already running.';
    final pending = readings
        .where((r) => r.status != SyncStatus.synced)
        .toList()
        .reversed
        .toList();
    if (pending.isEmpty) return 'Nothing to sync.';
    syncing = true;
    notifyListeners();
    int ok = 0, failed = 0, consecutiveFails = 0;
    for (final r in pending) {
      bool success = false;
      try {
        success = await ApiService()
            .logVitals(r.hr.round(), r.spo2.round())
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        success = false;
      }
      if (success) {
        r.status = SyncStatus.synced;
        ok++;
        consecutiveFails = 0;
      } else {
        r.status = SyncStatus.failed;
        failed++;
        consecutiveFails++;
        if (consecutiveFails >= 3) break; // server is clearly unreachable
      }
    }
    syncing = false;
    await _save();
    notifyListeners();
    if (failed == 0) return 'Synced $ok reading(s).';
    return 'Synced $ok, failed $failed. Failed readings stay saved locally.';
  }

  /// Loads previously saved readings from the backend.
  /// Requires ApiService.getVitalsHistory() returning a List of maps (or null
  /// on failure). It is called dynamically so this file still compiles if the
  /// method has not been added yet.
  static Future<RemoteVitalsResult> fetchRemote() async {
    try {
      final dynamic api = ApiService();
      final dynamic res = await api.getVitalsHistory();
      if (res == null) {
        return const RemoteVitalsResult(
          null,
          'Server unreachable, or you are not signed in to the server.',
        );
      }
      final rows = (res as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      return RemoteVitalsResult(rows, null);
    } on NoSuchMethodError {
      return const RemoteVitalsResult(
        null,
        'ApiService.getVitalsHistory() has not been added yet.',
      );
    } catch (e) {
      return RemoteVitalsResult(null, 'Could not load server history: $e');
    }
  }
}

// ---------------- GPS TREK TRACKER ----------------

/// GPS fixes worse than this (metres) are ignored so jitter doesn't inflate
/// distance. A desktop PC without GPS hardware usually reports 100 m+.
const double kMaxAcceptableAccuracyM = 35;
const double kWaypointMaxAccuracyM = 50;
const double kWaypointAltToleranceM = 150;
const int kWaypointConfirmFixes = 3;

class TrackPoint {
  final double lat;
  final double lon;
  final double? alt;
  final double acc;
  final DateTime t;
  final int seg;
  const TrackPoint({
    required this.lat,
    required this.lon,
    required this.alt,
    required this.acc,
    required this.t,
    required this.seg,
  });

  List<dynamic> toJson() => [lat, lon, alt, acc, t.millisecondsSinceEpoch, seg];

  factory TrackPoint.fromJson(List<dynamic> j) => TrackPoint(
    lat: (j[0] as num).toDouble(),
    lon: (j[1] as num).toDouble(),
    alt: j[2] == null ? null : (j[2] as num).toDouble(),
    acc: (j[3] as num).toDouble(),
    t: DateTime.fromMillisecondsSinceEpoch((j[4] as num).toInt()),
    seg: (j[5] as num).toInt(),
  );

  latlong.LatLng get latLng => latlong.LatLng(lat, lon);
}

List<List<latlong.LatLng>> routeSegments(List<TrackPoint> pts) {
  final out = <List<latlong.LatLng>>[];
  int? current;
  for (final p in pts) {
    if (current != p.seg) {
      out.add(<latlong.LatLng>[]);
      current = p.seg;
    }
    out.last.add(p.latLng);
  }
  return out;
}

class CampWaypoint {
  final String name;
  final double? lat;
  final double? lon;
  final double? altM;
  final double radiusM;
  const CampWaypoint({
    required this.name,
    this.lat,
    this.lon,
    this.altM,
    this.radiusM = 150,
  });

  bool get isSet => lat != null && lon != null;

  CampWaypoint located(double lat, double lon, double? altM, double radiusM) =>
      CampWaypoint(
        name: name,
        lat: lat,
        lon: lon,
        altM: altM,
        radiusM: radiusM,
      );

  CampWaypoint cleared() => CampWaypoint(name: name);

  Map<String, dynamic> toJson() => {
    'name': name,
    'lat': lat,
    'lon': lon,
    'alt': altM,
    'radius': radiusM,
  };

  factory CampWaypoint.fromJson(Map<String, dynamic> j) => CampWaypoint(
    name: '${j['name']}',
    lat: (j['lat'] as num?)?.toDouble(),
    lon: (j['lon'] as num?)?.toDouble(),
    altM: (j['alt'] as num?)?.toDouble(),
    radiusM: (j['radius'] as num?)?.toDouble() ?? 150,
  );
}

class SavedTrek {
  final String id;
  final String name;
  final DateTime start;
  final DateTime end;
  final double distanceM;
  final int movingSec;
  final int elapsedSec;
  final double gainM;
  final double? maxAlt;
  final List<TrackPoint> points;

  const SavedTrek({
    required this.id,
    required this.name,
    required this.start,
    required this.end,
    required this.distanceM,
    required this.movingSec,
    required this.elapsedSec,
    required this.gainM,
    required this.maxAlt,
    required this.points,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'start': start.millisecondsSinceEpoch,
    'end': end.millisecondsSinceEpoch,
    'dist': distanceM,
    'moving': movingSec,
    'elapsed': elapsedSec,
    'gain': gainM,
    'maxAlt': maxAlt,
    'pts': points.map((p) => p.toJson()).toList(),
  };

  factory SavedTrek.fromJson(Map<String, dynamic> j) => SavedTrek(
    id: '${j['id']}',
    name: '${j['name']}',
    start: DateTime.fromMillisecondsSinceEpoch((j['start'] as num).toInt()),
    end: DateTime.fromMillisecondsSinceEpoch((j['end'] as num).toInt()),
    distanceM: (j['dist'] as num).toDouble(),
    movingSec: (j['moving'] as num).toInt(),
    elapsedSec: (j['elapsed'] as num).toInt(),
    gainM: (j['gain'] as num).toDouble(),
    maxAlt: (j['maxAlt'] as num?)?.toDouble(),
    points: (j['pts'] as List)
        .map((e) => TrackPoint.fromJson(List<dynamic>.from(e as List)))
        .toList(),
  );
}

/// Saves a finished trek to the local database and, if reachable, the API.
/// Returns true when the cloud copy succeeded.
/// delete below this
Future<bool> persistTrekToJourney(SavedTrek t) async {
  final km = t.distanceM / 1000;
  final alt = (t.maxAlt ?? 0).round();
  try {
    await DatabaseHelper.instance.insertTrek({
      'user_id': 1,
      'trek_name': t.name,
      'start_date': t.start.toIso8601String(),
      'end_date': t.end.toIso8601String(),
      'distance': double.parse(km.toStringAsFixed(3)),
      'max_altitude': alt,
      'status': 'Completed',
    });
  } catch (_) {}
  try {
    return await ApiService().createTrekWithDetails(
      t.name,
      km,
      alt.toDouble(),
      start: t.start,
      end: t.end,
      gainM: t.gainM,
      points: t.points
          .map((p) => [p.lat, p.lon, p.alt, p.acc, p.t.millisecondsSinceEpoch])
          .toList(),
    );
  } catch (_) {
    return false;
  }
}

// just above this
enum TrackState { idle, tracking, paused }

class TrekTracker extends ChangeNotifier {
  TrekTracker._();
  static final TrekTracker instance = TrekTracker._();

  static const String _kHistory = 'k2_trek_history_v1';
  static const String _kWaypoints = 'k2_waypoints_v1';
  static const String _kStage = 'k2_reached_stage_v1';
  static const String _kActive = 'k2_active_trek_v1';
  static const List<String> stageLabels = [
    'BASE',
    'CAMP 1',
    'CAMP 2',
    'SUMMIT',
  ];

  TrackState state = TrackState.idle;
  final List<TrackPoint> points = [];
  final List<SavedTrek> history = [];
  List<CampWaypoint> waypoints = List<CampWaypoint>.generate(
    4,
    (i) => CampWaypoint(name: stageLabels[i]),
  );
  int reachedStage = 0;

  Position? lastPosition;
  double? lastAccuracy;
  double? currentAltitude;
  String? statusMessage;
  bool recoveredTrek = false;

  DateTime? startTime;
  double distanceM = 0;
  double movingSec = 0;
  double gainM = 0;
  double? maxAltitude;

  double _todayHistoryM = 0;
  int _segment = 0;
  DateTime? _pauseStart;
  Duration _pausedAccum = Duration.zero;
  StreamSubscription<Position>? _sub;
  Timer? _ticker;
  final List<double> _altBuf = [];
  double? _altAnchor;
  final Map<int, int> _near = {};
  final List<String> _events = [];
  int _sinceSnapshot = 0;
  bool _inited = false;
  static const String _kCampDirty = 'k2_camps_dirty_v1';
  static const String _kCampEvents = 'k2_camp_events_v1';
  bool _campsDirty = false;
  bool _campsSyncing = false;
  int _campsVersion = 0;
  final List<Map<String, dynamic>> _pendingCampEvents = [];

  bool get isActive => state != TrackState.idle;

  // ----- lifecycle / persistence -----

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final h = prefs.getString(_kHistory);
      if (h != null) {
        history
          ..clear()
          ..addAll(
            (jsonDecode(h) as List).map(
              (e) => SavedTrek.fromJson(Map<String, dynamic>.from(e as Map)),
            ),
          );
      }
      final w = prefs.getString(_kWaypoints);
      if (w != null) {
        final list = (jsonDecode(w) as List)
            .map(
              (e) => CampWaypoint.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
        if (list.length == 4) waypoints = list;
      }
      reachedStage = prefs.getInt(_kStage) ?? 0;
      _campsDirty = prefs.getBool(_kCampDirty) ?? false;
      final ev = prefs.getString(_kCampEvents);
      if (ev != null) {
        _pendingCampEvents
          ..clear()
          ..addAll(
            (jsonDecode(ev) as List).map(
              (e) => Map<String, dynamic>.from(e as Map),
            ),
          );
      }
      final a = prefs.getString(_kActive);
      if (a != null) {
        _restoreActive(Map<String, dynamic>.from(jsonDecode(a) as Map));
      }
    } catch (_) {}
    _recomputeTodayHistory();
    notifyListeners();
    syncCamps();
  }

  void _restoreActive(Map<String, dynamic> m) {
    final pts = (m['pts'] as List)
        .map((e) => TrackPoint.fromJson(List<dynamic>.from(e as List)))
        .toList();
    if (pts.isEmpty) return;
    points
      ..clear()
      ..addAll(pts);
    final elapsedMs = (m['elapsedMs'] as num).toInt();
    startTime = DateTime.now().subtract(Duration(milliseconds: elapsedMs));
    _pausedAccum = Duration.zero;
    _pauseStart = DateTime.now();
    distanceM = (m['dist'] as num).toDouble();
    movingSec = (m['moving'] as num).toDouble();
    gainM = (m['gain'] as num).toDouble();
    maxAltitude = (m['maxAlt'] as num?)?.toDouble();
    _segment = (m['seg'] as num).toInt() + 1;
    state = TrackState.paused;
    recoveredTrek = true;
  }

  Future<void> _persistHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kHistory,
        jsonEncode(history.map((t) => t.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> _persistWaypoints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kWaypoints,
        jsonEncode(waypoints.map((w) => w.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> _persistStage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kStage, reachedStage);
    } catch (_) {}
  }

  Future<void> _saveSnapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kActive,
        jsonEncode({
          'pts': points.map((p) => p.toJson()).toList(),
          'elapsedMs': elapsed.inMilliseconds,
          'dist': distanceM,
          'moving': movingSec,
          'gain': gainM,
          'maxAlt': maxAltitude,
          'seg': _segment,
        }),
      );
    } catch (_) {}
  }

  Future<void> _clearSnapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kActive);
    } catch (_) {}
  }

  // ----- permission / position -----

  Future<bool> ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        statusMessage =
            'Location services are turned off. Turn them on to use GPS.';
        notifyListeners();
        return false;
      }
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      if (p == LocationPermission.denied) {
        statusMessage = 'Location permission was denied.';
        notifyListeners();
        return false;
      }
      if (p == LocationPermission.deniedForever) {
        statusMessage =
            'Location permission is permanently denied. Enable it in system settings.';
        notifyListeners();
        return false;
      }
      statusMessage = null;
      return true;
    } catch (e) {
      statusMessage = 'Could not access GPS: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> refreshPosition() async {
    if (!await ensurePermission()) return;
    try {
      final p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
      ).timeout(const Duration(seconds: 20));
      _applyForDisplay(p);
      notifyListeners();
    } catch (e) {
      statusMessage = 'No GPS fix yet ($e).';
      notifyListeners();
    }
  }

  void _applyForDisplay(Position p) {
    lastPosition = p;
    lastAccuracy = p.accuracy;
    final a = _validAlt(p);
    if (a != null) currentAltitude = a;
  }

  /// Altitude from GPS is only trusted when it looks plausible. Many
  /// platforms report exactly 0 when there is no altitude fix.
  double? _validAlt(Position p) {
    final a = p.altitude;
    if (a.isNaN || a.isInfinite) return null;
    if (a == 0.0) return null;
    if (a < -400 || a > 9000) return null;
    return a;
  }

  // ----- start / pause / resume / finish -----

  Future<bool> start() async {
    if (state != TrackState.idle) return false;
    if (!await ensurePermission()) return false;
    _resetActive();
    startTime = DateTime.now();
    state = TrackState.tracking;
    _subscribe();
    _startTicker();
    notifyListeners();
    return true;
  }

  void _resetActive() {
    points.clear();
    distanceM = 0;
    movingSec = 0;
    gainM = 0;
    maxAltitude = null;
    _segment = 0;
    _altBuf.clear();
    _altAnchor = null;
    _near.clear();
    _pausedAccum = Duration.zero;
    _pauseStart = null;
    startTime = null;
    recoveredTrek = false;
    _sinceSnapshot = 0;
  }

  void _subscribe() {
    _sub?.cancel();
    _sub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 2,
          ),
        ).listen(
          _onPosition,
          onError: (Object e) {
            statusMessage = 'GPS error: $e';
            notifyListeners();
          },
        );
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state == TrackState.tracking) notifyListeners();
    });
  }

  void pause() {
    if (state != TrackState.tracking) return;
    _sub?.cancel();
    _sub = null;
    _ticker?.cancel();
    _pauseStart = DateTime.now();
    state = TrackState.paused;
    _segment++;
    _altBuf.clear();
    _altAnchor = null;
    _saveSnapshot();
    notifyListeners();
  }

  Future<bool> resume() async {
    if (state != TrackState.paused) return false;
    if (!await ensurePermission()) return false;
    if (_pauseStart != null) {
      _pausedAccum += DateTime.now().difference(_pauseStart!);
      _pauseStart = null;
    }
    recoveredTrek = false;
    state = TrackState.tracking;
    _subscribe();
    _startTicker();
    notifyListeners();
    return true;
  }

  Duration get elapsed {
    final s = startTime;
    if (s == null) return Duration.zero;
    final now = DateTime.now();
    final pausedNow = _pauseStart != null
        ? now.difference(_pauseStart!)
        : Duration.zero;
    final e = now.difference(s) - _pausedAccum - pausedNow;
    return e.isNegative ? Duration.zero : e;
  }

  Future<SavedTrek?> finish({String? name}) async {
    if (state == TrackState.idle) return null;
    _sub?.cancel();
    _sub = null;
    _ticker?.cancel();
    final end = DateTime.now();
    final trek = SavedTrek(
      id: '${end.millisecondsSinceEpoch}',
      name: (name == null || name.trim().isEmpty) ? 'K2 TREK' : name.trim(),
      start: startTime ?? end,
      end: end,
      distanceM: distanceM,
      movingSec: movingSec.round(),
      elapsedSec: elapsed.inSeconds,
      gainM: gainM,
      maxAlt: maxAltitude,
      points: List<TrackPoint>.from(points),
    );
    history.insert(0, trek);
    if (history.length > 50) history.removeRange(50, history.length);
    _resetActive();
    state = TrackState.idle;
    _recomputeTodayHistory();
    await _persistHistory();
    await _clearSnapshot();
    notifyListeners();
    return trek;
  }

  Future<void> discard() async {
    _sub?.cancel();
    _sub = null;
    _ticker?.cancel();
    _resetActive();
    state = TrackState.idle;
    await _clearSnapshot();
    notifyListeners();
  }

  Future<void> deleteSaved(String id) async {
    history.removeWhere((t) => t.id == id);
    _recomputeTodayHistory();
    await _persistHistory();
    notifyListeners();
  }

  // ----- position handling -----

  void _onPosition(Position p) {
    if (state != TrackState.tracking) return;
    _applyForDisplay(p);
    if (p.accuracy > kMaxAcceptableAccuracyM) {
      notifyListeners(); // poor fix: shown in the UI but not recorded
      return;
    }
    final now = DateTime.now();
    final rawAlt = _validAlt(p);
    final pt = TrackPoint(
      lat: p.latitude,
      lon: p.longitude,
      alt: rawAlt,
      acc: p.accuracy,
      t: now,
      seg: _segment,
    );
    if (points.isNotEmpty && points.last.seg == _segment) {
      final last = points.last;
      final d = Geolocator.distanceBetween(last.lat, last.lon, pt.lat, pt.lon);
      final dt = now.difference(last.t).inMilliseconds / 1000.0;
      final minStep = max(3.0, (last.acc + pt.acc) / 4); // ignore jitter
      if (d < minStep) {
        notifyListeners();
        return;
      }
      if (dt > 0 && d / dt > 15) {
        notifyListeners(); // implausible jump (> 54 km/h on foot)
        return;
      }
      distanceM += d;
      if (dt > 0 && d / dt >= 0.4) movingSec += min(dt, 60.0);
    }
    _updateElevation(_smoothAlt(rawAlt));
    points.add(pt);
    _checkWaypoints(pt);
    _sinceSnapshot++;
    if (_sinceSnapshot >= 15) {
      _sinceSnapshot = 0;
      _saveSnapshot();
    }
    notifyListeners();
  }

  double? _smoothAlt(double? alt) {
    if (alt == null) return null;
    _altBuf.add(alt);
    if (_altBuf.length > 3) _altBuf.removeAt(0);
    return _altBuf.reduce((a, b) => a + b) / _altBuf.length;
  }

  /// Elevation gain uses a 5 m hysteresis so GPS altitude noise does not
  /// add up to fake climbing.
  void _updateElevation(double? smooth) {
    if (smooth == null) return;
    final maxA = maxAltitude;
    if (maxA == null || smooth > maxA) maxAltitude = smooth;
    final anchor = _altAnchor;
    if (anchor == null) {
      _altAnchor = smooth;
      return;
    }
    final diff = smooth - anchor;
    if (diff >= 5) {
      gainM += diff;
      _altAnchor = smooth;
    } else if (diff <= -5) {
      _altAnchor = smooth;
    }
  }

  // ----- camps / waypoints -----

  void _checkWaypoints(TrackPoint pt) {
    if (pt.acc > kWaypointMaxAccuracyM) return;
    for (int stage = reachedStage + 1; stage < waypoints.length; stage++) {
      final wp = waypoints[stage];
      if (!wp.isSet) continue;
      final d = Geolocator.distanceBetween(pt.lat, pt.lon, wp.lat!, wp.lon!);
      bool inside = d <= wp.radiusM;
      final alt = currentAltitude;
      final wpAlt = wp.altM;
      if (inside &&
          wpAlt != null &&
          alt != null &&
          (alt - wpAlt).abs() > kWaypointAltToleranceM) {
        inside = false; // altitude does not match the configured camp
      }
      final n = inside ? (_near[stage] ?? 0) + 1 : 0;
      _near[stage] = n;
      if (n >= kWaypointConfirmFixes) {
        reachedStage = stage;
        _near.clear();
        _events.add(
          'GPS: ${stageLabels[stage]} reached (${d.round()} m from the waypoint).',
        );
        _persistStage();
        _recordCampEvent(stage, 'gps');
        break;
      }
    }
  }

  void confirmStageManually(int stage) {
    if (stage < 0 || stage >= stageLabels.length) return;
    reachedStage = stage;
    _near.clear();
    _persistStage();
    _recordCampEvent(stage, 'manual');
    notifyListeners();
  }

  void setWaypoint(int stage, CampWaypoint wp) {
    waypoints[stage] = wp;
    _persistWaypoints();
    _markCampsDirty();
    notifyListeners();
  }

  // ----- camp sync with the server -----

  void _recordCampEvent(int stage, String method) {
    _pendingCampEvents.add({
      'client_id': '${DateTime.now().microsecondsSinceEpoch}-$stage',
      'stage': stage,
      'method': method,
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    _markCampsDirty();
  }

  void _markCampsDirty() {
    _campsVersion++;
    _campsDirty = true;
    _saveCampSyncState();
    syncCamps();
  }

  Future<void> _saveCampSyncState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kCampDirty, _campsDirty);
      await prefs.setString(_kCampEvents, jsonEncode(_pendingCampEvents));
    } catch (_) {}
  }

  /// Pushes unsynced local changes. Otherwise adopts the server copy.
  Future<void> syncCamps() async {
    if (_campsSyncing) return;
    _campsSyncing = true;
    final startVersion = _campsVersion;
    var again = false;
    try {
      final api = ApiService();
      if (_campsDirty) {
        final sent = List<Map<String, dynamic>>.from(_pendingCampEvents);
        final ok = await api.putCamps(
          reachedStage: reachedStage,
          waypoints: [
            for (int i = 0; i < waypoints.length; i++)
              if (waypoints[i].isSet)
                {
                  'stage': i,
                  'lat': waypoints[i].lat,
                  'lon': waypoints[i].lon,
                  'alt_m': waypoints[i].altM,
                  'radius_m': waypoints[i].radiusM,
                },
          ],
          events: sent,
        );
        if (ok) {
          final ids = sent.map((e) => e['client_id']).toSet();
          _pendingCampEvents.removeWhere((e) => ids.contains(e['client_id']));
          if (_campsVersion == startVersion) _campsDirty = false;
          await _saveCampSyncState();
        }
      } else {
        final server = await api.getCamps();
        if (server != null && _campsVersion == startVersion) {
          if (server['initialized'] == true) {
            final wps = List<CampWaypoint>.generate(
              4,
              (i) => CampWaypoint(name: stageLabels[i]),
            );
            for (final w in (server['waypoints'] as List? ?? const [])) {
              final m = Map<String, dynamic>.from(w as Map);
              final s = (m['stage'] as num).toInt();
              if (s < 0 || s > 3) continue;
              wps[s] = wps[s].located(
                (m['lat'] as num).toDouble(),
                (m['lon'] as num).toDouble(),
                (m['alt_m'] as num?)?.toDouble(),
                (m['radius_m'] as num?)?.toDouble() ?? 150,
              );
            }
            waypoints = wps;
            reachedStage = min(
              3,
              max(0, ((server['reached_stage'] as num?) ?? 0).toInt()),
            );
            await _persistWaypoints();
            await _persistStage();
            notifyListeners();
          } else if (reachedStage > 0 || waypoints.any((w) => w.isSet)) {
            // Server has nothing yet but this phone does: upload it.
            _campsVersion++;
            _campsDirty = true;
            await _saveCampSyncState();
          }
        }
      }
    } catch (_) {
    } finally {
      _campsSyncing = false;
    }
    if (_campsDirty && _campsVersion != startVersion) again = true;
    if (again) await syncCamps();
  }

  /// Called on logout: forget this user's local trek state.
  void resetForLogout() {
    _sub?.cancel();
    _sub = null;
    _ticker?.cancel();
    _resetActive();
    state = TrackState.idle;
    history.clear();
    waypoints = List<CampWaypoint>.generate(
      4,
      (i) => CampWaypoint(name: stageLabels[i]),
    );
    reachedStage = 0;
    lastPosition = null;
    lastAccuracy = null;
    currentAltitude = null;
    statusMessage = null;
    _todayHistoryM = 0;
    _pendingCampEvents.clear();
    _campsDirty = false;
    _events.clear();
    _inited = false;
    notifyListeners();
  }

  String? takeEvent() => _events.isEmpty ? null : _events.removeAt(0);

  int? get nextStage => reachedStage < 3 ? reachedStage + 1 : null;

  double? distanceToNextM() {
    final ns = nextStage;
    final p = lastPosition;
    if (ns == null || p == null) return null;
    final wp = waypoints[ns];
    if (!wp.isSet) return null;
    return Geolocator.distanceBetween(
      p.latitude,
      p.longitude,
      wp.lat!,
      wp.lon!,
    );
  }

  // ----- derived numbers -----

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static double _distanceForDay(List<TrackPoint> pts, DateTime day) {
    double sum = 0;
    for (int i = 1; i < pts.length; i++) {
      final a = pts[i - 1];
      final b = pts[i];
      if (a.seg == b.seg && _sameDay(a.t, day) && _sameDay(b.t, day)) {
        sum += Geolocator.distanceBetween(a.lat, a.lon, b.lat, b.lon);
      }
    }
    return sum;
  }

  void _recomputeTodayHistory() {
    final now = DateTime.now();
    _todayHistoryM = history.fold<double>(
      0,
      (s, t) => s + _distanceForDay(t.points, now),
    );
  }

  /// Distance from today's recorded GPS points only (0 if none recorded).
  double get todayDistanceM =>
      _todayHistoryM + _distanceForDay(points, DateTime.now());

  bool get hasTodayGps => todayDistanceM > 0;

  List<double> sparkDistance() {
    if (points.length < 2) return const [0.0, 0.0];
    final cum = <double>[0];
    for (int i = 1; i < points.length; i++) {
      final a = points[i - 1];
      final b = points[i];
      final step = a.seg == b.seg
          ? Geolocator.distanceBetween(a.lat, a.lon, b.lat, b.lon)
          : 0.0;
      cum.add(cum.last + step);
    }
    final total = cum.last;
    if (total <= 0) return const [0.0, 0.0];
    return _sample(cum, 12).map((v) => v / total).toList();
  }

  List<double> sparkAltitude() {
    final alts = points.where((p) => p.alt != null).map((p) => p.alt!).toList();
    if (alts.length < 2) return const [0.5, 0.5];
    final lo = alts.reduce(min);
    final hi = alts.reduce(max);
    if (hi - lo < 1) return const [0.5, 0.5];
    return _sample(alts, 12).map((v) => (v - lo) / (hi - lo)).toList();
  }

  static List<double> _sample(List<double> src, int n) {
    if (src.length <= n) return src;
    return List<double>.generate(
      n,
      (i) => src[(i * (src.length - 1) / (n - 1)).round()],
    );
  }
}

// ==========================================
// EXPEDITION GPS — tracker, route viewer, camp waypoints
// ==========================================

const latlong.LatLng _kDefaultMapCenter = latlong.LatLng(35.8825, 76.5133);

double _zoomForSpan(double span) {
  if (span < 0.002) return 16;
  if (span < 0.01) return 14;
  if (span < 0.05) return 12;
  if (span < 0.2) return 10;
  return 8;
}

/// Manual camp confirmation (used by the Dashboard and the tracker screen).
Future<void> confirmStageDialog(BuildContext context, int stage) async {
  final t = TrekTracker.instance;
  if (stage == t.reachedStage) return;
  final label = TrekTracker.stageLabels[stage];
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.charcoal,
      title: Text(
        'CONFIRM $label?',
        style: GoogleFonts.oswald(
          color: AppColors.snow,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: Text(
        'Mark $label as reached. This is a manual confirmation, not a GPS detection.',
        style: GoogleFonts.inter(color: AppColors.stone),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('CANCEL', style: TextStyle(color: AppColors.stone)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.gold),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text(
            'CONFIRM',
            style: TextStyle(color: AppColors.charcoal),
          ),
        ),
      ],
    ),
  );
  if (ok == true) t.confirmStageManually(stage);
}

class TrekTrackerScreen extends StatefulWidget {
  const TrekTrackerScreen({super.key});
  @override
  State<TrekTrackerScreen> createState() => _TrekTrackerScreenState();
}

class _TrekTrackerScreenState extends State<TrekTrackerScreen> {
  final TrekTracker _t = TrekTracker.instance;
  final MapController _map = MapController();
  bool _mapReady = false;
  bool _follow = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _t.addListener(_onChange);
    _t.init().then((_) {
      if (mounted && _t.state == TrackState.idle) _t.refreshPosition();
    });
  }

  @override
  void dispose() {
    _t.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    final p = _t.lastPosition;
    if (_mapReady && _follow && p != null) {
      try {
        _map.move(latlong.LatLng(p.latitude, p.longitude), _map.camera.zoom);
      } catch (_) {}
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.forest),
    );
  }

  Future<void> _start() async {
    final ok = await _t.start();
    if (!ok) _toast(_t.statusMessage ?? 'Could not start GPS tracking.');
  }

  Future<void> _resume() async {
    final ok = await _t.resume();
    if (!ok) _toast(_t.statusMessage ?? 'Could not resume GPS tracking.');
  }

  Future<void> _finish() async {
    final ctrl = TextEditingController(
      text: 'K2 TREK ${formatDate(DateTime.now())}',
    );
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.charcoal,
        title: Text(
          'FINISH TREK',
          style: GoogleFonts.oswald(
            color: AppColors.snow,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${formatKm(_t.distanceM)}  •  ${formatDuration(_t.elapsed.inSeconds)}',
              style: GoogleFonts.inter(color: AppColors.stone),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              style: const TextStyle(color: AppColors.snow),
              decoration: const InputDecoration(
                labelText: 'Trek name',
                labelStyle: TextStyle(color: AppColors.stone),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text(
              'CANCEL',
              style: TextStyle(color: AppColors.stone),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text(
              'DISCARD',
              style: TextStyle(color: AppColors.red),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.gold),
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text(
              'SAVE',
              style: TextStyle(color: AppColors.charcoal),
            ),
          ),
        ],
      ),
    );
    if (action == 'save') {
      setState(() => _saving = true);
      final trek = await _t.finish(name: ctrl.text);
      bool synced = false;
      if (trek != null) synced = await persistTrekToJourney(trek);
      if (!mounted) return;
      setState(() => _saving = false);
      _toast(
        synced
            ? 'Trek saved to your Journey.'
            : 'Trek saved on this device. Cloud sync failed.',
      );
    } else if (action == 'discard') {
      await _t.discard();
      _toast('Trek discarded.');
    }
  }

  Widget _stat(String label, String value) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.cardDark,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.oswald(
                color: AppColors.snow,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: GoogleFonts.inter(
                color: AppColors.stone,
                fontSize: 10,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _banner(String text, Color color, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                color: AppColors.snow,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMap() {
    final p = _t.lastPosition;
    final me = p == null ? null : latlong.LatLng(p.latitude, p.longitude);
    final center =
        me ??
        (_t.points.isNotEmpty ? _t.points.last.latLng : _kDefaultMapCenter);
    final markers = <Marker>[];
    for (int i = 0; i < _t.waypoints.length; i++) {
      final wp = _t.waypoints[i];
      if (!wp.isSet) continue;
      final reached = i <= _t.reachedStage;
      markers.add(
        Marker(
          point: latlong.LatLng(wp.lat!, wp.lon!),
          width: 70,
          height: 52,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.flag,
                size: 24,
                color: reached ? AppColors.green : AppColors.skyBlue,
              ),
              Text(
                TrekTracker.stageLabels[i],
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  backgroundColor: Colors.black54,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (me != null) {
      markers.add(
        Marker(
          point: me,
          width: 40,
          height: 40,
          child: const Icon(
            Icons.my_location,
            color: AppColors.skyBlue,
            size: 30,
          ),
        ),
      );
    }
    final lines = <Polyline>[];
    for (final seg in routeSegments(_t.points)) {
      if (seg.length > 1) {
        lines.add(Polyline(points: seg, strokeWidth: 5, color: AppColors.gold));
      }
    }
    return Container(
      height: 300,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 16,
              onMapReady: () => _mapReady = true,
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture && _follow) setState(() => _follow = false);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.flutter_application_1',
              ),
              PolylineLayer(polylines: lines),
              MarkerLayer(markers: markers),
            ],
          ),
          if (me == null)
            Positioned(
              top: 10,
              left: 10,
              right: 10,
              child: Container(
                padding: const EdgeInsets.all(8),
                color: Colors.black54,
                child: Text(
                  'Waiting for a GPS position…',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(color: AppColors.snow, fontSize: 12),
                ),
              ),
            ),
          Positioned(
            right: 10,
            bottom: 10,
            child: FloatingActionButton.small(
              backgroundColor: _follow ? AppColors.gold : AppColors.cardDark,
              foregroundColor: _follow ? AppColors.charcoal : AppColors.snow,
              onPressed: () {
                setState(() => _follow = true);
                final pos = _t.lastPosition;
                if (_mapReady && pos != null) {
                  try {
                    _map.move(latlong.LatLng(pos.latitude, pos.longitude), 16);
                  } catch (_) {}
                }
              },
              child: const Icon(Icons.my_location),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGpsInfo() {
    final acc = _t.lastAccuracy;
    final alt = _t.currentAltitude;
    final p = _t.lastPosition;
    String quality;
    Color qc;
    if (acc == null) {
      quality = 'No GPS fix';
      qc = Colors.orangeAccent;
    } else if (acc <= 10) {
      quality = 'Good';
      qc = AppColors.green;
    } else if (acc <= kMaxAcceptableAccuracyM) {
      quality = 'Fair';
      qc = AppColors.gold;
    } else {
      quality = 'Poor, points not recorded';
      qc = AppColors.red;
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gps_fixed, size: 16, color: qc),
              const SizedBox(width: 8),
              Text(
                acc == null ? quality : '±${acc.round()} m  •  $quality',
                style: GoogleFonts.inter(
                  color: qc,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                alt == null
                    ? 'Altitude: not available'
                    : 'Altitude: ${alt.round()} m',
                style: GoogleFonts.inter(color: AppColors.snow, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            p == null
                ? 'Position: —'
                : 'Position: ${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}',
            style: GoogleFonts.inter(color: AppColors.stone, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    switch (_t.state) {
      case TrackState.idle:
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _start,
            icon: const Icon(Icons.play_arrow),
            label: const Text('START TREK'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.gold,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        );
      case TrackState.tracking:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _t.pause,
                icon: const Icon(Icons.pause),
                label: const Text('PAUSE'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.gold,
                  side: const BorderSide(color: AppColors.gold),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _finish,
                icon: const Icon(Icons.stop),
                label: const Text('FINISH'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.red,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        );
      case TrackState.paused:
        return Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _resume,
                icon: const Icon(Icons.play_arrow),
                label: const Text('RESUME'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _finish,
                icon: const Icon(Icons.stop),
                label: const Text('FINISH'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.red,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        );
    }
  }

  Widget _buildCampCard() {
    final next = _t.nextStage;
    final toNext = _t.distanceToNextM();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'CAMP PROGRESS',
                style: GoogleFonts.oswald(
                  color: AppColors.snow,
                  fontSize: 13,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const CampWaypointsScreen(),
                  ),
                ),
                icon: const Icon(Icons.flag, size: 14),
                label: const Text('SET WAYPOINTS'),
                style: TextButton.styleFrom(foregroundColor: AppColors.gold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...List.generate(4, (i) {
            final reached = i <= _t.reachedStage;
            final wp = _t.waypoints[i];
            return InkWell(
              onTap: () => confirmStageDialog(context, i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      reached ? Icons.check_circle : Icons.circle_outlined,
                      size: 18,
                      color: reached ? AppColors.gold : AppColors.stone,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      TrekTracker.stageLabels[i],
                      style: GoogleFonts.inter(
                        color: reached ? AppColors.snow : AppColors.stone,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      wp.isSet ? 'GPS waypoint set' : 'No waypoint',
                      style: GoogleFonts.inter(
                        color: wp.isSet ? AppColors.green : AppColors.stone,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 6),
          Text(
            next == null
                ? 'Summit confirmed.'
                : (toNext == null
                      ? 'Set coordinates for ${TrekTracker.stageLabels[next]} to enable GPS detection, or tap a camp to confirm it yourself.'
                      : '${formatKm(toNext)} to ${TrekTracker.stageLabels[next]}. Tap a camp to confirm it manually.'),
            style: GoogleFonts.inter(
              color: AppColors.stone,
              fontSize: 11,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyCard(SavedTrek tr) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => TrekRouteScreen(trek: tr)),
        ),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.cardDark,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: Row(
            children: [
              const Icon(Icons.route, color: AppColors.gold),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        color: AppColors.snow,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      '${formatDate(tr.start)}  •  ${formatKm(tr.distanceM)}  •  ${formatDuration(tr.elapsedSec)}',
                      style: GoogleFonts.inter(
                        color: AppColors.stone,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline, color: AppColors.stone),
                onPressed: () => _t.deleteSaved(tr.id),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = _t.state != TrackState.idle;
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      appBar: AppBar(
        title: Text(
          'TREK TRACKER',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: 'Camp waypoints',
            icon: const Icon(Icons.flag_outlined, color: AppColors.snow),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CampWaypointsScreen()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
        children: [
          if (_t.statusMessage != null)
            _banner(_t.statusMessage!, Colors.orangeAccent, Icons.gps_off),
          if (_t.recoveredTrek)
            _banner(
              'An unfinished trek was recovered. Resume it or finish to save it.',
              AppColors.skyBlue,
              Icons.restore,
            ),
          _buildMap(),
          const SizedBox(height: 12),
          _buildGpsInfo(),
          const SizedBox(height: 12),
          Row(
            children: [
              _stat(
                'DISTANCE',
                active || _t.distanceM > 0 ? formatKm(_t.distanceM) : '—',
              ),
              _stat('ELAPSED', formatDuration(_t.elapsed.inSeconds)),
              _stat('MOVING', formatDuration(_t.movingSec.round())),
            ],
          ),
          Row(
            children: [
              _stat('PACE', formatPace(_t.movingSec, _t.distanceM)),
              _stat(
                'ELEV. GAIN',
                _t.maxAltitude == null ? '—' : '+${_t.gainM.round()} m',
              ),
              _stat('POINTS', '${_t.points.length}'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _t.hasTodayGps
                ? 'Today: ${formatKm(_t.todayDistanceM)} recorded by GPS'
                : 'No GPS distance recorded today.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(color: AppColors.stone, fontSize: 12),
          ),
          const SizedBox(height: 14),
          _buildControls(),
          const SizedBox(height: 20),
          _buildCampCard(),
          const SizedBox(height: 28),
          Text(
            'SAVED TREKS',
            style: GoogleFonts.oswald(
              color: AppColors.stone,
              fontSize: 12,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          if (_t.history.isEmpty)
            Text(
              'No saved treks yet. Start a trek, then finish it to save it with its route.',
              style: GoogleFonts.inter(color: AppColors.stone, fontSize: 12),
            )
          else
            ..._t.history.map(_historyCard),
        ],
      ),
    );
  }
}

// ---------------- SAVED ROUTE VIEWER ----------------

class TrekRouteScreen extends StatelessWidget {
  final SavedTrek trek;
  const TrekRouteScreen({super.key, required this.trek});

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(k, style: GoogleFonts.inter(color: AppColors.stone, fontSize: 12)),
        Text(
          v,
          style: GoogleFonts.inter(
            color: AppColors.snow,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final pts = trek.points;
    latlong.LatLng center = _kDefaultMapCenter;
    double zoom = 14;
    if (pts.isNotEmpty) {
      final lats = pts.map((p) => p.lat);
      final lons = pts.map((p) => p.lon);
      final minLat = lats.reduce(min), maxLat = lats.reduce(max);
      final minLon = lons.reduce(min), maxLon = lons.reduce(max);
      center = latlong.LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2);
      zoom = _zoomForSpan(max(maxLat - minLat, maxLon - minLon));
    }
    final lines = <Polyline>[];
    for (final seg in routeSegments(pts)) {
      if (seg.length > 1) {
        lines.add(Polyline(points: seg, strokeWidth: 5, color: AppColors.gold));
      }
    }
    final markers = <Marker>[];
    if (pts.isNotEmpty) {
      markers.add(
        Marker(
          point: pts.first.latLng,
          width: 36,
          height: 36,
          child: const Icon(
            Icons.trip_origin,
            color: AppColors.green,
            size: 26,
          ),
        ),
      );
      markers.add(
        Marker(
          point: pts.last.latLng,
          width: 36,
          height: 36,
          child: const Icon(Icons.location_on, color: AppColors.red, size: 32),
        ),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      appBar: AppBar(
        title: Text('ROUTE', style: Theme.of(context).textTheme.titleLarge),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
        children: [
          Text(
            trek.name,
            style: GoogleFonts.oswald(
              color: AppColors.snow,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            '${formatDate(trek.start)}  •  ${formatTime(trek.start)} to ${formatTime(trek.end)}',
            style: GoogleFonts.inter(color: AppColors.stone, fontSize: 12),
          ),
          const SizedBox(height: 14),
          if (pts.length < 2)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.cardDark,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Text(
                'No GPS route points were recorded for this trek.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(color: AppColors.stone),
              ),
            )
          else
            Container(
              height: 320,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: FlutterMap(
                options: MapOptions(initialCenter: center, initialZoom: zoom),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.flutter_application_1',
                  ),
                  PolylineLayer(polylines: lines),
                  MarkerLayer(markers: markers),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.cardDark,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Column(
              children: [
                _row('Distance', formatKm(trek.distanceM)),
                _row('Elapsed time', formatDuration(trek.elapsedSec)),
                if (trek.movingSec > 0) ...[
                  _row('Moving time', formatDuration(trek.movingSec)),
                  _row(
                    'Average pace',
                    formatPace(trek.movingSec.toDouble(), trek.distanceM),
                  ),
                ],
                _row(
                  'Elevation gain',
                  trek.maxAlt == null ? '—' : '+${trek.gainM.round()} m',
                ),
                _row(
                  'Highest altitude',
                  trek.maxAlt == null ? '—' : '${trek.maxAlt!.round()} m',
                ),
                _row('Route points', '${trek.points.length}'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- CAMP WAYPOINT SETUP ----------------

class CampWaypointsScreen extends StatefulWidget {
  const CampWaypointsScreen({super.key});
  @override
  State<CampWaypointsScreen> createState() => _CampWaypointsScreenState();
}

class _CampWaypointsScreenState extends State<CampWaypointsScreen> {
  final TrekTracker _t = TrekTracker.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _t.addListener(_onChange);
  }

  @override
  void dispose() {
    _t.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.forest),
    );
  }

  Future<void> _useHere(int stage) async {
    setState(() => _busy = true);
    await _t.refreshPosition();
    if (!mounted) return;
    setState(() => _busy = false);
    final p = _t.lastPosition;
    if (p == null) {
      _toast(_t.statusMessage ?? 'No GPS fix yet.');
      return;
    }
    if (p.accuracy > kWaypointMaxAccuracyM) {
      _toast(
        'GPS accuracy is only ±${p.accuracy.round()} m. Move outdoors with a clear sky and try again.',
      );
      return;
    }
    final wp = _t.waypoints[stage];
    _t.setWaypoint(
      stage,
      wp.located(p.latitude, p.longitude, _t.currentAltitude, wp.radiusM),
    );
    _toast('${wp.name} set to your current position.');
  }

  Future<void> _edit(int stage) async {
    final wp = _t.waypoints[stage];
    final latC = TextEditingController(text: wp.lat?.toString() ?? '');
    final lonC = TextEditingController(text: wp.lon?.toString() ?? '');
    final altC = TextEditingController(text: wp.altM?.round().toString() ?? '');
    final radC = TextEditingController(text: wp.radiusM.round().toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.charcoal,
        title: Text(
          wp.name,
          style: GoogleFonts.oswald(
            color: AppColors.snow,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final f in [
                ['Latitude (e.g. 35.8825)', latC],
                ['Longitude (e.g. 76.5133)', lonC],
                ['Altitude in metres (optional)', altC],
                ['Detection radius in metres', radC],
              ])
                TextField(
                  controller: f[1] as TextEditingController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  style: const TextStyle(color: AppColors.snow),
                  decoration: InputDecoration(
                    labelText: f[0] as String,
                    labelStyle: const TextStyle(color: AppColors.stone),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'CANCEL',
              style: TextStyle(color: AppColors.stone),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.gold),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'SAVE',
              style: TextStyle(color: AppColors.charcoal),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final lat = double.tryParse(latC.text.trim());
    final lon = double.tryParse(lonC.text.trim());
    final alt = double.tryParse(altC.text.trim());
    final rad = double.tryParse(radC.text.trim()) ?? 150;
    if (lat == null ||
        lon == null ||
        lat < -90 ||
        lat > 90 ||
        lon < -180 ||
        lon > 180) {
      _toast('Enter a valid latitude (-90 to 90) and longitude (-180 to 180).');
      return;
    }
    if (rad < 20 || rad > 2000) {
      _toast('Radius must be between 20 and 2000 metres.');
      return;
    }
    _t.setWaypoint(stage, wp.located(lat, lon, alt, rad));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.charcoal,
      appBar: AppBar(
        title: Text(
          'CAMP WAYPOINTS',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white10),
            ),
            child: Text(
              'GPS can only detect a camp if it knows where the camp is. Set real '
              'coordinates for each camp (stand at the camp and tap USE MY LOCATION, '
              'or type them in). While tracking, a camp is marked reached only when '
              'your GPS accuracy is 50 m or better and you stay inside the radius for '
              '3 readings in a row. If you also set an altitude, the GPS altitude '
              'must be within 150 m of it. You can always confirm a camp manually '
              'instead.',
              style: GoogleFonts.inter(
                color: AppColors.stone,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 16),
          ...List.generate(4, (i) {
            final wp = _t.waypoints[i];
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.cardDark,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.flag,
                        size: 18,
                        color: wp.isSet ? AppColors.green : AppColors.stone,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        wp.name,
                        style: GoogleFonts.oswald(
                          color: AppColors.snow,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    wp.isSet
                        ? '${wp.lat!.toStringAsFixed(5)}, ${wp.lon!.toStringAsFixed(5)}'
                              '${wp.altM != null ? '  •  ${wp.altM!.round()} m' : ''}'
                              '  •  radius ${wp.radiusM.round()} m'
                        : 'Not set. Camp detection is manual only.',
                    style: GoogleFonts.inter(
                      color: AppColors.stone,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _useHere(i),
                        icon: const Icon(Icons.my_location, size: 14),
                        label: const Text('USE MY LOCATION'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.gold,
                          side: const BorderSide(color: AppColors.gold),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () => _edit(i),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.skyBlue,
                          side: const BorderSide(color: AppColors.skyBlue),
                        ),
                        child: const Text('EDIT'),
                      ),
                      if (wp.isSet)
                        TextButton(
                          onPressed: () => _t.setWaypoint(i, wp.cleared()),
                          child: const Text(
                            'CLEAR',
                            style: TextStyle(color: AppColors.stone),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
// ==========================================
// JOURNEY ROUTE LOADER + LOGOUT
// ==========================================

/// Opens the recorded route of a Journey entry. Server treks fetch their GPS points first.

/// Opens the recorded route of a Journey entry.
/// Server treks fetch their GPS points first.
Future<void> openRecordRoute(BuildContext context, ExpeditionRecord r) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);

  // Offline route
  if (!r.fromServer) {
    if (r.routePoints.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No GPS route points are available for this trek.'),
          backgroundColor: AppColors.forest,
        ),
      );
      return;
    }

    nav.push(
      MaterialPageRoute(
        builder: (_) => JourneyMapScreen(initialCenter: r.routePoints.first),
      ),
    );
    return;
  }

  try {
    final id = int.tryParse(r.id);

    if (id == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Invalid trek ID.')));
      return;
    }

    final data = await ApiService().getTrek(id);

    if (!context.mounted) return;

    if (data == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not load the route from the server.'),
          backgroundColor: AppColors.forest,
        ),
      );
      return;
    }

    final rawPoints = data['points'];

    if (rawPoints is! List || rawPoints.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No recorded GPS points were found for this trek.'),
          backgroundColor: AppColors.forest,
        ),
      );
      return;
    }

    final pts = <TrackPoint>[];
    int segment = 0;
    DateTime? previousTime;

    for (final entry in rawPoints) {
      if (entry is! Map) continue;

      final point = Map<String, dynamic>.from(entry);

      final latValue = point['lat'];
      final lonValue = point['lon'];

      if (latValue is! num || lonValue is! num) continue;

      final latitude = latValue.toDouble();
      final longitude = lonValue.toDouble();

      if (!latitude.isFinite ||
          !longitude.isFinite ||
          latitude < -90 ||
          latitude > 90 ||
          longitude < -180 ||
          longitude > 180) {
        continue;
      }

      final recordedAt =
          DateTime.tryParse('${point['recorded_at'] ?? ''}')?.toLocal() ??
          DateTime.now();

      if (previousTime != null &&
          recordedAt.difference(previousTime).inMinutes > 10) {
        segment++;
      }

      previousTime = recordedAt;

      final altitude = point['alt'];
      final accuracy = point['accuracy'];

      pts.add(
        TrackPoint(
          lat: latitude,
          lon: longitude,
          alt: altitude is num ? altitude.toDouble() : null,
          acc: accuracy is num ? accuracy.toDouble() : 0,
          t: recordedAt,
          seg: segment,
        ),
      );
    }

    if (pts.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('The server returned no valid GPS coordinates.'),
          backgroundColor: AppColors.forest,
        ),
      );
      return;
    }

    final trek = SavedTrek(
      id: r.id,
      name: r.title,
      start: r.date,
      end: r.date.add(r.duration),
      distanceM: r.distanceKm * 1000,
      movingSec: 0,
      elapsedSec: r.duration.inSeconds,
      gainM: r.elevationGainM.toDouble(),
      maxAlt: r.maxAltitudeM > 0 ? r.maxAltitudeM.toDouble() : null,
      points: pts,
    );

    nav.push(MaterialPageRoute(builder: (_) => TrekRouteScreen(trek: trek)));
  } catch (e) {
    if (!context.mounted) return;

    messenger.showSnackBar(
      SnackBar(
        content: Text('Unable to open trek route: $e'),
        backgroundColor: AppColors.forest,
      ),
    );
  }
}

/// Confirms, then signs out and clears this user's phone data.
Future<void> confirmLogout(BuildContext context) async {
  final api = ApiService();

  try {
    final pendingSos = await api.pendingSosCount();
    final tracking = TrekTracker.instance.isActive;

    if (!context.mounted) return;

    final warnings = <String>[
      if (pendingSos > 0)
        '$pendingSos SOS alert(s) have NOT been sent and may be discarded.',
      if (tracking) 'A GPS trek is still being recorded and may be discarded.',
      'Anything on this phone that has not synced to the server may be lost.',
    ];

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.charcoal,
        title: Text(
          'LOG OUT?',
          style: GoogleFonts.oswald(
            color: AppColors.snow,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          warnings.join('\n\n'),
          style: GoogleFonts.inter(color: AppColors.stone),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'CANCEL',
              style: TextStyle(color: AppColors.stone),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('LOG OUT'),
          ),
        ],
      ),
    );

    if (ok != true || !context.mounted) return;

    await api.signOutAndClear();

    primaryContactPhone.value = '';

    TrekTracker.instance.resetForLogout();
    ChecklistStore.instance.resetMemory();

    if (!context.mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthScreen()),
      (route) => false,
    );
  } catch (e) {
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Logout failed: $e'),
        backgroundColor: AppColors.red,
      ),
    );
  }
}

// ------------------------------------------------------------
// VIDEO PLAYER
// ------------------------------------------------------------

class VideoPlayerScreen extends StatefulWidget {
  final String title;
  final String? asset;
  final String? url;

  const VideoPlayerScreen({
    super.key,
    required this.title,
    this.asset,
    this.url,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _controller;

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    if (!mounted) return;

    final oldController = _controller;
    _controller = null;

    oldController?.removeListener(_tick);
    await oldController?.dispose();

    if (!mounted) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final asset = widget.asset;
      final url = widget.url;
      debugPrint('🎬 Video asset: $asset');
      debugPrint('🎬 Video URL: $url');
      if ((asset == null || asset.trim().isEmpty) &&
          (url == null || url.trim().isEmpty)) {
        throw Exception('No video asset or URL was provided.');
      }

      final controller = asset != null && asset.trim().isNotEmpty
          ? VideoPlayerController.asset(asset)
          : VideoPlayerController.networkUrl(Uri.parse(url!));

      _controller = controller;

      await controller.initialize().timeout(const Duration(seconds: 30));
      debugPrint('🎬 Video initialized: ${controller.value.isInitialized}');
      debugPrint('🎬 Video duration: ${controller.value.duration}');
      debugPrint('🎬 Video size: ${controller.value.size}');
      debugPrint('🎬 Video error: ${controller.value.errorDescription}');
      if (!mounted || _controller != controller) {
        await controller.dispose();
        return;
      }

      controller.addListener(_tick);

      await controller.play();

      if (!mounted) return;

      setState(() {
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      final failedController = _controller;
      _controller = null;

      failedController?.removeListener(_tick);
      await failedController?.dispose();

      if (!mounted) return;

      setState(() {
        _loading = false;
        _error =
            'This phone could not play the video.\n\n'
            'Check that the video file exists, the URL is accessible, '
            'and the format is supported by Android.\n\n'
            'Recommended format: MP4 with H.264 video and AAC audio.\n\n'
            'Details: $e';
      });
    }
  }

  void _tick() {
    final controller = _controller;

    if (!mounted || controller == null) return;

    if (controller.value.hasError && _error == null) {
      setState(() {
        _error = 'Playback error: ${controller.value.errorDescription}';
      });
    } else {
      setState(() {});
    }
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        await controller.play();
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Could not control video playback: $e';
      });
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    _controller = null;

    controller?.removeListener(_tick);
    controller?.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    Widget body;

    if (_loading) {
      body = const Center(
        child: CircularProgressIndicator(color: AppColors.gold),
      );
    } else if (_error != null ||
        controller == null ||
        !controller.value.isInitialized) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: AppColors.red, size: 40),
              const SizedBox(height: 12),
              Text(
                _error ?? 'Video unavailable.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(color: AppColors.snow, fontSize: 12),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                ),
                onPressed: _initializeVideo,
                child: const Text(
                  'RETRY',
                  style: TextStyle(color: AppColors.charcoal),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      body = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AspectRatio(
            aspectRatio: controller.value.aspectRatio > 0
                ? controller.value.aspectRatio
                : 16 / 9,
            child: VideoPlayer(controller),
          ),
          const SizedBox(height: 12),
          VideoProgressIndicator(
            controller,
            allowScrubbing: true,
            colors: const VideoProgressColors(playedColor: AppColors.gold),
          ),
          IconButton(
            iconSize: 48,
            color: AppColors.gold,
            icon: Icon(
              controller.value.isPlaying
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_filled,
            ),
            onPressed: _togglePlayback,
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          widget.title,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        backgroundColor: Colors.transparent,
      ),
      body: body,
    );
  }
}
