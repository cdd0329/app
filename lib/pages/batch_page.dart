import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../utils/export_helper.dart';
import '../utils/class_maps.dart';
import '../models/detection_record.dart';
import '../models/database.dart';

// ---- 数据模型 ----

/// 单张图片的检测结果（公开版 _Det）
class BatchDet {
  final double x1, y1, x2, y2, score;
  String label;
  BatchDet(this.x1, this.y1, this.x2, this.y2, this.score, this.label);
}

class BatchImage {
  final String name;
  final Uint8List bytes;
  List<BatchDet> dets = const [];
  int imgW = 640, imgH = 640;
  bool done = false;
  String? error;

  BatchImage({required this.name, required this.bytes});
}

// ---- 批量检测页面 ----

class BatchPage extends StatefulWidget {
  final List<XFile> files;
  final String serverUrl;
  final double conf;
  final bool isVoc;
  const BatchPage({
    super.key,
    required this.files,
    required this.serverUrl,
    required this.conf,
    required this.isVoc,
  });
  @override
  State<BatchPage> createState() => _BatchPageState();
}

class _BatchPageState extends State<BatchPage> {
  late List<BatchImage> _items;
  int _done = 0;
  bool _busy = false;

  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _items = [];
    WidgetsBinding.instance.addPostFrameCallback((_) { if (!_disposed) _initImages(); });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _initImages() async {
    var list = <BatchImage>[];
    for (int i = 0; i < widget.files.length; i++) {
      var bytes = await widget.files[i].readAsBytes();
      list.add(BatchImage(name: widget.files[i].name.split('.').first, bytes: bytes));
    }
    if (!_disposed && mounted) setState(() => _items = list);
    if (!_disposed) _detectAll();
  }

