import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'detection_record.dart';

class AppDatabase {
  static Database? _db;

  static Future<Database> get() async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dbPath, 'lingmou.db'),
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE history (
            id INTEGER PRIMARY KEY,
            image_name TEXT NOT NULL,
            uploaded_at TEXT NOT NULL,
            count INTEGER NOT NULL DEFAULT 0,
            process_ms INTEGER NOT NULL DEFAULT 0,
            objects_json TEXT NOT NULL DEFAULT '[]',
            image_path TEXT
          )
        ''');
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          try { await db.execute('ALTER TABLE history ADD COLUMN image_path TEXT'); } catch (_) {}
        }
      },
    );
    return _db!;
  }

  static Future<int> insertRecord(DetectionRecord r) async {
    final db = await get();
    return db.insert('history', {
      'id': r.id,
      'image_name': r.imageName,
      'uploaded_at': r.uploadedAt,
      'count': r.count,
      'process_ms': r.processMs,
      'objects_json': jsonEncode(r.objects.map((o) => {
        'class': o.className,
        'confidence': o.confidence,
        'bbox': o.bbox,
      }).toList()),
    });
  }

  static Future<List<DetectionRecord>> getAllRecords() async {
    final db = await get();
    final rows = await db.query('history', orderBy: 'id DESC');
    return rows.map((row) => DetectionRecord.fromDb(row)).toList();
  }

  static Future<void> deleteRecord(int id) async {
    final db = await get();
    await db.delete('history', where: 'id = ?', whereArgs: [id]);
  }
}
