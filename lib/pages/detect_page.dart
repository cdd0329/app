import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import '../models/detection_record.dart';
import '../models/database.dart';

class DetectPage extends StatefulWidget {
  const DetectPage({super.key});
  @override
  State<DetectPage> createState() => _DetectPageState();
}

class _DetectPageState extends State<DetectPage> {
  final _picker = ImagePicker();
  String _serverUrl = 'http://218.195.250.194:8765';
  Uint8List? _rawBytes;
  int _imgW = 640, _imgH = 640;
  List<_Det> _dets = const [];
  bool _isBusy = false, _hasRun = false;
  double _conf = 0.25;
  String? _dbg;
  bool _isCameraMode = false;

  // 增强参数
  bool _enhExpanded = false;
  bool _showOriginal = false;
  double _scale = 1, _crop = 1, _rotate = 0;
  double _brightness = 0, _contrast = 0, _saturation = 1;
  String _currentModel = 'COCO (80类)';

  // 相机模式检测结果
  List<YOLOResult> _camDets = [];
  double _camFps = 0;

  Future<void> _pick(ImageSource s) async {
    if (_isBusy) return;
    final f = await _picker.pickImage(source: s, imageQuality: 85);
    if (f == null) return;
    final bytes = await f.readAsBytes();
    if (mounted) setState(() { _rawBytes = bytes; _dets = const []; _hasRun = false; _dbg = null; });
  }

  Future<void> _detect() async {
    if (_rawBytes == null) return;
    setState(() { _isBusy = true; _dbg = null; });
    final sw = Stopwatch()..start();
    try {
      var uri = Uri.parse('$_serverUrl/api/detect');
      var req = http.MultipartRequest('POST', uri);
      req.fields['conf'] = _conf.toString();
      req.fields['model'] = _currentModel.contains('VOC') ? 'voc' : 'coco';
      req.files.add(http.MultipartFile.fromBytes('file', _rawBytes!, filename: 'img.jpg'));
      var resp = await http.Response.fromStream(await req.send());
      sw.stop();
      if (resp.statusCode != 200) {
        if (mounted) setState(() { _isBusy = false; _dbg = 'HTTP ${resp.statusCode}'; });
        return;
      }
      var data = jsonDecode(resp.body);
      var list = (data['objects'] as List?)?.map((o) {
        var b = o['bbox'] as List;
        return _Det(b[0].toDouble(), b[1].toDouble(), b[2].toDouble(), b[3].toDouble(),
            (o['confidence'] as num).toDouble(), o['class'] as String);
      }).toList() ?? [];
      var sw2 = data['width'] as int? ?? 0;
      var sh2 = data['height'] as int? ?? 0;
      if (sw2 > 0 && sh2 > 0) { _imgW = sw2; _imgH = sh2; }
      final now = DateTime.now().millisecondsSinceEpoch;
      try {
        final dir = await getApplicationDocumentsDirectory();
        final imgFile = File('${dir.path}/$now.jpg');
        await imgFile.writeAsBytes(_rawBytes!);
        await AppDatabase.insertRecord(DetectionRecord(
          id: now, imagePath: imgFile.path,
          imageName: DateTime.now().toString().substring(0, 19),
          uploadedAt: DateTime.now().toString().substring(0, 19),
          count: list.length, processMs: sw.elapsedMilliseconds,
          objects: list.map((b) => DetectedObject(
            className: b.label, confidence: b.score,
            bbox: [b.x1, b.y1, b.x2, b.y2],
          )).toList(),
        ));
      } catch (_) {}
      if (mounted) setState(() { _dets = list; _hasRun = true; _isBusy = false;
        _dbg = '${list.length}目标 ${sw.elapsedMilliseconds}ms'; });
    } catch (e) {
      if (mounted) setState(() { _isBusy = false; _dbg = '连接失败($e)'; });
    }
  }

  Widget _buildImagePreview() {
    if (_rawBytes == null) return const SizedBox.shrink();
    Widget img = Image.memory(_rawBytes!, fit: BoxFit.contain);
    if (!_showOriginal) {
      final contrastMatrix = <double>[
        _contrast + 1, 0, 0, 0, _brightness,
        0, _contrast + 1, 0, 0, _brightness,
        0, 0, _contrast + 1, 0, _brightness,
        0, 0, 0, 1, 0,
      ];
      final satMatrix = <double>[
        0.3086 + 0.6914 * _saturation, 0.6094 - 0.6094 * _saturation, 0.0820 - 0.0820 * _saturation, 0, 0,
        0.3086 - 0.3086 * _saturation, 0.6094 + 0.3906 * _saturation, 0.0820 - 0.0820 * _saturation, 0, 0,
        0.3086 - 0.3086 * _saturation, 0.6094 - 0.6094 * _saturation, 0.0820 + 0.9180 * _saturation, 0, 0,
        0, 0, 0, 1, 0,
      ];
      img = ColorFiltered(colorFilter: ColorFilter.matrix(satMatrix), child: img);
      img = ColorFiltered(colorFilter: ColorFilter.matrix(contrastMatrix), child: img);
      img = Transform(alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(0, 0, _scale)..setEntry(1, 1, _scale)..setEntry(2, 2, _scale)
          ..rotateZ(_rotate * math.pi / 180),
        child: img);
    }
    return img;
  }

