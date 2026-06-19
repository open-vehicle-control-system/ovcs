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
///   - Launcher overlay with fade+scale transition
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

class _InfotainmentShellState extends State<InfotainmentShell>
    with SingleTickerProviderStateMixin {
  late String _activePageId;
  bool _launcherVisible = false;

  late final AnimationController _launcherAnimController;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _scaleAnimation;

  static const Duration _animDuration = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    _activePageId = widget.pages.isNotEmpty ? widget.pages.first.id : '';

    _launcherAnimController = AnimationController(
      vsync: this,
      duration: _animDuration,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _launcherAnimController,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );

    _scaleAnimation = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(
        parent: _launcherAnimController,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );

    _launcherAnimController.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) {
        setState(() {
          _launcherVisible = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _launcherAnimController.dispose();
    super.dispose();
  }

  void _openLauncher() {
    setState(() {
      _launcherVisible = true;
    });
    _launcherAnimController.forward();
  }

  void _closeLauncher() {
    _launcherAnimController.reverse();
    // _launcherVisible set to false by the status listener when dismissed
  }

  void _selectPage(String pageId) {
    setState(() {
      _activePageId = pageId;
    });
    _closeLauncher();
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
                vehicleModule: widget.vehicleConfig.module,
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

          // Layer 2: Launcher overlay with fade + scale transition
          if (_launcherVisible)
            Positioned.fill(
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: ScaleTransition(
                  scale: _scaleAnimation,
                  child: LauncherScreen(
                    pages: widget.pages,
                    activePageId: _activePageId,
                    onPageSelected: _selectPage,
                    onClose: _closeLauncher,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
