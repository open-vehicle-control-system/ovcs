class BlockStyle {
  final String? backgroundColor;
  final double? borderRadius;
  final double? padding;
  final double? margin;

  BlockStyle({
    this.backgroundColor,
    this.borderRadius,
    this.padding,
    this.margin,
  });

  factory BlockStyle.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return BlockStyle();
    }
    return BlockStyle(
      backgroundColor: json['backgroundColor'] as String?,
      borderRadius: (json['borderRadius'] as num?)?.toDouble(),
      padding: (json['padding'] as num?)?.toDouble(),
      margin: (json['margin'] as num?)?.toDouble(),
    );
  }
}

class SidebarConfig {
  final double width;
  final String? backgroundColor;

  SidebarConfig({
    required this.width,
    this.backgroundColor,
  });

  factory SidebarConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return SidebarConfig(width: 100);
    }
    return SidebarConfig(
      width: (json['width'] as num?)?.toDouble() ?? 100,
      backgroundColor: json['backgroundColor'] as String?,
    );
  }
}

class VehicleConfig {
  final String name;
  final String module;
  final String mainColor;
  final int refreshInterval;
  final int gridColumns;
  final int gridRows;
  final String? backgroundImage;
  final BlockStyle blockStyle;
  final SidebarConfig sidebar;

  VehicleConfig({
    required this.name,
    required this.module,
    required this.mainColor,
    required this.refreshInterval,
    required this.gridColumns,
    required this.gridRows,
    this.backgroundImage,
    required this.blockStyle,
    required this.sidebar,
  });

  factory VehicleConfig.fromJson(Map<String, dynamic> json) {
    final attrs = json['attributes'] as Map<String, dynamic>;
    return VehicleConfig(
      name: attrs['name'] as String,
      module: attrs['module'] as String,
      mainColor: attrs['mainColor'] as String,
      refreshInterval: attrs['refreshInterval'] as int,
      gridColumns: attrs['gridColumns'] as int,
      gridRows: attrs['gridRows'] as int,
      backgroundImage: attrs['backgroundImage'] as String?,
      blockStyle:
          BlockStyle.fromJson(attrs['blockStyle'] as Map<String, dynamic>?),
      sidebar:
          SidebarConfig.fromJson(attrs['sidebar'] as Map<String, dynamic>?),
    );
  }
}
