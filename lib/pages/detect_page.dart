import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:share_plus/share_plus.dart';
import 'package:ultralytics_yolo/yolo.dart';
import 'batch_page.dart';
import '../utils/export_helper.dart';
import '../utils/class_maps.dart';
import '../models/detection_record.dart';
import '../models/database.dart';

class DetectPage extends StatefulWidget {
  const DetectPage({super.key});
  @override State<DetectPage> createState() => _DetectPageState();
}

class _DetectPageState extends State<DetectPage> {
  final _picker = ImagePicker();
  String _serverUrl = 'http://218.195.250.194:8765';
  Uint8List? _rawBytes;
  int _imgW = 640, _imgH = 640;
  List<_Det> _dets = const [];
  bool _busy = false, _hasRun = false;
  double _conf = 0.25;
  String? _dbg;

  bool _enh = false;
  double _sc = 1, _cr = 1, _rt = 0;
  double _br = 0, _ct = 0, _st = 1;
  String _mdl = 'VOC (20类)';
  bool _useLocal = false;
  YOLO? _yoloInstance;
  bool _localReady = false;
  bool _uploaded = false;
  bool _uploading = false;

  bool _camOn = false;
  CameraController? _camCtrl;
  List<_Det> _live = [];
  Timer? _timer;
  int _lW = 640, _lH = 480;

  @override void initState() { super.initState(); _initC(); }
  @override void dispose() { _timer?.cancel(); _camCtrl?.dispose(); super.dispose(); }

  Future<void> _pick(ImageSource s) async {
    if (_busy) return;
    if (s == ImageSource.gallery) {
      // 相册：支持多选，1张走单图，多张走批量
      var files = await _picker.pickMultiImage(imageQuality: 85, limit: 9);
      if (files.isEmpty) return;
      if (files.length == 1) {
        var b = await files[0].readAsBytes();
        if (mounted) setState(() { _rawBytes = b; _dets = const []; _hasRun = false; _dbg = null; });
      } else {
        if (!mounted) return;
        await Navigator.push(context, MaterialPageRoute(
          builder: (_) => BatchPage(files: files, serverUrl: _serverUrl, conf: _conf, isVoc: _mdl.contains('VOC')),
        ));
      }
      return;
    }
    // 拍照：单张
    var f = await _picker.pickImage(source: s, imageQuality: 85);
    if (f == null) return;
    var b = await f.readAsBytes();
    if (mounted) setState(() { _rawBytes = b; _dets = const []; _hasRun = false; _dbg = null; });
  }

  Future<void> _toggleLocal(bool v) async {
    if (v && !_localReady) {
      try {
        _yoloInstance = YOLO(modelPath: 'assets/coco_model.tflite', task: YOLOTask.detect, useGpu: false);
        await _yoloInstance!.loadModel();
        _localReady = true;
      } catch (e) { setState(() => _useLocal = false); return; }
    }
    setState(() => _useLocal = v);
  }