  @override
  Widget build(BuildContext context) {
    if (_isCameraMode) return _buildCameraMode(context);
    return _buildImageMode(context);
  }

  Widget _buildCameraMode(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('实时检测'), leading: IconButton(
        icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _isCameraMode = false))),
      body: Stack(children: [
        YOLOView(
          modelPath: 'assets/voc_model.tflite',
          task: YOLOTask.detect,
          confidenceThreshold: _conf,
          iouThreshold: 0.7,
          useGpu: false,
          lensFacing: LensFacing.back,
          onResult: (dets) { if (mounted) setState(() => _camDets = dets); },
          onPerformanceMetrics: (m) { if (mounted) setState(() => _camFps = m.fps); },
        ),
        Positioned(top: 12, left: 12, child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
          child: Text('${_camDets.length} 目标 · ${_camFps.toStringAsFixed(0)} FPS',
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
        )),
        Positioned(bottom: 0, left: 0, right: 0, child: Container(
          constraints: const BoxConstraints(maxHeight: 160),
          decoration: const BoxDecoration(color: Colors.black54),
          child: _camDets.isEmpty
              ? const SizedBox.shrink()
              : ListView.builder(scrollDirection: Axis.horizontal, itemCount: _camDets.length,
                  itemBuilder: (_, i) {
                    final d = _camDets[i];
                    return Container(width: 100, margin: const EdgeInsets.all(6),
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(8)),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text(d.className, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                        Text('${(d.confidence * 100).toInt()}%', style: TextStyle(color: Colors.greenAccent.shade200, fontSize: 11)),
                      ]));
                  }),
        )),
      ]),
    );
  }

  Widget _buildImageMode(BuildContext context) {
    final t = Theme.of(context);
    final has = _rawBytes != null;
    return Scaffold(
      appBar: AppBar(title: const Text('灵眸'), actions: [
        IconButton(icon: const Icon(Icons.videocam_outlined, size: 22), tooltip: '实时检测',
            onPressed: () => setState(() => _isCameraMode = true)),
        Padding(padding: const EdgeInsets.only(right: 12),
          child: _buildModelSelector()),
      ]),
      body: Column(children: [
        if (_isBusy) const LinearProgressIndicator(minHeight: 2),
        Expanded(flex: 3, child: Container(
          margin: const EdgeInsets.all(16).copyWith(bottom: 8),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE8ECF1))),
          child: has
              ? ClipRRect(borderRadius: BorderRadius.circular(12),
                  child: Center(child: Stack(children: [
                    _buildImagePreview(),
                    if (_dets.isNotEmpty)
                      Positioned.fill(child: IgnorePointer(
                        child: CustomPaint(painter: _BoxPaint(_dets, _imgW.toDouble(), _imgH.toDouble())),
                      )),
                  ])))
              : Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.image_outlined, size: 64, color: Colors.grey.shade300),
                  const SizedBox(height: 12),
                  Text('选择图片开始检测', style: TextStyle(fontSize: 15, color: Colors.grey.shade500)),
                ])),
        )),
        if (has) Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE8ECF1))),
          child: Column(children: [
            InkWell(onTap: () => setState(() => _enhExpanded = !_enhExpanded),
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(children: [
                      Icon(Icons.tune, size: 18, color: t.colorScheme.primary), const SizedBox(width: 8),
                      const Text('图片增强', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      const Spacer(),
                      Icon(_enhExpanded ? Icons.expand_less : Icons.expand_more, size: 20),
                    ]))),
            if (_enhExpanded) ...[const Divider(height: 1),
              Padding(padding: const EdgeInsets.fromLTRB(14, 4, 14, 8), child: Column(children: [
                _slider('缩放', _scale, 0.5, 2, (v) => _scale = v, '${_scale.toStringAsFixed(1)}x'),
                _slider('裁剪', _crop, 0.4, 1, (v) => _crop = v, '${(_crop*100).toInt()}%'),
                _slider('旋转', _rotate, -45, 45, (v) => _rotate = v, '${_rotate.toInt()}°'),
                _slider('亮度', _brightness, -0.5, 0.5, (v) => _brightness = v, _brightness.toStringAsFixed(2)),
                _slider('对比度', _contrast, -0.5, 0.5, (v) => _contrast = v, _contrast.toStringAsFixed(2)),
                _slider('饱和度', _saturation, 0, 2, (v) => _saturation = v, '${_saturation.toStringAsFixed(1)}x'),
                Row(children: [
                  TextButton.icon(
                    onPressed: () => setState(() => _showOriginal = !_showOriginal),
                    icon: Icon(_showOriginal ? Icons.toggle_off : Icons.compare, size: 16),
                    label: Text(_showOriginal ? '恢复' : '对比', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(foregroundColor: Colors.grey.shade600),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () { setState(() { _scale=1;_crop=1;_rotate=0;_brightness=0;_contrast=0;_saturation=1; }); },
                    icon: const Icon(Icons.refresh, size: 16), label: const Text('重置', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(foregroundColor: Colors.grey.shade600),
                  ),
                ]),
              ])),
            ],
          ]),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(children: [
            Text('置信度', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            Expanded(child: Slider(value: _conf, min: 0.05, max: 0.95,
                activeColor: t.colorScheme.primary, onChanged: (v) => setState(() => _conf = v))),
            Text(_conf.toStringAsFixed(2), style: TextStyle(fontSize: 12,
                fontWeight: FontWeight.w600, color: t.colorScheme.primary)),
          ]),
        ),
        Expanded(flex: 2, child: Container(
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 0), padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE8ECF1))),
          child: _dets.isEmpty
              ? Center(child: Text(_hasRun ? '未检测到目标' : '', style: TextStyle(color: Colors.grey.shade500)))
              : ListView.separated(itemCount: _dets.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final d = _dets[i];
                    final cs = [Colors.red, Colors.green, Colors.blue, Colors.orange,
                      Colors.purple, Colors.teal, Colors.pink, Colors.indigo];
                    final c = cs[i % cs.length];
                    return ListTile(dense: true,
                      leading: Container(width: 12, height: 12, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                      title: Text(d.label, style: const TextStyle(fontSize: 14)),
                      trailing: Text('${(d.score * 100).toStringAsFixed(0)}%',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c)),
                    );
                  }),
        )),
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), child: Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: !_isBusy ? () => _pick(ImageSource.gallery) : null,
            icon: const Icon(Icons.photo_library_outlined, size: 18), label: const Text('相册'),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(
            onPressed: !_isBusy ? () => _pick(ImageSource.camera) : null,
            icon: const Icon(Icons.camera_alt_outlined, size: 18), label: const Text('拍照'),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)))),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: FilledButton.icon(
            onPressed: (has && !_isBusy) ? _detect : null,
            icon: const Icon(Icons.search, size: 18), label: const Text('开始检测'),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)))),
        ])),
      ]),
    );
  }

  Widget _slider(String l, double v, double min, double max, ValueChanged<double> cb, String d) {
    return Row(children: [
      SizedBox(width: 48, child: Text(l, style: const TextStyle(fontSize: 12))),
      Expanded(child: Slider(value: v, min: min, max: max, onChanged: (n) => setState(() => cb(n)))),
      SizedBox(width: 40, child: Text(d, style: const TextStyle(fontSize: 11), textAlign: TextAlign.right)),
    ]);
  }

  Widget _buildModelSelector() {
    return PopupMenuButton<String>(
      onSelected: (v) => setState(() => _currentModel = v),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'COCO (80类)', child: Text('COCO (80类)')),
        PopupMenuItem(value: 'VOC (20类)', child: Text('VOC (20类)')),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFBFDBFE))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.model_training, size: 16, color: Color(0xFF3B82F6)), const SizedBox(width: 6),
          Text(_currentModel, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF3B82F6))),
          const Icon(Icons.arrow_drop_down, size: 18, color: Color(0xFF3B82F6)),
        ]),
      ),
    );
  }
}

