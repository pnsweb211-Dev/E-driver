import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../api/driver_api.dart';

/// Durable queue of everything the driver has done but the server has not yet
/// been told about.
///
/// Buses drive through dead zones. Before this, a GPS ping that failed to send
/// was retried a handful of times and then simply lost, and there was no way to
/// mark a child picked up without a live connection. Now every action is written
/// here FIRST, the UI updates from local state immediately, and the queue is
/// flushed whenever there is signal.
///
/// Deliberately plain: raw sqflite, no codegen, no dependency injection. The
/// background tracking isolate writes to this queue too, and an isolate has no
/// access to the Riverpod container or anything built around it.
///
/// Safety comes from [clientEventId]: the server holds a unique index on
/// (school_id, client_event_id), so flushing the same row twice is a no-op
/// rather than a duplicate boarding record.
class Outbox {
  Outbox._();

  static const _dbName = 'driver_outbox.db';
  static const _uuid = Uuid();

  static Database? _db;

  /// Kinds of queued work. Pings are batched; actions are replayed one by one.
  static const kindPing = 'ping';
  static const kindAction = 'action';

  static Future<Database> _open() async {
    if (_db != null) return _db!;

    final dir = await getApplicationDocumentsDirectory();

    _db = await openDatabase(
      p.join(dir.path, _dbName),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE outbox (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            endpoint TEXT,
            payload TEXT NOT NULL,
            client_event_id TEXT,
            created_at INTEGER NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT
          )
        ''');
        await db.execute('CREATE INDEX idx_outbox_kind ON outbox (kind, id)');
      },
    );

    return _db!;
  }

  /// Queue a GPS position. Carries its own timestamp so a batch flushed after an
  /// offline stretch reconstructs the real trail instead of collapsing every
  /// point onto the moment signal returned.
  static Future<void> enqueuePing({
    required double lat,
    required double lng,
    required double speed,
    DateTime? recordedAt,
  }) async {
    final db = await _open();

    await db.insert('outbox', {
      'kind': kindPing,
      'payload': jsonEncode({
        'lat': lat,
        'lng': lng,
        'speed': speed,
        'recorded_at': (recordedAt ?? DateTime.now()).toUtc().toIso8601String(),
      }),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Queue a driver action (mark picked, decline a run, log a call…).
  ///
  /// Returns the client event id so the caller can store it against its local
  /// optimistic state.
  static Future<String> enqueueAction({
    required String endpoint,
    required Map<String, dynamic> payload,
    String? clientEventId,
  }) async {
    final db = await _open();
    final id = clientEventId ?? _uuid.v4();

    await db.insert('outbox', {
      'kind': kindAction,
      'endpoint': endpoint,
      'payload': jsonEncode({...payload, 'client_event_id': id}),
      'client_event_id': id,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });

    return id;
  }

  /// How much is waiting. Shown in the UI so a driver knows work is queued and
  /// does not re-tap — the commonest cause of duplicate-looking records.
  static Future<int> pendingCount() async {
    final db = await _open();
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM outbox');

    return Sqflite.firstIntValue(rows) ?? 0;
  }

  static Future<int> pendingPings() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM outbox WHERE kind = ?',
      [kindPing],
    );

    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// Push everything queued to the server.
  ///
  /// Rows are deleted only on a definite outcome — success, or a rejection the
  /// server will never accept (4xx that is not auth/rate-limit). A network
  /// failure leaves the row alone so the next flush retries it. Returns the
  /// number of rows cleared.
  static Future<int> flush({DriverApi? api}) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token');

    if (token == null || token.isEmpty) return 0;

    final client = api ?? DriverApi(token: token, isDriverToken: prefs.getBool('is_driver_token') ?? false);
    final db = await _open();
    var cleared = 0;

    cleared += await _flushPings(db, client);
    cleared += await _flushActions(db, client);

    return cleared;
  }

  static Future<int> _flushPings(Database db, DriverApi api) async {
    // Chunked at 100: the server accepts up to 200 per request, and a smaller
    // chunk means a failure costs less to retry.
    final rows = await db.query(
      'outbox',
      where: 'kind = ?',
      whereArgs: [kindPing],
      orderBy: 'id ASC',
      limit: 100,
    );

    if (rows.isEmpty) return 0;

    final pings = rows
        .map((r) => jsonDecode(r['payload'] as String) as Map<String, dynamic>)
        .toList();

    final result = await api.sendLocationBatch(pings);

    if (!result.isFinal) {
      await _recordFailure(db, rows, result.message);
      return 0;
    }

    final ids = rows.map((r) => r['id']).join(',');
    await db.rawDelete('DELETE FROM outbox WHERE id IN ($ids)');

    return rows.length;
  }

  static Future<int> _flushActions(Database db, DriverApi api) async {
    final rows = await db.query(
      'outbox',
      where: 'kind = ?',
      whereArgs: [kindAction],
      orderBy: 'id ASC',
      limit: 50,
    );

    var cleared = 0;

    for (final row in rows) {
      final result = await api.post(
        row['endpoint'] as String,
        jsonDecode(row['payload'] as String) as Map<String, dynamic>,
      );

      if (result.isFinal) {
        await db.delete('outbox', where: 'id = ?', whereArgs: [row['id']]);
        cleared++;
      } else {
        await _recordFailure(db, [row], result.message);
        // Stop on the first unresolved failure: actions are ordered, and
        // replaying a later correction before an earlier mark would leave the
        // server holding the wrong final state.
        break;
      }
    }

    return cleared;
  }

  static Future<void> _recordFailure(
    Database db,
    List<Map<String, Object?>> rows,
    String? error,
  ) async {
    for (final row in rows) {
      await db.update(
        'outbox',
        {
          'attempts': (row['attempts'] as int? ?? 0) + 1,
          'last_error': error,
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  /// Drop everything. Used on sign-out so a queue is never flushed under the
  /// next driver's credentials.
  static Future<void> clear() async {
    final db = await _open();
    await db.delete('outbox');
  }
}