  Future<void> _detect() async {
    if (_rawBytes == null) return;
    if (_useLocal) { await _localDetect(); return; }
    var sendBytes = _applyTransform(_rawBytes!);
    setState(() { _busy = true; _dbg = null; });
    var sw = Stopwatch()..start();
    try {
      var u = Uri.parse('$_serverUrl/api/detect');
      var r = http.MultipartRequest('POST', u);
      r.fields['conf'] = _conf.toString();
      r.fields['model'] = _mdl.contains('VOC') ? 'voc' : 'coco';
      r.files.add(http.MultipartFile.fromBytes('file', sendBytes, filename: 'img.jpg'));
      var resp = await http.Response.fromStream(await r.send()).timeout(const Duration(seconds: 15));
      sw.stop();
      if (resp.statusCode != 200) { if (mounted) setState(() { _busy = false; _dbg = 'HTTP ${resp.statusCode}'; }); return; }
      var data = jsonDecode(resp.body);
      var list = (data['objects'] as List?)?.map((o) {
        var bb = o['bbox'] as List;
        return _Det(bb[0].toDouble(), bb[1].toDouble(), bb[2].toDouble(), bb[3].toDouble(),
            (o['confidence'] as num).toDouble(), o['class'] as String);
      }).toList() ?? [];
      var sw2 = data['width'] as int? ?? 0;
      var sh2 = data['height'] as int? ?? 0;
      if (sw2 > 0 && sh2 > 0) { _imgW = sw2; _imgH = sh2; }
      var now = DateTime.now().millisecondsSinceEpoch;
      try {
        var dir = await getApplicationDocumentsDirectory();
        // 保存原始图（未变换）到历史记录，保留未来调整可能性
        await File('${dir.path}/$now.jpg').writeAsBytes(_rawBytes!);
        await AppDatabase.insertRecord(DetectionRecord(
          id: now, imagePath: '${dir.path}/$now.jpg',
          imageName: now.toString(),
          uploadedAt: DateTime.now().toString().substring(0, 19),
          count: list.length, processMs: sw.elapsedMilliseconds,
          objects: list.map((b) => DetectedObject(className: b.label, confidence: b.score, bbox: [b.x1, b.y1, b.x2, b.y2])).toList(),
        ));
      } catch (_) {}
      if (mounted) setState(() { _dets = list; _hasRun = true; _busy = false; _uploaded = false;
        _dbg = '${list.length}目标 ${sw.elapsedMilliseconds}ms'; });
    } catch (e) { if (mounted) setState(() { _busy = false; _dbg = '连接失败($e)'; }); }
  }

  Future<void> _localDetect() async {
    if (_rawBytes == null || _yoloInstance == null) return;
    setState(() { _busy = true; _dbg = null; });
    var sw = Stopwatch()..start();
    try {
      var res = await _yoloInstance!.predict(_rawBytes!, confidenceThreshold: _conf);
      sw.stop();
      var dets = res['detections'] as List? ?? [];
      var list = <_Det>[];
      for (var r in dets) {
        var m = r as Map;
        var bb = m['boundingBox'] as Map;
        list.add(_Det(
          (bb['left'] as num).toDouble(), (bb['top'] as num).toDouble(),
          (bb['right'] as num).toDouble(), (bb['bottom'] as num).toDouble(),
          (m['confidence'] as num).toDouble(), m['className'] as String,
        ));
      }
      if (mounted) setState(() { _dets = list; _hasRun = true; _busy = false; _uploaded = false;
        _imgW = 640; _imgH = 640;
        _dbg = '${list.length}目标 ${sw.elapsedMilliseconds}ms (本地)'; });
    } catch (e) {
      if (mounted) setState(() { _busy = false; _dbg = '本地推理失败: $e'; });
    }
  }

  void _resetE() { setState(() { _sc = 1; _cr = 1; _rt = 0; _br = 0; _ct = 0; _st = 1; }); }

  /// 对原始图片应用旋转 + 裁剪变换，使发送到服务器的图与预览一致
  Uint8List _applyTransform(Uint8List bytes) {
    if (_rt == 0 && _cr >= 1.0) return bytes;
    var image = img.decodeImage(bytes);
    if (image == null) return bytes;
    // 旋转
    if (_rt != 0) {
      image = img.copyRotate(image, angle: _rt.toInt());
    }
    // 中心裁剪
    if (_cr < 1.0) {
      var cw = (image.width * _cr).toInt();
      var ch = (image.height * _cr).toInt();
      var cx = ((image.width - cw) / 2).toInt();
      var cy = ((image.height - ch) / 2).toInt();
      image = img.copyCrop(image, x: cx, y: cy, width: cw, height: ch);
    }
    return Uint8List.fromList(img.encodeJpg(image));
  }

  Future<void> _initC() async {
    try { final cs = await availableCameras(); if (cs.isNotEmpty) { _camCtrl = CameraController(cs.first, ResolutionPreset.medium); await _camCtrl!.initialize(); } } catch (_) {}
  }

  void _enterC() {
    if (_camCtrl == null || !_camCtrl!.value.isInitialized) return;
    setState(() => _camOn = true);
    _timer = Timer.periodic(const Duration(milliseconds: 800), (_) async {
      if (!_camOn || _camCtrl == null) return;
      try {
        final p = await _camCtrl!.takePicture();
        final b = await p.readAsBytes();
        final d = await _send(b);
        if (mounted && _camOn) setState(() => _live = d);
      } catch (_) {}
    });
  }