  Future<void> _detectAll() async {
    if (_disposed || !mounted) return;
    setState(() => _busy = true);
    for (int i = 0; i < _items.length; i++) {
      if (_disposed) return;
      final item = _items[i];
      final sw = Stopwatch()..start();
      try {
        final uri = Uri.parse('${widget.serverUrl}/api/detect');
        final req = http.MultipartRequest('POST', uri);
        req.fields['conf'] = widget.conf.toString();
        req.fields['model'] = widget.isVoc ? 'voc' : 'coco';
        req.files.add(http.MultipartFile.fromBytes('file', item.bytes, filename: '${item.name}.jpg'));
        final resp = await http.Response.fromStream(await req.send()).timeout(const Duration(seconds: 15));
        sw.stop();

        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          item.imgW = data['width'] ?? 640;
          item.imgH = data['height'] ?? 640;
          final list = (data['objects'] as List?) ?? [];
          item.dets = list.map((o) {
            final bb = o['bbox'] as List;
            return BatchDet(
              bb[0].toDouble(), bb[1].toDouble(),
              bb[2].toDouble(), bb[3].toDouble(),
              (o['confidence'] as num).toDouble(),
              o['class'] as String,
            );
          }).toList();

          // 保存到数据库
          try {
            final dir = await getApplicationDocumentsDirectory();
            final now = DateTime.now().millisecondsSinceEpoch;
            await File('${dir.path}/$now.jpg').writeAsBytes(item.bytes);
            await AppDatabase.insertRecord(DetectionRecord(
              id: now,
              imagePath: '${dir.path}/$now.jpg',
              imageName: item.name,
              uploadedAt: DateTime.now().toString().substring(0, 19),
              count: item.dets.length,
              processMs: sw.elapsedMilliseconds,
              objects: item.dets
                  .map((d) => DetectedObject(
                        className: d.label,
                        confidence: d.score,
                        bbox: [d.x1, d.y1, d.x2, d.y2],
                      ))
                  .toList(),
            ));
          } catch (_) {}
        } else {
          item.error = 'HTTP ${resp.statusCode}';
        }
      } catch (e) {
        item.error = '$e';
      }
      item.done = true;
      if (!_disposed && mounted) setState(() => _done = i + 1);
    }
    if (!_disposed && mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('批量检测 (${_done}/${_items.length})')),
      body: _done < _items.length ? _buildProgress() : _buildGrid(),
    );
  }

  Widget _buildProgress() {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        SizedBox(
          width: 200,
          child: LinearProgressIndicator(
            value: _done / _items.length,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(height: 16),
        Text('检测中 $_done / ${_items.length} ...',
            style: const TextStyle(fontSize: 15, color: Colors.grey)),
        if (_items.isNotEmpty && _done < _items.length)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_items[_done < _items.length ? _done : _done - 1].name,
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ),
      ]),
    );
  }

  Widget _buildGrid() {
    return Column(children: [
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: _items.length,
          itemBuilder: (_, i) => _gridItem(i),
        ),
      ),
      if (!_busy)
        Container(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(children: [
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _exportAll(context),
                  icon: const Icon(Icons.file_download_outlined, size: 18),
                  label: const Text('📤 全部导出'),
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _uploadAll(context),
                  icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                  label: const Text('☁️ 全部上传'),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(child: Text('导出 YOLO .zip 标注（图片+标签）',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500))),
              const SizedBox(width: 8),
              Expanded(child: Text('上传标注到服务器，用于模型训练',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500))),
            ]),
          ]),
        ),
    ]);
  }

  Widget _gridItem(int i) {
    final item = _items[i];
    final hasDets = item.dets.isNotEmpty;
    return GestureDetector(
      onTap: () => _openDetail(context, i),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(item.bytes, fit: BoxFit.cover, width: double.infinity, height: double.infinity),
          ),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 1),
            ),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: hasDets ? Colors.blue.shade600 : Colors.grey.shade600,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                hasDets ? '${item.dets.length}' : '0',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          if (item.error != null)
            Positioned(
              bottom: 4,
              left: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(color: Colors.red.shade800, borderRadius: BorderRadius.circular(4)),
                child: Text(item.error!, style: const TextStyle(color: Colors.white, fontSize: 9), overflow: TextOverflow.ellipsis),
              ),
            ),
        ],
      ),
    );
  }

  void _openDetail(BuildContext ctx, int index) {
    Navigator.push(
      ctx,
      MaterialPageRoute(
        builder: (_) => BatchDetailPage(
          items: _items,
          initialIndex: index,
          serverUrl: widget.serverUrl,
          conf: widget.conf,
          isVoc: widget.isVoc,
        ),
      ),
    );
  }

  Future<void> _exportAll(BuildContext ctx) async {
    final exportItems = _items
        .where((item) => item.dets.isNotEmpty)
        .map((item) => ExportItem(
              name: item.name,
              imageBytes: item.bytes,
              imgW: item.imgW,
              imgH: item.imgH,
              targets: item.dets.map((d) => ExportTarget(d.label, d.x1, d.y1, d.x2, d.y2)).toList(),
            ))
        .toList();
    if (exportItems.isEmpty) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('没有检测到目标')));
      }
      return;
    }
    try {
      final zip = await exportZip(exportItems, isVoc: widget.isVoc);
      if (ctx.mounted) {
        showDialog(
          context: ctx,
          builder: (ctx2) => AlertDialog(
            title: const Text('导出完成'),
            content: Text('共 ${exportItems.length} 张\n文件: ${zip.path}'),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx2);
                  shareZip(zip);
                },
                child: const Text('分享'),
              ),
              TextButton(onPressed: () => Navigator.pop(ctx2), child: const Text('确定')),
            ],
          ),
        );
      }
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  Future<void> _uploadAll(BuildContext ctx) async {
    var host = Uri.parse(widget.serverUrl).host;
    var uploadUrl = 'http://$host:8767/api/annotations/upload';
    var ok = 0, fail = 0;
    for (var item in _items) {
      if (item.dets.isEmpty) continue;
      try {
        var uri = Uri.parse(uploadUrl);
        var req = http.MultipartRequest('POST', uri);
        req.files.add(await http.MultipartFile.fromBytes('file', item.bytes, filename: '${item.name}.jpg'));
        // YOLO 标注内容
        var map = widget.isVoc ? VOC_MAP : COCO_MAP;
        var lines = item.dets.map((d) {
          var clsId = map[d.label] ?? 0;
          var xc = ((d.x1 + d.x2) / 2) / item.imgW;
          var yc = ((d.y1 + d.y2) / 2) / item.imgH;
          var w = (d.x2 - d.x1) / item.imgW;
          var h = (d.y2 - d.y1) / item.imgH;
          return '$clsId ${xc.toStringAsFixed(6)} ${yc.toStringAsFixed(6)} ${w.toStringAsFixed(6)} ${h.toStringAsFixed(6)}';
        }).join('\n');
        req.fields['label'] = lines;
        req.fields['model'] = widget.isVoc ? 'voc' : 'coco';
        var resp = await http.Response.fromStream(await req.send()).timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) ok++; else fail++;
      } catch (_) { fail++; }
    }
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('上传完成: $ok 成功, $fail 失败')));
    }
  }
}

