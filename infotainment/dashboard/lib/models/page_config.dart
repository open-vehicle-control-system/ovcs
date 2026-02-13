class PageConfig {
  final String id;
  final String name;
  final String? icon;
  final String? backgroundImage;

  PageConfig({
    required this.id,
    required this.name,
    this.icon,
    this.backgroundImage,
  });

  factory PageConfig.fromJson(Map<String, dynamic> json) {
    final attrs = json['attributes'] as Map<String, dynamic>;
    return PageConfig(
      id: json['id'] as String,
      name: attrs['name'] as String,
      icon: attrs['icon'] as String?,
      backgroundImage: attrs['backgroundImage'] as String?,
    );
  }
}