  void _exitC() { _timer?.cancel(); setState(() { _camOn = false; _live = []; }); }

  void _editClass(int idx) {
    var d = _dets[idx];
    var classes = getClassList(isVoc: _mdl.contains('VOC'));
    var searchCtrl = TextEditingController();
    showModalBottomSheet(context: context, isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheetState) {
          var filtered = searchCtrl.text.isEmpty ? classes
              : classes.where((c) => c.contains(searchCtrl.text)).toList();
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(children: [
              Padding(padding: const EdgeInsets.fromLTRB(16, 12, 8, 0), child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [const Text('选择正确类别', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消'))]),
              ),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: TextField(
                controller: searchCtrl,
                decoration: InputDecoration(hintText: '搜索类别...', prefixIcon: const Icon(Icons.search, size: 20),
                  filled: true, fillColor: const Color(0xFFF5F7FA),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE8ECF1))),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                onChanged: (_) => setSheetState(() {}),
              )),
              Expanded(child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  var cls = filtered[i];
                  return ListTile(
                    leading: Icon(cls == d.label ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: cls == d.label ? Theme.of(ctx).colorScheme.primary : Colors.grey, size: 22),
                    title: Text(cls, style: TextStyle(fontWeight: cls == d.label ? FontWeight.w600 : FontWeight.normal)),
                    onTap: () { setState(() => d.label = cls); Navigator.pop(ctx); },
                  );
                },
              )),
            ]),
          );
        });
      },
    );
  }

  /// 在图片上绘制检测框，返回带框的图片字节
  Uint8List _drawBoxes(Uint8List bytes) {
    var image = img.decodeImage(bytes);
    if (image == null) return bytes;
    var cols = [
      [255,0,0], [0,255,0], [0,0,255], [255,165,0],
      [128,0,128], [0,128,128], [255,192,203], [75,0,130]
    ];
    for (int i = 0; i < _dets.length; i++) {
      var d = _dets[i];
      var c = cols[i % cols.length];
      var x1 = (d.x1 * image.width / _imgW).round();
      var y1 = (d.y1 * image.height / _imgH).round();
      var x2 = (d.x2 * image.width / _imgW).round();
      var y2 = (d.y2 * image.height / _imgH).round();
      img.drawRect(image, x1: x1, y1: y1, x2: x2, y2: y2, color: img.ColorRgba8(c[0], c[1], c[2], 255), thickness: 3);
    }
    return Uint8List.fromList(img.encodeJpg(image));
  }

  /// 上传标注到服务器
  Future<void> _uploadToServer(BuildContext ctx) async {
    if (_rawBytes == null || _dets.isEmpty) return;
    setState(() => _uploading = true);
    try {
      var host = Uri.parse(_serverUrl).host;
      var url = 'http://$host:8767/api/annotations/upload';
      var req = http.MultipartRequest('POST', Uri.parse(url));
      var sendBytes = _applyTransform(_rawBytes!);
      req.files.add(await http.MultipartFile.fromBytes('file', sendBytes, filename: 'img.jpg'));
      var isVoc = _mdl.contains('VOC');
      var map = isVoc ? VOC_MAP : COCO_MAP;
      var lines = _dets.map((d) {
        var clsId = map[d.label];
        var xc = ((d.x1 + d.x2) / 2) / _imgW;
        var yc = ((d.y1 + d.y2) / 2) / _imgH;
        var w = (d.x2 - d.x1) / _imgW;
        var h = (d.y2 - d.y1) / _imgH;
        return '$clsId ${xc.toStringAsFixed(6)} ${yc.toStringAsFixed(6)} ${w.toStringAsFixed(6)} ${h.toStringAsFixed(6)}';
      }).join('\n');
      req.fields['label'] = lines;
      req.fields['model'] = isVoc ? 'voc' : 'coco';
      var resp = await http.Response.fromStream(await req.send()).timeout(const Duration(seconds: 10));
      if (mounted) setState(() { _uploading = false; _uploaded = resp.statusCode == 200;
        _dbg = resp.statusCode == 200 ? '上传成功' : '上传失败'; });
    } catch (e) {
      if (mounted) setState(() { _uploading = false; _dbg = '上传失败'; });
    }
  }

  /// 导出弹窗
  void _showExportDialog(BuildContext ctx) {
    if (_rawBytes == null) return;
    showModalBottomSheet(
      context: ctx,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx2) {
        var isVoc = _mdl.contains('VOC');
        var item = ExportItem(
          name: DateTime.now().millisecondsSinceEpoch.toString(),
          imageBytes: _rawBytes!,
          imgW: _imgW, imgH: _imgH,
          targets: _dets.map((d) => ExportTarget(d.label, d.x1, d.y1, d.x2, d.y2)).toList(),
        );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('导出检测结果', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text('选择导出格式', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
              const Divider(height: 20),

              // 选项1：标注文件
              _exportOption(
                icon: Icons.description_outlined,
                title: '标注文件 (YOLO .txt)',
                desc: '类别ID + 归一化坐标，可用于模型训练',
                onSave: () async {
                  try {
                    var p = await exportSingleYolo(item, isVoc: isVoc);
                    if (ctx2.mounted) Navigator.pop(ctx2);
                    if (mounted) setState(() => _dbg = '标注已保存');
                  } catch (e) {
                    if (mounted) setState(() => _dbg = '导出失败');
                  }
                },
                onShare: () async {
                  try { await shareAnnotation(item, isVoc: isVoc); } catch (_) {}
                  if (ctx2.mounted) Navigator.pop(ctx2);
                },
              ),
              const Divider(height: 4),

              // 选项2：检测图片
              _exportOption(
                icon: Icons.image_outlined,
                title: '检测图片 (带框)',
                desc: '图片上绘制了边界框和标签',
                onSave: () async {
                  var boxed = _drawBoxes(_rawBytes!);
                  try {
                    var dir = await getApplicationDocumentsDirectory();
                    var p = '${dir.path}/yolo_export/${item.name}_detected.jpg';
                    await File(p).writeAsBytes(boxed);
                    if (ctx2.mounted) Navigator.pop(ctx2);
                    if (mounted) setState(() => _dbg = '图片已保存');
                  } catch (e) {
                    if (mounted) setState(() => _dbg = '保存失败');
                  }
                },
                onShare: () async {
                  var boxed = _drawBoxes(_rawBytes!);
                  var dir = await getApplicationDocumentsDirectory();
                  var p = '${dir.path}/yolo_export/${item.name}_detected.jpg';
                  await File(p).writeAsBytes(boxed);
                  await SharePlus.instance.share(ShareParams(
                    files: [XFile(p)], fileNameOverrides: ['${item.name}_detected.jpg'],
                  ));
                  if (ctx2.mounted) Navigator.pop(ctx2);
                },
              ),
              const Divider(height: 4),

              // 选项3：打包 .zip
              _exportOption(
                icon: Icons.folder_outlined,
                title: '打包下载 (.zip)',
                desc: '图片 + YOLO 标注 + 类别名，一个压缩包',
                onSave: () async {
                  try {
                    var zip = await exportZip([item], isVoc: isVoc);
                    if (ctx2.mounted) Navigator.pop(ctx2);
                    if (mounted) setState(() => _dbg = '压缩包已保存');
                  } catch (e) {
                    if (mounted) setState(() => _dbg = '导出失败');
                  }
                },
                onShare: () async {
                  try {
                    var zip = await exportZip([item], isVoc: isVoc);
                    await shareZip(zip);
                  } catch (_) {}
                  if (ctx2.mounted) Navigator.pop(ctx2);
                },
              ),
              const SizedBox(height: 8),
            ]),
          ),
        );
      },
    );
  }

  /// 导出选项行
  Widget _exportOption({
    required IconData icon, required String title, required String desc,
    required VoidCallback onSave, VoidCallback? onShare,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Icon(icon, size: 22, color: Colors.grey.shade700),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          Text(desc, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        ])),
        const SizedBox(width: 8),
        _miniBtn(Icons.save_outlined, '保存', onSave),
        if (onShare != null) ...[const SizedBox(width: 4), _miniBtn(Icons.share_outlined, '分享', onShare)],
      ]),
    );
  }

  Widget _miniBtn(IconData icon, String label, VoidCallback onTap) {
    return SizedBox(
      height: 32,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 14), label: Text(label, style: const TextStyle(fontSize: 11)),
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
      ),
    );
  }

  Future<List<_Det>> _send(Uint8List b) async {
    try {
      var u = Uri.parse('$_serverUrl/api/detect');
      var r = http.MultipartRequest('POST', u);
      r.fields['conf'] = _conf.toString();
      r.fields['model'] = _mdl.contains('VOC') ? 'voc' : 'coco';
      r.files.add(http.MultipartFile.fromBytes('file', b, filename: 'f.jpg'));
      var resp = await http.Response.fromStream(await r.send()).timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) return [];
      var data = jsonDecode(resp.body);
      _lW = (data['width'] as int?) ?? 640;
      _lH = (data['height'] as int?) ?? 480;
      return (data['objects'] as List?)?.map((o) {
        var bb = o['bbox'] as List;
        return _Det(bb[0].toDouble(), bb[1].toDouble(), bb[2].toDouble(), bb[3].toDouble(),
            (o['confidence'] as num).toDouble(), o['class'] as String);
      }).toList() ?? [];
    } catch (_) { return []; }
  }

  @override
  Widget build(BuildContext context) {
    if (_camOn) return _camView(context);
    var t = Theme.of(context); var has = _rawBytes != null;
    return Scaffold(
      appBar: AppBar(title: const Text('灵眸'), actions: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text('本地', style: TextStyle(fontSize: 11, color: _useLocal ? t.colorScheme.primary : Colors.grey)),
          Switch(value: _useLocal, onChanged: _toggleLocal, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
        ]),
        Padding(padding: const EdgeInsets.only(right: 12), child: _mdlBtn()),
      ]),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),

          // 图片 — 自适应高度
          if (has)
            Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: AspectRatio(
              aspectRatio: _imgW / (_imgH > 0 ? _imgH : 640),
              child: Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE8ECF1))),
                child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Stack(children: [
                  _imgPrev(),
                  if (_dets.isNotEmpty) Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _BoxP(_dets, _imgW.toDouble(), _imgH.toDouble())))),
                ])),
              ),
            )),

          // 空状态
          if (!has) Container(
            margin: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE8ECF1))),
            child: Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 80), child: Column(children: [
              Icon(Icons.image_outlined, size: 64, color: Colors.grey.shade300),
              const SizedBox(height: 12), Text('选择图片进行检测', style: TextStyle(fontSize: 15, color: Colors.grey.shade500)),
            ])))),

          if (has) _enhPanel(t),

          if (has) Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 0), child: Row(children: [
            Text('置信度', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            Expanded(child: Slider(value: _conf, min: 0.05, max: 0.95, activeColor: t.colorScheme.primary, onChanged: (v) => setState(() => _conf = v))),
            Text(_conf.toStringAsFixed(2), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.colorScheme.primary)),
          ])),

          if (has) Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 0), child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE8ECF1))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('检测结果', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.colorScheme.onSurface)),
                if (_dets.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 8), child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: t.colorScheme.primary, borderRadius: BorderRadius.circular(8)),
                  child: Text('${_dets.length}', style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)))),
              ]),
              const SizedBox(height: 6),
              if (_dets.isEmpty) Center(child: Text(_hasRun ? '未检测到目标' : '', style: TextStyle(color: Colors.grey.shade500))),
              if (_dets.isNotEmpty) ..._dets.asMap().entries.map((e) {
                int i = e.key; var d = e.value;
                var cs = [Colors.red, Colors.green, Colors.blue, Colors.orange, Colors.purple, Colors.teal, Colors.pink, Colors.indigo]; var c = cs[i % cs.length];
                return Column(children: [
                  if (i > 0) const Divider(height: 1),
                  ListTile(dense: true, leading: Container(width: 12, height: 12, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                    title: Text(d.label, style: const TextStyle(fontSize: 14)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('${(d.score * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c)),
                      const SizedBox(width: 4),
                      InkWell(onTap: () => _editClass(i),
                        child: Container(padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(6)),
                          child: Icon(Icons.edit_outlined, size: 14, color: Colors.grey.shade600)),
                      ),
                    ])),
                ]);
              }),
            ]),
          )),

          if (has)
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 0), child: Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: (_dets.isEmpty && !_hasRun) ? null : () => _showExportDialog(context),
                icon: const Icon(Icons.file_download_outlined, size: 16),
                label: const Text('导出', style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10)))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton.icon(
                onPressed: (_dets.isEmpty || _uploaded) ? null : () => _uploadToServer(context),
                icon: _uploading
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.cloud_upload_outlined, size: 16),
                label: Text(_uploaded ? '已上传' : (_uploading ? '上传中' : '上传'), style: const TextStyle(fontSize: 13)),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10)))),
            ])),
          if (has) Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: Text('修正类别后上传到服务器，用于模型增量训练',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ),

          _btnRow(has),
        ]),
      ),
    );
  }

  Widget _camView(BuildContext ctx) {
    if (_camCtrl == null || !_camCtrl!.value.isInitialized) {
      return Scaffold(appBar: AppBar(title: const Text('实时检测')), body: const Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('实时检测'), leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _exitC)),
      body: Stack(children: [
        Positioned.fill(child: CameraPreview(_camCtrl!)),
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _BoxP(_live, _lW.toDouble(), _lH.toDouble())))),
        Positioned(top: 12, left: 12, child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
          child: Text('${_live.length} 目标', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)))),
      ]),
    );
  }

  Widget _btnRow(bool has) {
    return Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), child: Row(children: [
      _obtn(Icons.photo_library_outlined, '相册', () => _pick(ImageSource.gallery)),
      const SizedBox(width: 8),
      _obtn(Icons.camera_alt_outlined, '拍照', () => _pick(ImageSource.camera)),
      const SizedBox(width: 8),
      _obtn(Icons.videocam_outlined, '实时', _enterC),
      const SizedBox(width: 8),
      Expanded(child: FilledButton.icon(
        onPressed: (has && !_busy) ? _detect : null, icon: const Icon(Icons.search, size: 16),
        label: const Text('检测', style: TextStyle(fontSize: 13)),
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)))),
    ]));
  }

  Widget _obtn(IconData icon, String label, VoidCallback cb) {
    return Expanded(child: OutlinedButton.icon(
      onPressed: _busy ? null : cb, icon: Icon(icon, size: 16), label: Text(label, style: const TextStyle(fontSize: 13)),
      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12))));
  }

  Widget _enhPanel(ThemeData t) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFE8ECF1))),
      child: Column(children: [
        InkWell(onTap: () => setState(() => _enh = !_enh), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), child: Row(children: [
          Icon(Icons.tune, size: 18, color: t.colorScheme.primary), const SizedBox(width: 8),
          const Text('图片增强', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          const Spacer(), Icon(_enh ? Icons.expand_less : Icons.expand_more, size: 20),
        ]))),
        if (_enh) ...[const Divider(height: 1),
          Padding(padding: const EdgeInsets.fromLTRB(14, 4, 14, 8), child: Column(children: [
            _sl('缩放', _sc, 0.5, 2, (v) => _sc = v, '${_sc.toStringAsFixed(1)}x'),
            _sl('裁剪', _cr, 0.4, 1, (v) => _cr = v, '${(_cr*100).toInt()}%'),
            _sl('旋转', _rt, -45, 45, (v) => _rt = v, '${_rt.toInt()}°'),
            _sl('亮度', _br, -1, 1, (v) => _br = v, _br.toStringAsFixed(2)),
            _sl('对比度', _ct, -0.5, 0.5, (v) => _ct = v, _ct.toStringAsFixed(2)),
            _sl('饱和度', _st, 0, 2, (v) => _st = v, '${_st.toStringAsFixed(1)}x'),
            Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: _resetE, icon: const Icon(Icons.refresh, size: 16), label: const Text('重置', style: TextStyle(fontSize: 12)), style: TextButton.styleFrom(foregroundColor: Colors.grey.shade600))),
          ])),
        ],
      ]),
    );
  }

  Widget _imgPrev() {
    if (_rawBytes == null) return const SizedBox.shrink();
    Widget img = Image.memory(_rawBytes!, fit: BoxFit.contain);
    var cM = <double>[_ct+1,0,0,0,_br, 0,_ct+1,0,0,_br, 0,0,_ct+1,0,_br, 0,0,0,1,0];
    var sM = <double>[0.3086+0.6914*_st,0.6094-0.6094*_st,0.0820-0.0820*_st,0,0, 0.3086-0.3086*_st,0.6094+0.3906*_st,0.0820-0.0820*_st,0,0, 0.3086-0.3086*_st,0.6094-0.6094*_st,0.0820+0.9180*_st,0,0, 0,0,0,1,0];
    img = ColorFiltered(colorFilter: ColorFilter.matrix(sM), child: img);
    img = ColorFiltered(colorFilter: ColorFilter.matrix(cM), child: img);
    // 裁剪（视觉预览：中心缩放）
    if (_cr < 1.0) {
      img = ClipRect(child: Transform.scale(scale: 1.0 / _cr, alignment: Alignment.center, child: img));
    }
    return Transform(alignment: Alignment.center, transform: Matrix4.identity()..setEntry(0,0,_sc)..setEntry(1,1,_sc)..setEntry(2,2,_sc)..rotateZ(_rt*math.pi/180), child: img);
  }

  Widget _sl(String l, double v, double min, double max, ValueChanged<double> cb, String d) {
    return Row(children: [
      SizedBox(width: 48, child: Text(l, style: const TextStyle(fontSize: 12))),
      Expanded(child: Slider(value: v, min: min, max: max, onChanged: (n) => setState(() => cb(n)))),
      SizedBox(width: 40, child: Text(d, style: const TextStyle(fontSize: 11), textAlign: TextAlign.right)),
    ]);
  }

  Widget _mdlBtn() {
    return PopupMenuButton<String>(onSelected: (v) => setState(() => _mdl = v), itemBuilder: (_) => const [
      PopupMenuItem(value: 'COCO (80类)', child: Text('COCO (80类)')),
      PopupMenuItem(value: 'VOC (20类)', child: Text('VOC (20类)')),
    ], child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFBFDBFE))), child: Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.model_training, size: 16, color: Color(0xFF3B82F6)), const SizedBox(width: 6),
      Text(_mdl, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF3B82F6))),
      const Icon(Icons.arrow_drop_down, size: 18, color: Color(0xFF3B82F6)),
    ])));
  }
}

