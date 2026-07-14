import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:archive/archive.dart';
import 'class_maps.dart';

/// 单个检测目标（与 _Det 解耦）
class ExportTarget {
  final String label;
  final double x1, y1, x2, y2;
  ExportTarget(this.label, this.x1, this.y1, this.x2, this.y2);
}

/// 单张图片的检测结果
class ExportItem {
  final String name;
  final Uint8List imageBytes;
  final int imgW, imgH;
  final List<ExportTarget> targets;

  ExportItem({
    required this.name,
    required this.imageBytes,
    required this.imgW,
    required this.imgH,
    required this.targets,
  });
}

/// 生成单张图片的 YOLO .txt 标注内容
String yoloAnnotation(ExportItem item, {required bool isVoc}) {
  final map = isVoc ? VOC_MAP : COCO_MAP;
  return item.targets.map((t) {
    final clsId = map[t.label];
    if (clsId == null) throw ArgumentError('未知类别: ${t.label}');
    final xc = ((t.x1 + t.x2) / 2) / item.imgW;
    final yc = ((t.y1 + t.y2) / 2) / item.imgH;
    final w = (t.x2 - t.x1) / item.imgW;
    final h = (t.y2 - t.y1) / item.imgH;
    return '$clsId ${xc.toStringAsFixed(6)} ${yc.toStringAsFixed(6)} ${w.toStringAsFixed(6)} ${h.toStringAsFixed(6)}';
  }).join('\n');
}

/// 生成 classes.txt 类别名文件
String classesTxt({required bool isVoc}) {
  final map = isVoc ? VOC_MAP : COCO_MAP;
  final entries = map.entries.toList();
  entries.sort((a, b) => a.value.compareTo(b.value));
  return entries.map((e) => e.key).join('\n');
}

/// 导出单张为 YOLO .txt 到指定目录
/// 返回保存的 File 路径
Future<String> exportSingleYolo(ExportItem item, {required bool isVoc}) async {
  final dir = await getApplicationDocumentsDirectory();
  final outDir = '${dir.path}/yolo_export';
  await Directory(outDir).create(recursive: true);
  final txtPath = '$outDir/${item.name}.txt';
  await File(txtPath).writeAsString(yoloAnnotation(item, isVoc: isVoc));
  return txtPath;
}

/// 导出为 .zip 包（images/ + labels/ + classes.txt）
/// 返回 .zip 文件
Future<File> exportZip(List<ExportItem> items, {required bool isVoc}) async {
  final archive = Archive();

  for (final item in items) {
    // 图片
    archive.addFile(ArchiveFile(
      'images/${item.name}.jpg',
      item.imageBytes.length,
      item.imageBytes,
    ));
    // 标注
    final ann = yoloAnnotation(item, isVoc: isVoc);
    final annBytes = Uint8List.fromList(ann.codeUnits);
    archive.addFile(ArchiveFile(
      'labels/${item.name}.txt',
      annBytes.length,
      annBytes,
    ));
  }

  // classes.txt
  final cls = classesTxt(isVoc: isVoc);
  final clsBytes = Uint8List.fromList(cls.codeUnits);
  archive.addFile(ArchiveFile('classes.txt', clsBytes.length, clsBytes));

  // 编码为 zip
  final encoded = ZipEncoder().encode(archive);
  final dir = await getApplicationDocumentsDirectory();
  final zipPath = '${dir.path}/yolo_export/annotations.zip';
  await Directory('${dir.path}/yolo_export').create(recursive: true);
  await File(zipPath).writeAsBytes(encoded);
  return File(zipPath);
}

/// 通过系统分享发送 .zip 文件
Future<void> shareZip(File zip) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(zip.path)],
      fileNameOverrides: [zip.path.split('/').last],
      text: '灵眸标注导出',
    ),
  );
}

/// 直接分享单张 YOLO .txt
Future<void> shareAnnotation(ExportItem item, {required bool isVoc}) async {
  final txt = yoloAnnotation(item, isVoc: isVoc);
  final dir = await getApplicationDocumentsDirectory();
  final path = '${dir.path}/yolo_export/${item.name}.txt';
  await Directory('${dir.path}/yolo_export').create(recursive: true);
  await File(path).writeAsString(txt);
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(path)],
      fileNameOverrides: ['${item.name}.txt'],
    ),
  );
}