class _Det { final double x1, y1, x2, y2, score; final String label;
  _Det(this.x1, this.y1, this.x2, this.y2, this.score, this.label); }

class _BoxPaint extends CustomPainter {
  final List<_Det> dets; final double imgW, imgH;
  _BoxPaint(this.dets, this.imgW, this.imgH);
  @override void paint(Canvas c, Size s) {
    if (imgW <= 0 || imgH <= 0) return;
    final scaleX = s.width / imgW, scaleY = s.height / imgH;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final ox = (s.width - imgW * scale) / 2, oy = (s.height - imgH * scale) / 2;
    final cs = [Colors.red,Colors.green,Colors.blue,Colors.orange,Colors.purple,Colors.teal,Colors.pink,Colors.indigo];
    for (var i = 0; i < dets.length; i++) {
      final d = dets[i]; final col = cs[i%cs.length];
      final r = Rect.fromLTWH(ox + d.x1*scale, oy + d.y1*scale, (d.x2-d.x1)*scale, (d.y2-d.y1)*scale);
      c.drawRect(r, Paint()..color=col..style=PaintingStyle.stroke..strokeWidth=2.5);
      final lb = '${d.label} ${(d.score*100).toStringAsFixed(0)}%';
      final tp = TextPainter(text: TextSpan(text: lb, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)), textDirection: TextDirection.ltr)..layout();
      c.drawRect(Rect.fromLTWH(r.left, r.top-22, tp.width+8, 22), Paint()..color=col);
      tp.paint(c, Offset(r.left+4, r.top-18));
    }
  }
  @override bool shouldRepaint(covariant CustomPainter o) => true;
}
