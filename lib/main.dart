import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:url_launcher/url_launcher.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:easy_localization/easy_localization.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();

  runApp(
    EasyLocalization(
      supportedLocales: const [
        Locale('en'),
        Locale('zh', 'Hans'),
        Locale('zh', 'Hant'),
        Locale('ja'),
        Locale('ko'),
        Locale('th'),
        Locale('vi'),
        Locale('id'),
        Locale('ms'),
        Locale('hi'),
        Locale('tl'),
        Locale('es'),
        Locale('pt'),
        Locale('fr'),
        Locale('de'),
        Locale('it'),
        Locale('ru'),
        Locale('nl'),
        Locale('tr'),
        Locale('pl'),
        Locale('uk'),
        Locale('ar'),
      ],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      child: const RUOKApp(),
    ),
  );
}

class RUOKApp extends StatelessWidget {
  const RUOKApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RUOK?',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        primaryColor: const Color(0xFF00FF41), // Matrix Green
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00FF41),
          secondary: Color(0xFFFF3131),
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _breathAnimation;
  String _status = 'initializing'; // key
  String _nextCheckIn = 'unknown'; // key or date string
  bool _isLoading = false;
  bool _hasCheckedInToday = false;
  bool _isConfigured = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _breathAnimation = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeInOutSine,
      ),
    );

    _loadStatus();
    _primeNetwork(); // Pre-trigger network permission dialog
  }

  Future<void> _primeNetwork() async {
    try {
      // Small dummy request to force iOS to show the network permission dialog
      // before the user actually tries to check-in for the first time.
      await http
          .get(Uri.parse('https://www.google.com'))
          .timeout(const Duration(seconds: 1));
    } catch (_) {
      // Ignore results/errors
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    debugPrint('[RUOK] Loading status from local storage...');
    final prefs = await SharedPreferences.getInstance();
    final lastCheckIn = prefs.getString('last_checkin_time');
    final delayDays = prefs.getInt('delay_days') ?? 3;
    final lastEmailId = prefs.getString('last_email_id');
    final email = prefs.getString('emergency_email') ?? '';

    debugPrint(
      '[RUOK] Loaded: LastCheckIn=$lastCheckIn, DelayDays=$delayDays, LastEmailId=$lastEmailId',
    );

    setState(() {
      _isConfigured = email.isNotEmpty;
      if (lastCheckIn != null) {
        final lastDate = DateTime.parse(lastCheckIn);
        final now = DateTime.now();
        // Check if same calendar day
        _hasCheckedInToday =
            lastDate.year == now.year &&
            lastDate.month == now.month &&
            lastDate.day == now.day;

        final nextDate = lastDate.add(Duration(days: delayDays));
        _nextCheckIn = DateFormat('yyyy-MM-dd HH:mm').format(nextDate);
        _status = 'system_active';
      } else {
        _hasCheckedInToday = false;
        _status = 'system_inactive';
        _nextCheckIn = 'unknown';
      }
    });
  }

  Future<void> _checkIn() async {
    if (_hasCheckedInToday) {
      _showSnackBar('already_checked_in'.tr());
      return;
    }

    debugPrint('[RUOK] Starting Check-In process...');
    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();

    // Hardcoded connection settings for reliability
    const workerUrl = 'https://ruok.huyamin150.workers.dev';
    const authSecret = 'my_private_token_2025';

    final emergencyEmail = prefs.getString('emergency_email') ?? '';
    final delayDays = prefs.getInt('delay_days') ?? 3;
    final lastEmailId = prefs.getString('last_email_id');
    final message =
        prefs.getString('message') ??
        'default_message'.tr(args: [delayDays.toString()]);

    if (emergencyEmail.isEmpty) {
      _showSnackBar('err_no_email'.tr());
      setState(() => _isLoading = false);
      return;
    }

    try {
      // 1. Cancel previous email if exists
      if (lastEmailId != null && lastEmailId.isNotEmpty) {
        await http.post(
          Uri.parse('$workerUrl/cancel'),
          headers: {
            'Authorization': authSecret,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'id': lastEmailId}),
        );
      }

      // 2. Schedule new email
      final nextDateTime = DateTime.now().add(Duration(days: delayDays));
      final sendAt = nextDateTime.toUtc().toIso8601String();

      final response = await http.post(
        Uri.parse('$workerUrl/send'),
        headers: {
          'Authorization': authSecret,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'from': 'RUOK <ruok@gowellapp.me>',
          'to': emergencyEmail,
          'subject': 'Emergency Contact from RUOK?',
          'html':
              '<p>$message</p><p>Sent automatically by RUOK? Dead Man\'s Switch.</p>',
          'scheduled_at': sendAt,
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        final newEmailId = data['id'];

        await prefs.setString('last_email_id', newEmailId);
        await prefs.setString(
          'last_checkin_time',
          DateTime.now().toIso8601String(),
        );

        _showSnackBar('check_in_success'.tr());
        _loadStatus();
      } else {
        _showSnackBar('err_failed'.tr(args: [response.body]));
      }
    } catch (e) {
      _showSnackBar('err_unknown'.tr(args: [e.toString()]));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _launchURL(String url, {bool inApp = false}) async {
    debugPrint('[RUOK] Attempting to launch URL: $url (inApp: $inApp)');
    final uri = Uri.parse(url);
    try {
      final success = await launchUrl(
        uri,
        mode: inApp ? LaunchMode.inAppWebView : LaunchMode.platformDefault,
      );
      if (!success) {
        debugPrint(
          '[RUOK] Launch failed (returned false). Trying platform default...',
        );
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (e) {
      debugPrint('[RUOK] Error launching URL: $e');
      _showSnackBar('err_launch'.tr(args: [url]));
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isIOS = !kIsWeb && Platform.isIOS;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.grey),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SettingsPage()),
            ).then((_) => _loadStatus()),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    children: [
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              const SizedBox(height: 20),
                              Image.asset(
                                'assets/images/app_icon.png',
                                width: 80,
                                height: 80,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'app_title'.tr(),
                                style: TextStyle(
                                  fontSize: 42,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 8,
                                  color: Theme.of(context).primaryColor,
                                  shadows: [
                                    Shadow(
                                      blurRadius: 20,
                                      color: Theme.of(
                                        context,
                                      ).primaryColor.withOpacity(0.5),
                                    ),
                                  ],
                                ),
                              ),
                              if (!_isConfigured) ...[
                                const SizedBox(height: 12),
                                GestureDetector(
                                  onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) =>
                                          const SettingsPage(),
                                    ),
                                  ).then((_) => _loadStatus()),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: Colors.red.withOpacity(0.5),
                                      ),
                                    ),
                                    child: Text(
                                      'setup_hint'.tr(),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.redAccent,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 20),
                              GestureDetector(
                                onTap: _isLoading ? null : _checkIn,
                                child: AnimatedBuilder(
                                  animation: _breathAnimation,
                                  builder: (context, child) {
                                    // Only breathe if checked-in or just idle in a nice way
                                    final currentScale = _hasCheckedInToday
                                        ? _breathAnimation.value
                                        : 1.0;
                                    final glowIntensity = _hasCheckedInToday
                                        ? (_animationController.value * 0.5 +
                                              0.5)
                                        : 0.2;

                                    return Transform.scale(
                                      scale: currentScale,
                                      child: Container(
                                        width: 200,
                                        height: 200,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                        ),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: _hasCheckedInToday
                                              ? const Color(0xFF10B981)
                                              : Colors.transparent,
                                          border: Border.all(
                                            color: _hasCheckedInToday
                                                ? const Color(0xFF10B981)
                                                : Theme.of(context).primaryColor
                                                      .withOpacity(0.3),
                                            width: 2,
                                          ),
                                          boxShadow: [
                                            // Inner core glow
                                            BoxShadow(
                                              color:
                                                  (_hasCheckedInToday
                                                          ? const Color(
                                                              0xFF10B981,
                                                            )
                                                          : Theme.of(
                                                              context,
                                                            ).primaryColor)
                                                      .withOpacity(
                                                        _hasCheckedInToday
                                                            ? 0.6 *
                                                                  glowIntensity
                                                            : 0.1,
                                                      ),
                                              blurRadius: _hasCheckedInToday
                                                  ? 20
                                                  : 10,
                                              spreadRadius: _hasCheckedInToday
                                                  ? 2
                                                  : 0,
                                            ),
                                            // Outer atmospheric glow
                                            if (_hasCheckedInToday)
                                              BoxShadow(
                                                color: const Color(0xFF10B981)
                                                    .withOpacity(
                                                      0.3 * glowIntensity,
                                                    ),
                                                blurRadius: 60,
                                                spreadRadius: 15,
                                              ),
                                            // Distant ambient glow
                                            if (_hasCheckedInToday)
                                              BoxShadow(
                                                color: const Color(0xFF10B981)
                                                    .withOpacity(
                                                      0.15 * glowIntensity,
                                                    ),
                                                blurRadius: 100,
                                                spreadRadius: 30,
                                              ),
                                          ],
                                        ),
                                        child: Center(
                                          child: _isLoading
                                              ? const CircularProgressIndicator(
                                                  color: Colors.white,
                                                  strokeWidth: 3,
                                                )
                                              : Column(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.center,
                                                  children: [
                                                    if (_hasCheckedInToday) ...[
                                                      const Icon(
                                                        Icons.favorite,
                                                        size: 64,
                                                        color: Colors.white,
                                                      ),
                                                      const SizedBox(
                                                        height: 12,
                                                      ),
                                                      Text(
                                                        'status_ok'.tr(),
                                                        textAlign:
                                                            TextAlign.center,
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 16,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          letterSpacing: 0.5,
                                                        ),
                                                      ),
                                                    ] else
                                                      Text(
                                                        'check_in_button'.tr(),
                                                        textAlign:
                                                            TextAlign.center,
                                                        style: TextStyle(
                                                          fontSize: 22,
                                                          fontWeight:
                                                              FontWeight.w900,
                                                          letterSpacing: 1,
                                                          color: Theme.of(
                                                            context,
                                                          ).primaryColor,
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
                              const SizedBox(height: 20),
                              Text(
                                _status.tr(),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'next_alert_label'.tr(),
                                style: TextStyle(
                                  color: Colors.grey.withOpacity(0.9),
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _nextCheckIn.tr(),
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).primaryColor.withOpacity(0.9),
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace',
                                  letterSpacing: 1,
                                ),
                              ),
                              const SizedBox(height: 20),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (isIOS) ...[
                              TextButton(
                                onPressed: () => _launchURL(
                                  'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/',
                                ),
                                child: Text(
                                  'terms_of_use'.tr(),
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              const Text(
                                '|',
                                style: TextStyle(color: Colors.grey),
                              ),
                            ],
                            TextButton(
                              onPressed: () => _launchURL(
                                'https://gowellapp.me/ruok/privacy_policy',
                                inApp: true,
                              ),
                              child: Text(
                                'privacy_policy'.tr(),
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
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

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _emailController = TextEditingController();
  final _msgController = TextEditingController();
  int _delayDays = 3;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _emailController.text = prefs.getString('emergency_email') ?? '';
      _msgController.text = prefs.getString('message') ?? '';
      _delayDays = prefs.getInt('delay_days') ?? 3;
      if (_delayDays < 2) _delayDays = 2;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('emergency_email', _emailController.text);
    await prefs.setString('message', _msgController.text);
    await prefs.setInt('delay_days', _delayDays);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('settings_title'.tr())),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _buildTextField(
            'emergency_email'.tr(),
            _emailController,
            TextInputType.emailAddress,
          ),
          const SizedBox(height: 20),
          _buildTextField(
            'notification_msg'.tr(),
            _msgController,
            TextInputType.multiline,
            maxLines: 3,
          ),
          const SizedBox(height: 20),
          // Language Selector
          _buildLanguageSelector(),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'delay_days_label'.tr(),
                style: const TextStyle(color: Colors.grey),
              ),
              Text(
                'delay_days_unit'.tr(args: ['$_delayDays']),
                style: TextStyle(
                  color: Theme.of(context).primaryColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ],
          ),
          Slider(
            value: _delayDays.toDouble().clamp(2.0, 30.0),
            min: 2,
            max: 30,
            divisions: 28,
            activeColor: Theme.of(context).primaryColor,
            label: 'delay_days_unit'.tr(
              args: [(_delayDays < 2 ? 2 : _delayDays).toString()],
            ),
            onChanged: (v) => setState(() => _delayDays = v.toInt()),
          ),
          const SizedBox(height: 20),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withOpacity(0.3)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline,
                  color: Colors.orangeAccent,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'local_storage_warning'.tr(),
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
          ElevatedButton(
            onPressed: _saveSettings,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.black,
            ),
            child: Text(
              'save_settings_button'.tr(),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLanguageSelector() {
    final List<Map<String, dynamic>> languages = [
      {'name': 'English', 'locale': const Locale('en')},
      {'name': '简体中文', 'locale': const Locale('zh', 'Hans')},
      {'name': '繁體中文', 'locale': const Locale('zh', 'Hant')},
      {'name': '日本語', 'locale': const Locale('ja')},
      {'name': '한국어', 'locale': const Locale('ko')},
      {'name': 'Español', 'locale': const Locale('es')},
      {'name': 'Português', 'locale': const Locale('pt')},
      {'name': 'Français', 'locale': const Locale('fr')},
      {'name': 'Deutsch', 'locale': const Locale('de')},
      {'name': 'Italiano', 'locale': const Locale('it')},
      {'name': 'Русский', 'locale': const Locale('ru')},
      {'name': 'Nederlands', 'locale': const Locale('nl')},
      {'name': 'Türkçe', 'locale': const Locale('tr')},
      {'name': 'Polski', 'locale': const Locale('pl')},
      {'name': 'Українська', 'locale': const Locale('uk')},
      {'name': 'العربية', 'locale': const Locale('ar')},
      {'name': 'ไทย', 'locale': const Locale('th')},
      {'name': 'Tiếng Việt', 'locale': const Locale('vi')},
      {'name': 'Bahasa Indonesia', 'locale': const Locale('id')},
      {'name': 'Bahasa Melayu', 'locale': const Locale('ms')},
      {'name': 'Filipino', 'locale': const Locale('tl')},
      {'name': 'हिन्दी', 'locale': const Locale('hi')},
    ];

    return DropdownButtonFormField<Locale>(
      value: context.locale,
      decoration: InputDecoration(
        labelText: 'language_label'.tr(),
        border: const OutlineInputBorder(),
        hintText: 'Select Language',
      ),
      items: languages.map((lang) {
        return DropdownMenuItem<Locale>(
          value: lang['locale'] as Locale,
          child: Text(lang['name'] as String),
        );
      }).toList(),
      onChanged: (Locale? newLocale) {
        if (newLocale != null) {
          context.setLocale(newLocale);
        }
      },
    );
  }

  Widget _buildTextField(
    String label,
    TextEditingController controller,
    TextInputType type, {
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      keyboardType: type,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Theme.of(context).primaryColor),
        ),
      ),
    );
  }
}
