class MetricRef {
  final String module;
  final String key;
  final String? label;

  MetricRef({
    required this.module,
    required this.key,
    this.label,
  });

  factory MetricRef.fromJson(Map<String, dynamic> json) {
    return MetricRef(
      module: json['module'] as String,
      key: json['key'] as String,
      label: json['label'] as String?,
    );
  }
}

class ActionRef {
  final String module;
  final String action;

  ActionRef({
    required this.module,
    required this.action,
  });

  factory ActionRef.fromJson(Map<String, dynamic> json) {
    return ActionRef(
      module: json['module'] as String,
      action: json['action'] as String,
    );
  }
}

class BlockConfig {
  final String id;
  final String name;
  final String subtype;
  final int columns;
  final int rows;
  final List<MetricRef> metrics;
  final List<ActionRef> actions;
  final Map<String, dynamic>? config;

  BlockConfig({
    required this.id,
    required this.name,
    required this.subtype,
    required this.columns,
    required this.rows,
    required this.metrics,
    required this.actions,
    this.config,
  });

  factory BlockConfig.fromJson(Map<String, dynamic> json) {
    final attrs = json['attributes'] as Map<String, dynamic>;
    final metricsList = (attrs['metrics'] as List<dynamic>?)
        ?.map((m) => MetricRef.fromJson(m as Map<String, dynamic>))
        .toList() ?? [];
    final actionsList = (attrs['actions'] as List<dynamic>?)
        ?.map((a) => ActionRef.fromJson(a as Map<String, dynamic>))
        .toList() ?? [];

    return BlockConfig(
      id: json['id'] as String,
      name: attrs['name'] as String,
      subtype: attrs['subtype'] as String,
      columns: attrs['columns'] as int,
      rows: attrs['rows'] as int,
      metrics: metricsList,
      actions: actionsList,
      config: attrs['config'] as Map<String, dynamic>?,
    );
  }
}
