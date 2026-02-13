import 'package:flutter/material.dart';
import 'package:dashboard_flutter/models/vehicle_config.dart';
import 'package:dashboard_flutter/models/page_config.dart';
import 'package:dashboard_flutter/views/dynamic_page.dart';
import 'package:dashboard_flutter/components/launcher_screen.dart';
import 'package:dashboard_flutter/components/status_bar.dart';

/// The main composable shell for the infotainment app.
///
/// Layout:
///   - Fullscreen DynamicPage for the active page
///   - Thin status bar at the top (time, temperature, 12V battery)
///   - Launcher button in the bottom-left corner
///   - Launcher overlay (CarPlay-style grid of page icons)
class InfotainmentShell extends StatefulWidget {
  final VehicleConfig vehicleConfig;
  final List<PageConfig> pages;

  const InfotainmentShell({
    super.key,
    required this.vehicleConfig,
    required this.pages,
  });

  @override
  State<InfotainmentShell> createState() => _InfotainmentShellState();
}

class _InfotainmentShellState extends State<InfotainmentShell> {
  late String _activePageId;
  bool _launcherOpen = false;

  @override
  void initState() {
    super.initState();
    // Default to the first page
    _activePageId = widget.pages.isNotEmpty ? widget.pages.first.id : '';
  }

  void _openLauncher() {
    setState(() { _launcherOpen = true; });
  }

  void _closeLauncher() {
    setState(() { _launcherOpen = false; });
  }

  void _selectPage(String pageId) {
    setState(() {
      _activePageId = pageId;
      _launcherOpen = false;
    });
  }

  PageConfig? get _activePage {
    try {
      return widget.pages.firstWhere((p) => p.id == _activePageId);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final activePage = _activePage;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Layer 1: Active page content (fullscreen)
          if (activePage != null)
            Positioned.fill(
              child: DynamicPage(
                key: ValueKey(_activePageId),
                pageId: _activePageId,
                vehicleConfig: widget.vehicleConfig,
                backgroundImage: activePage.backgroundImage,
              ),
            ),

          // Layer 2: Status bar at the top
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: StatusBar(vehicleName: widget.vehicleConfig.name),
          ),

          // Layer 3: Launcher button (bottom-left)
          Positioned(
            bottom: 20,
            left: 20,
            child: _LauncherButton(onPressed: _openLauncher),
          ),

          // Layer 4: Launcher overlay
          if (_launcherOpen)
            Positioned.fill(
              child: LauncherScreen(
                pages: widget.pages,
                activePageId: _activePageId,
                onPageSelected: _selectPage,
                onClose: _closeLauncher,
              ),
            ),
        ],
      ),
    );
  }
}

class _LauncherButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _LauncherButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xCC1F2937),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0x33FFFFFF),
            width: 1,
          ),
        ),
        child: const Icon(
          Icons.apps_rounded,
          color: Colors.white,
          size: 28,
        ),
      ),
    );
  }
}
