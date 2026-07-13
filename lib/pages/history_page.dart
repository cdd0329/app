import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/detection_record.dart';
import '../models/database.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<DetectionRecord> _records = [];
  String _search = '';
  int _page = 1;
  static const _per = 10;

  List<DetectionRecord> get _filtered {
    if (_search.isEmpty) return _records;
    return _records.where((r) => r.imageName.toLowerCase().contains(_search.toLowerCase())).toList();
  }
  List<DetectionRecord> get _paged => _filtered.skip((_page - 1) * _per).take(_per).toList();
  int get _tp => (_filtered.length / _per).ceil().clamp(1, 999);

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final recs = await AppDatabase.getAllRecords();
      if (mounted) setState(() => _records = recs);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('检测历史')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() { _search = v; _page = 1; }),
            decoration: InputDecoration(
              hintText: '搜索文件名...', prefixIcon: const Icon(Icons.search, size: 20),
              filled: true, fillColor: const Color(0xFFF5F7FA),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE8ECF1))),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
          ),
        ),
        Expanded(
          child: _records.isEmpty
              ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.history, size: 56, color: Colors.grey.shade300),
                  const SizedBox(height: 12),
                  Text('暂无检测记录', style: TextStyle(fontSize: 15, color: Colors.grey.shade500)),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _paged.length + 1,
                  itemBuilder: (_, i) {
                    if (i == _paged.length) return const SizedBox(height: 8);
                    final r = _paged[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _openDetail(r),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Icon(Icons.image_outlined, size: 20, color: t.colorScheme.primary),
                              const SizedBox(width: 8),
                              Expanded(child: Text(r.imageName, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14), overflow: TextOverflow.ellipsis)),
                              const SizedBox(width: 8),
                              Text('${r.count} 目标', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: t.colorScheme.primary)),
                              const SizedBox(width: 4),
                              Text('${r.processMs}ms', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                            ]),
                            const SizedBox(height: 6),
                            if (r.objects.isNotEmpty)
                              Wrap(spacing: 4, runSpacing: 4, children: r.objects.take(8).map((o) {
                                final x = o.className.hashCode;
                                final cs = [Colors.red, Colors.green, Colors.blue, Colors.orange, Colors.purple, Colors.teal, Colors.pink, Colors.indigo];
                                final c = cs[(x < 0 ? -x : x) % cs.length];
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
                                child: Text('${o.className} ${(o.confidence*100).toInt()}%',
                                    style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w500)));
                            }).toList()),
                            const SizedBox(height: 8),
                            Row(children: [
                              Text(r.uploadedAt, style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
                              const Spacer(),
                              GestureDetector(
                                onTap: () { AppDatabase.deleteRecord(r.id); setState(() { _records.remove(r); _page = 1; }); },
                                child: Padding(padding: const EdgeInsets.all(6), child: Icon(Icons.delete_outline, size: 18, color: Colors.red.shade300)),
                              ),
                              const SizedBox(width: 4),
                              GestureDetector(
                                onTap: () => _openDetail(r),
                                child: Padding(padding: const EdgeInsets.all(6), child: Icon(Icons.chevron_right, size: 20, color: Colors.grey.shade400)),
                              ),
                            ]),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (_tp > 1) Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFE8ECF1))), color: Colors.white),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(icon: const Icon(Icons.chevron_left), onPressed: _page > 1 ? () => setState(() => _page--) : null),
            Text('$_page / $_tp 页', style: const TextStyle(fontSize: 13)),
            IconButton(icon: const Icon(Icons.chevron_right), onPressed: _page < _tp ? () => setState(() => _page++) : null),
          ]),
        ),
      ]),
    );
  }

  void _openDetail(DetectionRecord r) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => _DetailPage(record: r)));
  }
}

class _DetailPage extends StatefulWidget {
  final DetectionRecord record;
  const _DetailPage({required this.record});
  @override
  State<_DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<_DetailPage> {
  Uint8List? _imgBytes;
  int _imgW = 640, _imgH = 640;

  @override
  void initState() {
    super.initState();
    if (widget.record.imagePath != null) {
      try {
        final file = File(widget.record.imagePath!);
        if (file.existsSync()) {
          _imgBytes = file.readAsBytesSync();
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = [Colors.red,Colors.green,Colors.blue,Colors.orange,Colors.purple,Colors.teal,Colors.pink,Colors.indigo];
    return Scaffold(
      appBar: AppBar(title: Text(widget.record.imageName)),
      body: Column(children: [
        Container(
          width: double.infinity, padding: const EdgeInsets.all(16), color: const Color(0xFFF5F7FA),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _stat('目标', '${widget.record.count}', Theme.of(context).colorScheme.primary),
            _stat('耗时', '${widget.record.processMs}ms', Theme.of(context).colorScheme.primary),
            _stat('时间', widget.record.uploadedAt.length >= 16 ? widget.record.uploadedAt.substring(0, 16) : widget.record.uploadedAt, Theme.of(context).colorScheme.primary),
          ]),
        ),
        if (_imgBytes != null)
          Container(
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE8ECF1))),
            child: ClipRRect(borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: double.infinity,
                height: 240,
                child: Center(child: Stack(children: [
                  Image.memory(_imgBytes!, fit: BoxFit.contain, width: double.infinity, height: 240),
                  if (widget.record.objects.isNotEmpty)
                    CustomPaint(
                      size: Size(_imgW.toDouble(), _imgH.toDouble()),
                      painter: _HistBoxPaint(widget.record.objects, _imgW.toDouble(), _imgH.toDouble()),
                    ),
                ])),
              ),
            ),
          ),
        Expanded(child: widget.record.objects.isEmpty
            ? const Center(child: Text('无检测数据'))
            : ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: widget.record.objects.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final o = widget.record.objects[i];
                  final c = cs[i % cs.length];
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8),
                        border: Border(left: BorderSide(color: c, width: 3))),
                    child: Row(children: [
                      Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                      const SizedBox(width: 10),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(o.className, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                        const SizedBox(height: 2),
                        Text('bbox: ${o.bbox.map((e) => e.toInt()).join(', ')}', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                      ])),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                          child: Text('${(o.confidence*100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c))),
                    ]),
                  );
                })),
      ]),
    );
  }
}

Widget _stat(String label, String value, Color color) {
  return Column(children: [
    Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    const SizedBox(height: 4),
    Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
  ]);
}

class _HistBoxPaint extends CustomPainter {
  final List<DetectedObject> dets; final double iW, iH;
  _HistBoxPaint(this.dets, this.iW, this.iH);
  @override void paint(Canvas c, Size s) {
    final cs = [Colors.red,Colors.green,Colors.blue,Colors.orange,Colors.purple,Colors.teal,Colors.pink,Colors.indigo];
    for (var i = 0; i < dets.length; i++) {
      final o = dets[i]; final col = cs[i % cs.length];
      final b = o.bbox;
      final r = Rect.fromLTWH(b[0]*s.width/iW, b[1]*s.height/iH, (b[2]-b[0])*s.width/iW, (b[3]-b[1])*s.height/iH);
      c.drawRect(r, Paint()..color=col..style=PaintingStyle.stroke..strokeWidth=2);
      final lb = '${o.className} ${(o.confidence*100).toStringAsFixed(0)}%';
      final tp = TextPainter(text: TextSpan(text: lb, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)), textDirection: TextDirection.ltr)..layout();
      c.drawRect(Rect.fromLTWH(r.left, r.top-20, tp.width+6, 20), Paint()..color=col);
      tp.paint(c, Offset(r.left+3, r.top-16));
    }
  }
  @override bool shouldRepaint(covariant CustomPainter o) => true;
}
