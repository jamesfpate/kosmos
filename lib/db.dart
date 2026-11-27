import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Local state in SQLite (app data; survives updates, cleared on uninstall). Each table is id -> JSON.
class Db {
  Db._(this._db);

  final Database _db;

  static Future<Db> open() async {
    final path = p.join(await getDatabasesPath(), 'winnow.db');
    // v2: b2 (Backblaze B2 uploads).
    final db = await openDatabase(
      path,
      version: 2,
      onCreate: (db, _) async {
        for (final t in ['decisions', 'albums', 'uploads', 'meta', 'b2']) {
          await db.execute('CREATE TABLE $t (id TEXT PRIMARY KEY, json TEXT NOT NULL)');
        }
      },
      onUpgrade: (db, from, _) async {
        if (from < 2) await db.execute('CREATE TABLE b2 (id TEXT PRIMARY KEY, json TEXT NOT NULL)');
      },
    );
    return Db._(db);
  }

  Future<List<Map<String, Object?>>> all(String table) async {
    final rows = await _db.query(table);
    return [for (final r in rows) jsonDecode(r['json'] as String) as Map<String, Object?>];
  }

  Future<void> put(String table, String id, Object? value) =>
      _db.insert(table, {'id': id, 'json': jsonEncode(value)}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> putAll(String table, Map<String, Object?> values) async {
    final batch = _db.batch();
    values.forEach((id, v) {
      batch.insert(table, {'id': id, 'json': jsonEncode(v)}, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    await batch.commit(noResult: true);
  }

  Future<void> remove(String table, String id) => _db.delete(table, where: 'id = ?', whereArgs: [id]);

  Future<T?> getMeta<T>(String key) async {
    final rows = await _db.query('meta', where: 'id = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['json'] as String) as T?;
  }

  Future<void> setMeta(String key, Object? value) => put('meta', key, value);

  Future<Map<String, Object?>> allMeta() async {
    final rows = await _db.query('meta');
    return {for (final r in rows) r['id'] as String: jsonDecode(r['json'] as String)};
  }
}
