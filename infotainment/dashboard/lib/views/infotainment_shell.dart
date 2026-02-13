import 'package:flutter/material.dart';
import 'package:dashboard_flutter/models/vehicle_config.dart';
import 'package:dashboard_flutter/models/page_config.dart';
import 'package:dashboard_flutter/views/dynamic_page.dart';
import 'package:dashboard_flutter/components/launcher_screen.dart';
import 'package:dashboard_flutter/components/side_bar.dart';

/// The main composable shell for the infotainment app.
///
/// Layout:
///   - Left sidebar (time, date, temperature, 12V battery, launcher button)
///   - DynamicPage content area filling the remaining width
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
    _activePageId = widget.pages.isNotEmpty ? widget.pages.first.id : '';
  }

  void _openLauncher() {
    setState(() {
      _launcherOpen = true;
    });
  }

  void _closeLauncher() {
    setState(() {
      _launcherOpen = false;
    });
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
          // Layer 1: Main layout — sidebar + content
          Row(
            children: [
              // Left sidebar
              SideBar(
                vehicleName: widget.vehicleConfig.name,
                sidebarConfig: widget.vehicleConfig.sidebar,
                onLauncherPressed: _openLauncher,
              ),
              // Content area
              Expanded(
                child: activePage != null
                    ? DynamicPage(
                        key: ValueKey(_activePageId),
                        pageId: _activePageId,
                        vehicleConfig: widget.vehicleConfig,
                        backgroundImage: activePage.backgroundImage,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),

          // Layer 2: Launcher overlay (fullscreen, above everything)
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
