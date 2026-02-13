import 'package:flutter/material.dart';
import 'package:dashboard_flutter/models/page_config.dart';

/// Icon name to Material Icon mapping.
/// The backend page definition includes an `icon` string (e.g. "dashboard",
/// "battery", "settings"). This maps those strings to Material Icons.
const Map<String, IconData> _iconMap = {
  'dashboard': Icons.dashboard_rounded,
  'speed': Icons.speed_rounded,
  'battery': Icons.battery_full_rounded,
  'settings': Icons.settings_rounded,
  'car': Icons.directions_car_rounded,
  'charging': Icons.ev_station_rounded,
  'thermostat': Icons.thermostat_rounded,
  'network': Icons.wifi_rounded,
  'music': Icons.music_note_rounded,
  'navigation': Icons.navigation_rounded,
  'phone': Icons.phone_rounded,
  'map': Icons.map_rounded,
  'radio': Icons.radio_rounded,
  'info': Icons.info_rounded,
};

/// A fullscreen launcher overlay inspired by Apple CarPlay.
///
/// Shows all available pages as icon tiles in a centered grid.
/// Tapping a tile navigates to that page and dismisses the launcher.
/// Tapping the background also dismisses the launcher.
class LauncherScreen extends StatelessWidget {
  final List<PageConfig> pages;
  final String activePageId;
  final ValueChanged<String> onPageSelected;
  final VoidCallback onClose;

  const LauncherScreen({
    super.key,
    required this.pages,
    required this.activePageId,
    required this.onPageSelected,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onClose,
      child: Container(
        color: const Color(0xF0000000),
        child: Center(
          child: GestureDetector(
            onTap: () {}, // prevent tap-through to the dismiss layer
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 40),
              child: Wrap(
                spacing: 30,
                runSpacing: 30,
                alignment: WrapAlignment.center,
                children: pages.map((page) => _PageTile(
                  page: page,
                  isActive: page.id == activePageId,
                  onTap: () => onPageSelected(page.id),
                )).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PageTile extends StatelessWidget {
  final PageConfig page;
  final bool isActive;
  final VoidCallback onTap;

  const _PageTile({
    required this.page,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final icon = _iconMap[page.icon] ?? Icons.widgets_rounded;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: isActive
                  ? const Color(0xFF6D28D9)
                  : const Color(0xFF1F2937),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isActive
                    ? const Color(0xFF8B5CF6)
                    : const Color(0x33FFFFFF),
                width: 1.5,
              ),
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: 36,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            page.name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'Lato',
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }
}
