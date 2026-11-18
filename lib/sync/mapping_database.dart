import 'package:sqflite/sqflite.dart';
import 'database_provider.dart';

class MappingDatabase {
  static const _tableName = 'sync_mappings';
  static const _columnId = 'id';
  static const _columnProfileId = 'profile_id';
  static const _columnSourceCalendarId = 'source_calendar_id';
  static const _columnSourceEventId = 'source_event_id';
  static const _columnSourceInstanceId = 'source_instance_id';
  static const _columnTargetCalendarId = 'target_calendar_id';
  static const _columnTargetEventId = 'target_event_id';
  static const _columnSyncedAt = 'synced_at';
  static const _columnCanonicalTime = 'canonical_time';

  static const _statusTable = 'sync_status';
  static const _statusId = 'id';
  static const _statusProfileId = 'profile_id';
  static const _statusTimestamp = 'timestamp';
  static const _statusSynced = 'synced';
  static const _statusDeleted = 'deleted';
  static const _statusSkipped = 'skipped';
  static const _statusErrors = 'errors';
  static const _statusUpdated = 'updated';

  static const _createdEventsTable = 'sync_created_events';
  static const _ceCalendarId = 'calendar_id';
  static const _ceEventId = 'event_id';

  final DatabaseProvider _dbProvider;

  MappingDatabase() : _dbProvider = DatabaseProvider();

  Future<Database> get database => _dbProvider.database;

  Future<bool> isEventSynced(
    String profileId,
    String sourceCalendarId,
    String sourceEventId, {
    String? sourceInstanceId,
  }) async {
    final db = await database;
    final instanceClause = sourceInstanceId != null
        ? '$_columnSourceInstanceId = ?'
        : '$_columnSourceInstanceId IS NULL';
    final instanceArgs =
        sourceInstanceId != null ? [sourceInstanceId] : const <Object?>[];
    final result = await db.query(
      _tableName,
      where:
          '$_columnProfileId = ? AND $_columnSourceCalendarId = ? AND $_columnSourceEventId = ? AND $instanceClause',
      whereArgs: [
        profileId,
        sourceCalendarId,
        sourceEventId,
        ...instanceArgs,
      ],
      limit: 1,
    );
    final synced = result.isNotEmpty;
    return synced;
  }