class _Det { final double x1, y1, x2, y2, score; String label;
  _Det(this.x1, this.y1, this.x2, this.y2, this.score, this.label); }

class _BoxP extends CustomPainter {
  final List<_Det> dets; final double iW, iH;
  _BoxP(this.dets, this.iW, this.iH);
  @override void paint(Canvas c, Size s) {
    if (iW <= 0 || iH <= 0) return;
    var sx = s.width / iW, sy = s.height / iH, sc = sx < sy ? sx : sy;
    var ox = (s.width - iW * sc) / 2, oy = (s.height - iH * sc) / 2;
    var cs = [Colors.red,Colors.green,Colors.blue,Colors.orange,Colors.purple,Colors.teal,Colors.pink,Colors.indigo];
    for (var i = 0; i < dets.length; i++) {
      var d = dets[i]; var col = cs[i%cs.length];
      var r = Rect.fromLTWH(ox+d.x1*sc, oy+d.y1*sc, (d.x2-d.x1)*sc, (d.y2-d.y1)*sc);
      c.drawRect(r, Paint()..color=col..style=PaintingStyle.stroke..strokeWidth=2.5);
      var lb = '${d.label} ${(d.score*100).toStringAsFixed(0)}%';
      var tp = TextPainter(text: TextSpan(text: lb, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)), textDirection: TextDirection.ltr)..layout();
      // 标签画在框内左上角
      c.drawRect(Rect.fromLTWH(r.left, r.top, tp.width+8, 22), Paint()..color=col);
      tp.paint(c, Offset(r.left+4, r.top+2));
    }
  }
  @override bool shouldRepaint(covariant CustomPainter o) => true;
}