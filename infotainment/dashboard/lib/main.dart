import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:dashboard_flutter/models/vehicle_config.dart';
import 'package:dashboard_flutter/models/page_config.dart';
import 'package:dashboard_flutter/services/config_service.dart';
import 'package:dashboard_flutter/views/infotainment_shell.dart';

void main() {
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('google_fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(['google_fonts'], license);
  });
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OVCS Infotainment',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const _BootScreen(),
    );
  }
}

/// Fetches vehicle configuration and pages from the API at startup,
/// then hands off to the InfotainmentShell.
class _BootScreen extends StatefulWidget {
  const _BootScreen();

  @override
  State<_BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<_BootScreen> {
  VehicleConfig? _vehicleConfig;
  List<PageConfig>? _pages;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final results = await Future.wait([
        ConfigService.fetchVehicle(),
        ConfigService.fetchPages(),
      ]);
      if (!mounted) return;
      setState(() {
        _vehicleConfig = results[0] as VehicleConfig;
        _pages = results[1] as List<PageConfig>;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Text(
                'Failed to load configuration',
                style: const TextStyle(color: Colors.white, fontSize: 18),
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Colors.grey, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              TextButton(
                onPressed: () {
                  setState(() { _error = null; });
                  _loadConfig();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_vehicleConfig == null || _pages == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return InfotainmentShell(
      vehicleConfig: _vehicleConfig!,
      pages: _pages!,
    );
  }
}

ThemeData _buildTheme() {
  var baseTheme = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
    scaffoldBackgroundColor: Colors.black,
  );

  return baseTheme.copyWith(
    textTheme: GoogleFonts.latoTextTheme(baseTheme.textTheme),
  );
}