// ---- 滑动详情页 ----

class BatchDetailPage extends StatefulWidget {
  final List<BatchImage> items;
  final int initialIndex;
  final String serverUrl;
  final double conf;
  final bool isVoc;
  const BatchDetailPage({
    super.key,
    required this.items,
    required this.initialIndex,
    required this.serverUrl,
    required this.conf,
    required this.isVoc,
  });
  @override
  State<BatchDetailPage> createState() => _BatchDetailPageState();
}

class _BatchDetailPageState extends State<BatchDetailPage> {
  late PageController _pageCtrl;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _pageCtrl = PageController(initialPage: _current);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_current];
    return Scaffold(
      appBar: AppBar(
        title: Text('${_current + 1}/${widget.items.length}  ${item.name}'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context, widget.items)),
      ),
      body: Column(children: [
        Expanded(
          child: PageView.builder(
            controller: _pageCtrl,
            onPageChanged: (i) => setState(() => _current = i),
            itemCount: widget.items.length,
            itemBuilder: (_, i) => _singlePage(widget.items[i]),
          ),
        ),
        _bottomBar(context),
      ]),
    );
  }

  Widget _singlePage(BatchImage item) {
    final t = Theme.of(context);
    final hasDets = item.dets.isNotEmpty;
    return SingleChildScrollView(
      child: Column(children: [
        // 图片 + 框
        if (item.imgH > 0)
          Padding(
            padding: const EdgeInsets.all(12),
            child: AspectRatio(
              aspectRatio: item.imgW.toDouble() / item.imgH.toDouble(),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE8ECF1)),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(children: [
                    Image.memory(item.bytes, fit: BoxFit.contain),
                    if (hasDets)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _BatchBoxPainter(
                              item.dets,
                              item.imgW.toDouble(),
                              item.imgH.toDouble(),
                            ),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
          ),

        // 检测结果列表
        if (hasDets)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE8ECF1)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text('检测结果', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.colorScheme.onSurface)),
                  if (item.dets.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: t.colorScheme.primary, borderRadius: BorderRadius.circular(8)),
                        child: Text('${item.dets.length}', style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                      ),
                    ),
                ]),
                const SizedBox(height: 6),
                if (item.dets.isEmpty)
                  Center(child: Text(item.error ?? '未检测到目标', style: TextStyle(color: Colors.grey.shade500)))
                else
                  ...item.dets.asMap().entries.map((e) => _detRow(e.key, e.value)),
              ]),
            ),
          ),
        const SizedBox(height: 80),
      ]),
    );
  }

  Widget _detRow(int i, BatchDet d) {
    final cs = [Colors.red, Colors.green, Colors.blue, Colors.orange, Colors.purple, Colors.teal, Colors.pink, Colors.indigo];
    final c = cs[i % cs.length];
    return Column(children: [
      if (i > 0) const Divider(height: 1),
      ListTile(
        dense: true,
        leading: Container(width: 12, height: 12, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        title: Text(d.label, style: const TextStyle(fontSize: 14)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('${(d.score * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c)),
          const SizedBox(width: 4),
          InkWell(
            onTap: () => _editClass(i),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(6)),
              child: Icon(Icons.edit_outlined, size: 14, color: Colors.grey.shade600),
            ),
          ),
        ]),
      ),
    ]);
  }

  void _editClass(int idx) {
    final item = widget.items[_current];
    final det = item.dets[idx];
    final classes = getClassList(isVoc: widget.isVoc);
    final currentIdx = classes.indexOf(det.label);
    final searchCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheetState) {
          final filtered = searchCtrl.text.isEmpty
              ? classes
              : classes.where((c) => c.contains(searchCtrl.text)).toList();
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(children: [
              // 标题栏
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('选择正确类别', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                ]),
              ),
              // 搜索框
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: TextField(
                  controller: searchCtrl,
                  decoration: InputDecoration(
                    hintText: '搜索类别...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    filled: true,
                    fillColor: const Color(0xFFF5F7FA),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFE8ECF1)),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onChanged: (_) => setSheetState(() {}),
                ),
              ),
              // 类别列表
              Expanded(
                child: ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (_, i) {
                    final cls = filtered[i];
                    final isSelected = i == currentIdx;
                    return ListTile(
                      leading: Icon(
                        isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        color: isSelected ? Theme.of(ctx).colorScheme.primary : Colors.grey,
                        size: 22,
                      ),
                      title: Text(cls, style: TextStyle(fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal)),
                      onTap: () {
                        setState(() => det.label = cls);
                        Navigator.pop(ctx);
                      },
                    );
                  },
                ),
              ),
            ]),
          );
        });
      },
    );
  }

  Widget _bottomBar(BuildContext ctx) {
    final item = widget.items[_current];
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFE8ECF1))),
        color: Colors.white,
      ),
      child: Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () async {
              final exportItem = ExportItem(
                name: item.name,
                imageBytes: item.bytes,
                imgW: item.imgW,
                imgH: item.imgH,
                targets: item.dets.map((d) => ExportTarget(d.label, d.x1, d.y1, d.x2, d.y2)).toList(),
              );
              try {
                final path = await exportSingleYolo(exportItem, isVoc: widget.isVoc);
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('已保存到: $path')));
                }
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('导出失败: $e')));
                }
              }
            },
            icon: const Icon(Icons.file_download_outlined, size: 16),
            label: const Text('导出'),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            onPressed: () {
              final exportItem = ExportItem(
                name: item.name,
                imageBytes: item.bytes,
                imgW: item.imgW,
                imgH: item.imgH,
                targets: item.dets.map((d) => ExportTarget(d.label, d.x1, d.y1, d.x2, d.y2)).toList(),
              );
              shareAnnotation(exportItem, isVoc: widget.isVoc);
            },
            icon: const Icon(Icons.share_outlined, size: 16),
            label: const Text('分享'),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10)),
          ),
        ),
      ]),
    );
  }
}

