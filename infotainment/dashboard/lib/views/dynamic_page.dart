import 'package:flutter/material.dart';
import 'package:dashboard_flutter/models/block_config.dart';
import 'package:dashboard_flutter/models/vehicle_config.dart';
import 'package:dashboard_flutter/services/config_service.dart';
import 'package:dashboard_flutter/services/metrics_service.dart';
import 'package:dashboard_flutter/components/blocks/block_renderer.dart';

/// A dynamic page that fetches its block layout from the API
/// and renders blocks on a grid using explicit column/row positions,
/// applying the vehicle's global block_style and the page/vehicle
/// background_image.
class DynamicPage extends StatefulWidget {
  final String pageId;
  final String? backgroundImage;
  final VehicleConfig vehicleConfig;

  const DynamicPage({
    super.key,
    required this.pageId,
    required this.vehicleConfig,
    this.backgroundImage,
  });

  @override
  State<DynamicPage> createState() => _DynamicPageState();
}

class _DynamicPageState extends State<DynamicPage> {
  List<BlockConfig>? _blocks;
  final MetricsService _metricsService = MetricsService();

  @override
  void initState() {
    super.initState();
    _loadBlocks();
    _metricsService.addListener(_onMetricsUpdate);
  }

  @override
  void didUpdateWidget(DynamicPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageId != widget.pageId) {
      _unsubscribeAll();
      _loadBlocks();
    }
  }

  @override
  void dispose() {
    _metricsService.removeListener(_onMetricsUpdate);
    _unsubscribeAll();
    super.dispose();
  }

  void _onMetricsUpdate() {
    if (mounted) setState(() {});
  }

  void _unsubscribeAll() {
    if (_blocks != null) {
      for (final block in _blocks!) {
        for (final metric in block.metrics) {
          _metricsService.unsubscribe(metric.module, metric.key);
        }
      }
    }
  }

  Future<void> _loadBlocks() async {
    final blocks = await ConfigService.fetchBlocks(widget.pageId);
    if (!mounted) return;

    // Subscribe to all metrics referenced by blocks on this page
    for (final block in blocks) {
      for (final metric in block.metrics) {
        _metricsService.subscribe(metric.module, metric.key);
      }
    }

    setState(() {
      _blocks = blocks;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Resolve background: page-level overrides vehicle-level
    final bgImage =
        widget.backgroundImage ?? widget.vehicleConfig.backgroundImage;

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: bgImage != null
          ? BoxDecoration(
              image: DecorationImage(
                image: AssetImage(bgImage),
                fit: BoxFit.fill,
                repeat: ImageRepeat.noRepeat,
              ),
            )
          : null,
      child: _blocks == null
          ? const Center(child: CircularProgressIndicator())
          : _buildGrid(context),
    );
  }

  Widget _buildGrid(BuildContext context) {
    final gridColumns = widget.vehicleConfig.gridColumns;
    final gridRows = widget.vehicleConfig.gridRows;
    final blockStyle = widget.vehicleConfig.blockStyle;

    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = constraints.maxWidth;
        final contentHeight = constraints.maxHeight;
        final cellWidth = contentWidth / gridColumns;
        final cellHeight = contentHeight / gridRows;

        return Stack(
          children: _blocks!.map((block) {
            final left = block.column * cellWidth;
            final top = block.row * cellHeight;
            final blockWidth = block.columns * cellWidth;
            final blockHeight = block.rows * cellHeight;

            return Positioned(
              left: left,
              top: top,
              width: blockWidth,
              height: blockHeight,
              child: BlockRenderer(
                block: block,
                metricsService: _metricsService,
                blockStyle: blockStyle,
              ),
            );
          }).toList(),
        );
      },
    );
  }
}
