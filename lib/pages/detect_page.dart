import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
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
  String _mdl = 'COCO (80类)';

  @override void initState() { super.initState(); }
  @override void dispose() { super.dispose(); }

  Future<void> _pick(ImageSource s) async {
    if (_busy) return;
    var f = await _picker.pickImage(source: s, imageQuality: 85);
    if (f == null) return;
    var b = await f.readAsBytes();
    if (mounted) setState(() { _rawBytes = b; _dets = const []; _hasRun = false; _dbg = null; });
  }

  Future<void> _detect() async {
    if (_rawBytes == null) return;
    setState(() { _busy = true; _dbg = null; });
    var sw = Stopwatch()..start();
    try {
      var u = Uri.parse('$_serverUrl/api/detect');
      var r = http.MultipartRequest('POST', u);
      r.fields['conf'] = _conf.toString();
      r.fields['model'] = _mdl.contains('VOC') ? 'voc' : 'coco';
      r.files.add(http.MultipartFile.fromBytes('file', _rawBytes!, filename: 'img.jpg'));
      var resp = await http.Response.fromStream(await r.send());
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
        await File('${dir.path}/$now.jpg').writeAsBytes(_rawBytes!);
        await AppDatabase.insertRecord(DetectionRecord(
          id: now, imagePath: '${dir.path}/$now.jpg',
          imageName: now.toString(),
          uploadedAt: DateTime.now().toString().substring(0, 19),
          count: list.length, processMs: sw.elapsedMilliseconds,
          objects: list.map((b) => DetectedObject(className: b.label, confidence: b.score, bbox: [b.x1, b.y1, b.x2, b.y2])).toList(),
        ));
      } catch (_) {}
      if (mounted) setState(() { _dets = list; _hasRun = true; _busy = false;
        _dbg = '${list.length}目标 ${sw.elapsedMilliseconds}ms'; });
    } catch (e) { if (mounted) setState(() { _busy = false; _dbg = '连接失败($e)'; }); }
  }

  void _resetE() { setState(() { _sc = 1; _cr = 1; _rt = 0; _br = 0; _ct = 0; _st = 1; }); }

  @override
  Widget build(BuildContext context) {
    var t = Theme.of(context); var has = _rawBytes != null;
    return Scaffold(
      appBar: AppBar(title: const Text('灵眸'), actions: [
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
              const SizedBox(height: 12), Text('选择图片开始检测', style: TextStyle(fontSize: 15, color: Colors.grey.shade500)),
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
                    trailing: Text('${(d.score * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c))),
                ]);
              }),
            ]),
          )),

          _btnRow(has),
        ]),
      ),
    );
  }

  Widget _btnRow(bool has) {
    return Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), child: Row(children: [
      _obtn(Icons.photo_library_outlined, '相册', () => _pick(ImageSource.gallery)),
      const SizedBox(width: 8),
      _obtn(Icons.camera_alt_outlined, '拍照', () => _pick(ImageSource.camera)),
      const SizedBox(width: 8),
      Expanded(flex: 2, child: FilledButton.icon(
        onPressed: (has && !_busy) ? _detect : null, icon: const Icon(Icons.search, size: 18),
        label: const Text('开始检测'), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)))),
    ]));
  }

  Widget _obtn(IconData icon, String label, VoidCallback cb) {
    return Expanded(child: OutlinedButton.icon(
      onPressed: _busy ? null : cb, icon: Icon(icon, size: 18), label: Text(label),
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

class _Det { final double x1, y1, x2, y2, score; final String label;
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
      c.drawRect(Rect.fromLTWH(r.left, r.top-22, tp.width+8, 22), Paint()..color=col);
      tp.paint(c, Offset(r.left+4, r.top-18));
    }
  }
  @override bool shouldRepaint(covariant CustomPainter o) => true;
}