// ---- 画框 Painter（复制自 detect_page.dart 的 _BoxP） ----

class _BatchBoxPainter extends CustomPainter {
  final List<BatchDet> dets;
  final double iW, iH;
  _BatchBoxPainter(this.dets, this.iW, this.iH);

  @override
  void paint(Canvas c, Size s) {
    if (iW <= 0 || iH <= 0) return;
    final sx = s.width / iW, sy = s.height / iH, sc = sx < sy ? sx : sy;
    final ox = (s.width - iW * sc) / 2, oy = (s.height - iH * sc) / 2;
    final cs = [Colors.red, Colors.green, Colors.blue, Colors.orange, Colors.purple, Colors.teal, Colors.pink, Colors.indigo];
    for (int i = 0; i < dets.length; i++) {
      final d = dets[i];
      final col = cs[i % cs.length];
      final r = Rect.fromLTWH(ox + d.x1 * sc, oy + d.y1 * sc, (d.x2 - d.x1) * sc, (d.y2 - d.y1) * sc);
      c.drawRect(r, Paint()..color = col..style = PaintingStyle.stroke..strokeWidth = 2.5);
      final lb = '${d.label} ${(d.score * 100).toStringAsFixed(0)}%';
      final tp = TextPainter(
        text: TextSpan(text: lb, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      c.drawRect(Rect.fromLTWH(r.left, r.top - 22, tp.width + 8, 22), Paint()..color = col);
      tp.paint(c, Offset(r.left + 4, r.top - 18));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter o) => true;
}
