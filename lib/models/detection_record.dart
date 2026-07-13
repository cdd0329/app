import 'dart:convert';

class DetectedObject {
  final String className;
  final double confidence;
  final List<double> bbox; // [x1, y1, x2, y2]

  DetectedObject({
    required this.className,
    required this.confidence,
    required this.bbox,
  });

  factory DetectedObject.fromJson(Map<String, dynamic> json) {
    return DetectedObject(
      className: json['class'] as String,
      confidence: (json['confidence'] as num).toDouble(),
      bbox: (json['bbox'] as List).map((e) => (e as num).toDouble()).toList(),
    );
  }
}

class DetectionRecord {
  final int id;
  final String imageName;
  final String uploadedAt;
  final int count;
  final int processMs;
  final List<DetectedObject> objects;
  final String? imagePath;
  bool isSelected;

  DetectionRecord({
    required this.id,
    required this.imageName,
    required this.uploadedAt,
    required this.count,
    required this.processMs,
    required this.objects,
    this.imagePath,
    this.isSelected = false,
  });

  factory DetectionRecord.fromJson(Map<String, dynamic> json) {
    return DetectionRecord(
      id: json['id'] as int,
      imageName: json['image_name'] as String,
      uploadedAt: json['uploaded_at'] as String? ?? '',
      count: json['count'] as int? ?? 0,
      processMs: json['process_ms'] as int? ?? 0,
      objects: (json['objects'] as List<dynamic>?)
              ?.map((o) => DetectedObject.fromJson(o as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  factory DetectionRecord.fromDb(Map<String, dynamic> row) {
    return DetectionRecord(
      id: row['id'] as int,
      imageName: row['image_name'] as String,
      uploadedAt: row['uploaded_at'] as String,
      count: row['count'] as int,
      processMs: row['process_ms'] as int,
      objects: (jsonDecode(row['objects_json'] as String) as List<dynamic>)
          .map((o) => DetectedObject.fromJson(o as Map<String, dynamic>))
          .toList(),
      imagePath: row['image_path'] as String?,
    );
  }
}