  Future<void> insertMapping({
    required String profileId,
    required String sourceCalendarId,
    required String sourceEventId,
    String? sourceInstanceId,
    required String targetCalendarId,
    required String targetEventId,
    required String syncedAt,
    String? canonicalTime,
  }) async {
    final db = await database;
    await db.insert(
      _tableName,
      {
        _columnProfileId: profileId,
        _columnSourceCalendarId: sourceCalendarId,
        _columnSourceEventId: sourceEventId,
        _columnSourceInstanceId: ?sourceInstanceId,
        _columnTargetCalendarId: targetCalendarId,
        _columnTargetEventId: targetEventId,
        _columnSyncedAt: syncedAt,
        _columnCanonicalTime: ?canonicalTime,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> hasPendingCreations(String profileId) async {
    final db = await database;
    final rows = await db.query(
      'sync_creation_reservations',
      where: 'profile_id = ?',
      whereArgs: [profileId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> ownsTarget(Map<String, Object?> mapping) async =>
      _ownsTarget(await database, mapping);

  Future<bool> _ownsTarget(
    DatabaseExecutor executor,
    Map<String, Object?> mapping,
  ) async {
    final rows = await executor.rawQuery(
      """SELECT m.id, EXISTS (
               SELECT 1 FROM sync_mappings duplicate
               WHERE duplicate.id <> m.id AND duplicate.profile_id = m.profile_id
                 AND duplicate.source_calendar_id = m.source_calendar_id
                 AND duplicate.source_event_id = m.source_event_id
                 AND duplicate.source_instance_id IS m.source_instance_id
             ) AS has_duplicate_source
           FROM sync_mappings m JOIN sync_created_events c
           ON c.calendar_id = m.target_calendar_id AND c.event_id = m.target_event_id
           WHERE m.target_calendar_id = ? AND m.target_event_id = ?""",
      [mapping['target_calendar_id'], mapping['target_event_id']],
    );
    return rows.length == 1 &&
        rows.single['id'] == mapping['id'] &&
        rows.single['has_duplicate_source'] == 0;
  }

  Future<bool> reserveCreation(
    String profileId,
    String sourceCalendarId,
    String sourceEventId,
    String? instanceId,
    String targetCalendarId,
  ) async {
    final db = await database;
    return db.transaction((txn) async {
      final profiles = await txn.query(
        'sync_profiles',
        where:
            'id = ? AND source_calendar_id = ? AND target_calendar_id = ? AND enabled = 1',
        whereArgs: [profileId, sourceCalendarId, targetCalendarId],
      );
      if (profiles.isEmpty) return false;
      final key = [
        profileId,
        sourceCalendarId,
        sourceEventId,
        instanceId ?? '',
      ];
      final existing = await txn.query(
        _tableName,
        where:
            "profile_id = ? AND source_calendar_id = ? AND source_event_id = ? AND COALESCE(source_instance_id, '') = ?",
        whereArgs: key,
      );
      final pending = await txn.query(
        'sync_creation_reservations',
        where: _reservationKey,
        whereArgs: key,
      );
      if (existing.isNotEmpty || pending.isNotEmpty) return false;
      await txn.insert('sync_creation_reservations', {
        'profile_id': profileId,
        'source_calendar_id': sourceCalendarId,
        'source_event_id': sourceEventId,
        'source_instance_id': instanceId ?? '',
      });
      return true;
    });
  }

  static const _reservationKey =
      'profile_id = ? AND source_calendar_id = ? AND source_event_id = ? AND source_instance_id = ?';

  Future<void> finishCreation({
    required String profileId,
    required String sourceCalendarId,
    required String sourceEventId,
    required String? sourceInstanceId,
    required String targetCalendarId,
    required String targetEventId,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(_tableName, {
        _columnProfileId: profileId,
        _columnSourceCalendarId: sourceCalendarId,
        _columnSourceEventId: sourceEventId,
        _columnSourceInstanceId: sourceInstanceId,
        _columnTargetCalendarId: targetCalendarId,
        _columnTargetEventId: targetEventId,
        _columnSyncedAt: DateTime.now().toIso8601String(),
      });
      await txn.insert(_createdEventsTable, {
        _ceCalendarId: targetCalendarId,
        _ceEventId: targetEventId,
      });
      final count = await txn.delete(
        'sync_creation_reservations',
        where: _reservationKey,
        whereArgs: [
          profileId,
          sourceCalendarId,
          sourceEventId,
          sourceInstanceId ?? '',
        ],
      );
      if (count != 1) {
        throw StateError('The calendar write has no reservation.');
      }
    });
  }

  Future<bool> changeOwnedTarget(
    Map<String, Object?> mapping,
    Future<bool> Function() change, {
    bool removeMapping = false,
    bool requireEnabledProfile = false,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      if (!await _ownsTarget(txn, mapping)) return false;
      if (requireEnabledProfile) {
        final active = await txn.query(
          'sync_profiles',
          where:
              'id = ? AND source_calendar_id = ? AND target_calendar_id = ? AND enabled = 1',
          whereArgs: [
            mapping['profile_id'],
            mapping['source_calendar_id'],
            mapping['target_calendar_id'],
          ],
          limit: 1,
        );
        if (active.isEmpty) return false;
      }
      if (!await change()) return false;
      if (removeMapping) {
        await txn.delete(
          _tableName,
          where: 'id = ?',
          whereArgs: [mapping['id']],
        );
        await txn.delete(
          _createdEventsTable,
          where: 'calendar_id = ? AND event_id = ?',
          whereArgs: [
            mapping['target_calendar_id'],
            mapping['target_event_id'],
          ],
        );
      }
      return true;
    });
  }

  Future<List<Map<String, Object?>>> listMappingsForCalendar(
    String profileId,
    String sourceCalendarId,
  ) async {
    final db = await database;
    final result = await db.query(
      _tableName,
      where:
          '$_columnProfileId = ? AND $_columnSourceCalendarId = ?',
      whereArgs: [profileId, sourceCalendarId],
    );
    return result;
  }

  Future<void> deleteMapping(int id) async {
    final db = await database;
    await db.delete(
      _tableName,
      where: '$_columnId = ?',
      whereArgs: [id],
    );
  }

  Future<void> insertStatus({
    required String profileId,
    required String timestamp,
    required int synced,
    required int deleted,
    required int skipped,
    required int updated,
    required int errors,
  }) async {
    final db = await database;
    await db.insert(_statusTable, {
      _statusProfileId: profileId,
      _statusTimestamp: timestamp,
      _statusSynced: synced,
      _statusDeleted: deleted,
      _statusSkipped: skipped,
      _statusUpdated: updated,
      _statusErrors: errors,
    });
    final count = (await db.rawQuery(
            'SELECT COUNT(*) AS cnt FROM $_statusTable WHERE $_statusProfileId = ?',
            [profileId]))
        .first['cnt'] as int;
    if (count > 20) {
      final oldest = await db.query(
        _statusTable,
        columns: [_statusId],
        where: '$_statusProfileId = ?',
        whereArgs: [profileId],
        orderBy: '$_statusId ASC',
        limit: count - 20,
      );
      for (final row in oldest) {
        await db.delete(
          _statusTable,
          where: '$_statusId = ?',
          whereArgs: [row[_statusId]],
        );
      }
    }
  }

  Future<List<Map<String, Object?>>> getStatusHistory({
    int limit = 20,
    String? profileId,
  }) async {
    final db = await database;
    if (profileId != null) {
      return db.query(
        _statusTable,
        where: '$_statusProfileId = ?',
        whereArgs: [profileId],
        orderBy: '$_statusId DESC',
        limit: limit,
      );
    }
    return db.query(
      _statusTable,
      orderBy: '$_statusId DESC',
      limit: limit,
    );
  }

  Future<bool> isEventCreatedBySync(
    String calendarId,
    String eventId,
  ) async {
    final db = await database;
    final result = await db.query(
      _createdEventsTable,
      where: '$_ceCalendarId = ? AND $_ceEventId = ?',
      whereArgs: [calendarId, eventId],
      limit: 1,
    );
    final created = result.isNotEmpty;
    return created;
  }

  Future<void> insertCreatedEvent(
    String calendarId,
    String eventId,
  ) async {
    final db = await database;
    await db.insert(
      _createdEventsTable,
      {
        _ceCalendarId: calendarId,
        _ceEventId: eventId,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> deleteCreatedEvent(
    String calendarId,
    String eventId,
  ) async {
    final db = await database;
    await db.delete(
      _createdEventsTable,
      where: '$_ceCalendarId = ? AND $_ceEventId = ?',
      whereArgs: [calendarId, eventId],
    );
  }

  Future<List<Map<String, Object?>>> listMappingsForProfile(
    String profileId,
  ) async {
    final db = await database;
    return db.query(
      _tableName,
      where: '$_columnProfileId = ?',
      whereArgs: [profileId],
    );
  }
}
