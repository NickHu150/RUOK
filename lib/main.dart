import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RUOKApp());
}

class RUOKApp extends StatelessWidget {
  const RUOKApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RUOK?',
      debugShowCheckedModeBanner: false,
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
  String _status = 'Initializing...';
  String _nextCheckIn = 'Unknown';
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
        _status = 'System Active';
      } else {
        _hasCheckedInToday = false;
        _status = 'System Inactive\nPlease configure settings';
      }
    });
  }

  Future<void> _checkIn() async {
    if (_hasCheckedInToday) {
      _showSnackBar('You have checked in today. Please come back tomorrow.');
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
        'I have been out of contact for $delayDays days. Please check on me.';

    if (emergencyEmail.isEmpty) {
      _showSnackBar('Please set an emergency email in settings first.');
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

        _showSnackBar('Check-in successful. Stay safe.');
        _loadStatus();
      } else {
        _showSnackBar('Failed: ${response.body}');
      }
    } catch (e) {
      _showSnackBar('Error: $e');
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
      _showSnackBar('Could not launch page: $url');
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
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'RUOK?',
                      style: TextStyle(
                        fontSize: 48,
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
                      const SizedBox(height: 20),
                      GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const SettingsPage(),
                          ),
                        ).then((_) => _loadStatus()),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.red.withOpacity(0.5),
                            ),
                          ),
                          child: const Text(
                            '⚠️ Setup your emergency contact and message to enable automated safety alerts',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.redAccent,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 60),
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
                              ? (_animationController.value * 0.5 + 0.5)
                              : 0.2;

                          return Transform.scale(
                            scale: currentScale,
                            child: Container(
                              width: 220,
                              height: 220,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _hasCheckedInToday
                                    ? const Color(0xFF10B981)
                                    : Colors.transparent,
                                border: Border.all(
                                  color: _hasCheckedInToday
                                      ? const Color(0xFF10B981)
                                      : Theme.of(
                                          context,
                                        ).primaryColor.withOpacity(0.3),
                                  width: 2,
                                ),
                                boxShadow: [
                                  // Inner core glow
                                  BoxShadow(
                                    color:
                                        (_hasCheckedInToday
                                                ? const Color(0xFF10B981)
                                                : Theme.of(
                                                    context,
                                                  ).primaryColor)
                                            .withOpacity(
                                              _hasCheckedInToday
                                                  ? 0.6 * glowIntensity
                                                  : 0.1,
                                            ),
                                    blurRadius: _hasCheckedInToday ? 20 : 10,
                                    spreadRadius: _hasCheckedInToday ? 2 : 0,
                                  ),
                                  // Outer atmospheric glow
                                  if (_hasCheckedInToday)
                                    BoxShadow(
                                      color: const Color(
                                        0xFF10B981,
                                      ).withOpacity(0.3 * glowIntensity),
                                      blurRadius: 60,
                                      spreadRadius: 15,
                                    ),
                                  // Distant ambient glow
                                  if (_hasCheckedInToday)
                                    BoxShadow(
                                      color: const Color(
                                        0xFF10B981,
                                      ).withOpacity(0.15 * glowIntensity),
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
                                        children: [
                                          if (_hasCheckedInToday) ...[
                                            const Icon(
                                              Icons.favorite,
                                              size: 64,
                                              color: Colors.white,
                                            ),
                                            const SizedBox(height: 12),
                                            const Text(
                                              'Safe & Protected',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 16,
                                                fontWeight: FontWeight.w700,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                          ] else
                                            Text(
                                              'I\'M OK',
                                              style: TextStyle(
                                                fontSize: 28,
                                                fontWeight: FontWeight.w900,
                                                letterSpacing: 2,
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
                    const SizedBox(height: 60),
                    Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Next alert will be sent to your contact at:',
                      style: TextStyle(
                        color: Colors.grey.withOpacity(0.9),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _nextCheckIn,
                      style: TextStyle(
                        color: Theme.of(context).primaryColor.withOpacity(0.9),
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        letterSpacing: 1,
                      ),
                    ),
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
                      child: const Text(
                        'Terms of Use',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ),
                    const Text('|', style: TextStyle(color: Colors.grey)),
                  ],
                  TextButton(
                    onPressed: () => _launchURL(
                      'https://gowellapp.me/ruok/privacy_policy',
                      inApp: true,
                    ),
                    child: const Text(
                      'Privacy Policy',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
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
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _buildTextField(
            'Emergency Email',
            _emailController,
            TextInputType.emailAddress,
          ),
          const SizedBox(height: 20),
          _buildTextField(
            'Notification Message',
            _msgController,
            TextInputType.multiline,
            maxLines: 3,
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Delay Days (until alert)',
                style: TextStyle(color: Colors.grey),
              ),
              Text(
                '$_delayDays Days',
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
            label: '${_delayDays < 2 ? 2 : _delayDays} days',
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
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: Colors.orangeAccent, size: 20),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Note: RUOK? has no backend servers. All your settings are stored locally on this device. If you uninstall the app, all data will be permanently deleted.',
                    style: TextStyle(
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
            child: const Text(
              'SAVE SETTINGS',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
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
