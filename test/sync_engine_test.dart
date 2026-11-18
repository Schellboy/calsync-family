import 'dart:io';

import 'package:calendar_sync/calendar/calendar_service.dart';
import 'package:calendar_sync/settings/profile_service.dart';
import 'package:calendar_sync/sync/database_provider.dart';
import 'package:calendar_sync/sync/mapping_database.dart';
import 'package:calendar_sync/sync/sync_engine.dart';
import 'package:device_calendar_plus/device_calendar_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

final start = DateTime.now().add(const Duration(days: 2));
final end = start.add(const Duration(hours: 2));

Event event(
  String id, {
  String calendar = 'source',
  String? instance,
  String title = 'Training',
  String? description,
  String? location,
  DateTime? from,
  DateTime? until,
  bool allDay = false,
  bool recurring = false,
  EventStatus status = EventStatus.confirmed,
}) => Event(
  eventId: id,
  instanceId: instance ?? id,
  calendarId: calendar,
  title: title,
  description: description,
  location: location,
  startDate: from ?? start,
  endDate: until ?? end,
  isAllDay: allDay,
  isRecurring: recurring,
  status: status,
  availability: EventAvailability.busy,
);

const marker = '🔃 Automatically created by CalSync';

class TestCalendar extends CalendarService {
  final events = <String, Event>{};
  final exceptionKeys = <String, (String, String)>{};
  final changes = <(String, String?), ({bool removed, String? movedId})>{};
  final unavailableCalendars = <String>{};
  final failedReads = <String>{};
  final deleted = <String>[];
  final updated = <String>[];
  bool offline = false;
  bool permissionDenied = false;
  bool rejectUpdate = false;
  bool rejectDelete = false;
  bool failAfterCreate = false;
  Future<void> Function()? afterCreate;
  int creates = 0;

  @override
  Future<void> verifyCalendars(String? sourceId, Set<String> targetIds) async {
    if (permissionDenied ||
        unavailableCalendars.contains(sourceId) ||
        unavailableCalendars.intersection(targetIds).isNotEmpty) {
      throw StateError('calendar not available');
    }
  }

  @override
  Future<List<Event>> listEvents(String calendarId, {DateTime? end}) async {
    if (failedReads.contains(calendarId)) throw StateError('list failed');
    return events.values
        .where(
          (event) =>
              event.calendarId == calendarId &&
              event.endDate.isAfter(DateTime.now()) &&
              (end == null || event.startDate.isBefore(end)),
        )
        .toList();
  }

  @override
  Future<Event?> getEvent(String eventId) async {
    if (failedReads.contains(eventId)) throw StateError('lookup failed');
    return events[eventId];
  }

  @override
  Future<bool> canDeleteEvents() async => !offline && !permissionDenied;

  @override
  Future<Map<String, (String, String)>> sourceExceptionKeys(
    String calendarId,
    Set<String> eventIds,
  ) async => {
    for (final id in eventIds)
      if (exceptionKeys.containsKey(id)) id: exceptionKeys[id]!,
  };

  @override
  Future<({bool removed, String? movedId})> sourceChange(
    String calendarId,
    String eventId,
    String? instanceId,
  ) async {
    if (failedReads.contains(eventId)) throw StateError('source read failed');
    return changes[(eventId, instanceId)] ?? (removed: false, movedId: null);
  }

  @override
  Future<String?> createEvent(
    String calendarId,
    String title,
    DateTime start,
    DateTime end, {
    String? description,
    bool? isAllDay,
    String? location,
  }) async {
    final id = 'created-${++creates}';
    events[id] = event(
      id,
      calendar: calendarId,
      title: title,
      description: description,
      from: start,
      until: end,
      allDay: isAllDay ?? false,
      location: location,
    );
    await afterCreate?.call();
    if (failAfterCreate) throw StateError('response lost');
    return id;
  }

  @override
  Future<bool> updateOwnedEvent(
    Event expected, {
    required String title,
    required DateTime start,
    required DateTime end,
    required String description,
    required bool allDay,
    required String? location,
  }) async {
    if (rejectUpdate || !identical(events[expected.eventId], expected)) {
      return false;
    }
    updated.add(expected.eventId);
    events[expected.eventId] = event(
      expected.eventId,
      calendar: expected.calendarId,
      from: start,
      until: end,
      title: title,
      description: description,
      allDay: allDay,
      location: location,
    );
    return true;
  }

  @override
  Future<bool> deleteOwnedEvent(Event expected) async {
    if (rejectDelete ||
        !await canDeleteEvents() ||
        !identical(events[expected.eventId], expected)) {
      return false;
    }
    events.remove(expected.eventId);
    deleted.add(expected.eventId);
    return true;
  }
}

void main() {
  late Directory temp;
  late TestCalendar calendar;
  late MappingDatabase db;
  late ProfileService profiles;
  late SyncEngine engine;
  late SyncProfile profile;

  Future<SyncProfile> addProfile(String name, String source) =>
      profiles.createProfile(
        name: name,
        sourceCalendarId: source,
        targetCalendarId: 'family',
        eventName: '',
        intervalMinutes: 60,
        enabled: true,
      );

  setUp(() async {
    initTestDb();
    temp = await Directory.systemTemp.createTemp('calsync-engine-');
    DatabaseProvider.setTestPath('${temp.path}/calendar.db');
    calendar = TestCalendar();
    db = MappingDatabase();
    profiles = ProfileService();
    engine = SyncEngine(calendar, db);
    profile = await addProfile('First team', 'source');
  });

  tearDown(() async {
    await (await db.database).close();
    await temp.delete(recursive: true);
  });

  Future<SyncResult> sync({
    SyncProfile? forProfile,
    String title = '',
    bool copyDescription = true,
    bool copyLocation = true,
    bool omitSourceTitle = false,
  }) {
    final selected = forProfile ?? profile;
    return engine.runSync(
      profileId: selected.id,
      sourceCalendarId: selected.sourceCalendarId!,
      targetCalendarId: 'family',
      syncEventName: title,
      copyDescription: copyDescription,
      copyLocation: copyLocation,
      omitSourceTitle: omitSourceTitle,
    );
  }

  Future<SyncPlan> preview() => engine.runDryRun(
    profileId: profile.id,
    sourceCalendarId: 'source',
    targetCalendarId: 'family',
    syncEventName: '',
    copyDescription: true,
    copyLocation: true,
  );

  Future<void> map(
    String source,
    String target, {
    String? instance,
    SyncProfile? owner,
    bool registered = true,
  }) async {
    final selected = owner ?? profile;
    await db.insertMapping(
      profileId: selected.id,
      sourceCalendarId: selected.sourceCalendarId!,
      sourceEventId: source,
      sourceInstanceId: instance,
      targetCalendarId: 'family',
      targetEventId: target,
      syncedAt: DateTime.now().toIso8601String(),
    );
    if (registered) await db.insertCreatedEvent('family', target);
  }

  Event target(
    String id, {
    String title = 'Training',
    String? location,
    String? desc,
  }) => event(
    id,
    calendar: 'family',
    title: title,
    location: location,
    description: desc ?? buildDescription('Training', null, true),
  );

  Future<void> removeSource({bool verified = true}) async {
    calendar.events['target'] = target('target');
    await map('match', 'target');
    if (verified) {
      calendar.changes[('match', null)] = (removed: true, movedId: null);
    }
  }

  test('creates once and keeps the same mapping on the next sync', () async {
    calendar.events['match'] = event(
      'match',
      location: 'Pitch A',
      description: 'Kit',
    );
    expect((await sync()).synced, ['match']);
    expect((await sync()).skipped, ['match']);
    expect(calendar.creates, 1);
    expect(calendar.events['created-1']!.location, 'Pitch A');
    expect(calendar.events['created-1']!.description, contains('Kit'));
    expect(await db.isEventCreatedBySync('family', 'created-1'), isTrue);
  });

  final changes = <String, Event>{
    'title colliding with a substring': event('match', title: 'Train'),
    'start time': event('match', from: start.add(const Duration(minutes: 30))),
    'end time': event('match', until: end.add(const Duration(minutes: 30))),
    'date': event(
      'match',
      from: start.add(const Duration(days: 1)),
      until: end.add(const Duration(days: 1)),
    ),
    'location': event('match', location: 'Pitch B'),
    'description': event('match', description: 'New details'),
    'all-day status': event('match', allDay: true),
  };
  for (final change in changes.entries) {
    test('updates existing event for ${change.key}', () async {
      calendar.events['match'] = change.value;
      calendar.events['target'] = target('target');
      await map('match', 'target');
      final rows = await db.listMappingsForProfile(profile.id);
      expect((await preview()).toUpdate, hasLength(1));
      expect((await sync()).updated, ['match']);
      expect(calendar.updated, ['target']);
      expect(calendar.creates, 0);
      expect(calendar.deleted, isEmpty);
      expect(await db.listMappingsForProfile(profile.id), rows);
      expect((await sync()).skipped, ['match']);
    });
  }

  test(
    'clears copied fields and preserves the custom title and title privacy',
    () async {
      calendar.events['match'] = event(
        'match',
        description: 'Personal details',
        location: 'Pitch',
      );
      calendar.events['target'] = target(
        'target',
        location: 'Old pitch',
        desc: 'Old details\n$marker',
      );
      await map('match', 'target');
      expect(
        (await sync(
          title: 'Busy',
          copyDescription: false,
          copyLocation: false,
          omitSourceTitle: true,
        )).updated,
        ['match'],
      );
      final written = calendar.events['target']!;
      expect(written.title, 'Busy');
      expect(written.location, isNull);
      expect(written.description, isNot(contains('Training')));
      expect(written.description, isNot(contains('Personal details')));
    },
  );

  test(
    'failed in-place update keeps the target and mapping and creates no replacement',
    () async {
      calendar.events['match'] = event('match', title: 'Changed');
      calendar.events['target'] = target('target');
      await map('match', 'target');
      calendar.rejectUpdate = true;
      expect((await sync()).errors, isNotEmpty);
      expect(calendar.updated, isEmpty);
      expect(calendar.deleted, isEmpty);
      expect(calendar.creates, 0);
      expect(await db.isEventSynced(profile.id, 'source', 'match'), isTrue);
    },
  );

  test(
    'a moved standalone source outside the window updates its existing target',
    () async {
      calendar.events['match'] = event(
        'match',
        from: start.add(const Duration(days: 60)),
        until: end.add(const Duration(days: 60)),
      );
      calendar.events['target'] = target('target');
      await map('match', 'target');
      expect((await sync()).updated, ['match']);
      expect(calendar.creates, 0);
      expect(calendar.deleted, isEmpty);
    },
  );

  test(
    'dry run and automatic sync keep confirmed removals until explicit confirmation',
    () async {
      await removeSource();
      final plans = await Future.wait([preview(), preview()]);
      expect(plans.first.toDelete.single.event.eventId, 'target');
      expect(calendar.deleted, isEmpty);
      expect(await db.isEventSynced(profile.id, 'source', 'match'), isTrue);
      expect((await sync()).deleted, isEmpty);
      expect(
        await engine.deleteConfirmedTargets(
          plans.first.toDelete,
          verifySourceRemoval: true,
        ),
        isTrue,
      );
      expect(calendar.deleted, ['target']);
      expect(await db.isEventSynced(profile.id, 'source', 'match'), isFalse);
    },
  );

  test(
    'missing data without positive removal evidence causes no deletion',
    () async {
      await removeSource(verified: false);
      expect((await preview()).toDelete, isEmpty);
      calendar.events.remove('target');
      expect((await preview()).errors, isNotEmpty);
      expect(calendar.deleted, isEmpty);
      expect(await db.isEventSynced(profile.id, 'source', 'match'), isTrue);
    },
  );

  for (final failure in [
    'offline',
    'permission',
    'source read',
    'target read',
    'reappeared',
    'target changed',
  ]) {
    test('confirmed deletion stops on $failure', () async {
      await removeSource();
      final plan = await preview();
      expect(plan.toDelete, hasLength(1));
      switch (failure) {
        case 'offline':
          calendar.offline = true;
        case 'permission':
          calendar.permissionDenied = true;
        case 'source read':
          calendar.failedReads.add('match');
        case 'target read':
          calendar.failedReads.add('target');
        case 'reappeared':
          calendar.changes.clear();
        case 'target changed':
          calendar.events['target'] = target(
            'target',
            title: 'Manually edited',
          );
      }
      expect(
        await engine.deleteConfirmedTargets(
          plan.toDelete,
          verifySourceRemoval: true,
        ),
        isFalse,
      );
      expect(calendar.deleted, isEmpty);
      expect(await db.isEventSynced(profile.id, 'source', 'match'), isTrue);
    });
  }

  test('incomplete source listing blocks the plan', () async {
    await removeSource();
    calendar.failedReads.add('source');
    expect((await preview()).errors, isNotEmpty);
    expect(calendar.deleted, isEmpty);
  });

  test('failed calendar deletion keeps the mapping for retry', () async {
    await removeSource();
    final plan = await preview();
    calendar.rejectDelete = true;
    expect(await engine.deleteConfirmedTargets(plan.toDelete), isFalse);
    expect(await db.isEventSynced(profile.id, 'source', 'match'), isTrue);
    expect(await db.isEventCreatedBySync('family', 'target'), isTrue);
  });

  test(
    'prioritizes a verified moved series exception and suppresses a duplicate',
    () async {
      calendar.events['moved'] = event(
        'moved',
        from: start.add(const Duration(days: 1)),
        until: end.add(const Duration(days: 1)),
      );
      calendar.events['target'] = target('target');
      await map('series', 'target', instance: 'series@old');
      calendar.changes[('series', 'series@old')] = (
        removed: false,
        movedId: 'moved',
      );
      expect((await preview()).toCreate, isEmpty);
      expect((await sync()).updated, ['moved']);
      expect((await sync()).skipped, ['moved']);
      expect(calendar.creates, 0);
    },
  );

  test(
    'an uncertain new series slot is withheld if the original slot vanished',
    () async {
      calendar.events['slot2'] = event(
        'series',
        recurring: true,
        instance: 'series@new',
      );
      calendar.events['target'] = target('target');
      await map('series', 'target', instance: 'series@old');
      final plan = await preview();
      expect(plan.toCreate, isEmpty);
      expect(plan.toDelete, isEmpty);
    },
  );

  test('only the canceled occurrence is proposed for deletion', () async {
    calendar.events['slot2'] = event(
      'series',
      recurring: true,
      instance: 'series@two',
    );
    calendar.events['target1'] = target('target1');
    calendar.events['target2'] = target('target2');
    await map('series', 'target1', instance: 'series@one');
    await map('series', 'target2', instance: 'series@two');
    calendar.changes[('series', 'series@one')] = (removed: true, movedId: null);
    final plan = await preview();
    expect(plan.toDelete.single.event.eventId, 'target1');
    expect(plan.toSkip.single.instanceId, 'series@two');
  });

  test(
    'a legacy recurring mapping is preserved without recreating the series',
    () async {
      calendar.events['slot1'] = event(
        'series',
        recurring: true,
        instance: 'series@one',
      );
      calendar.events['target'] = target('target');
      await map('series', 'target');
      expect((await sync()).errors, isNotEmpty);
      expect(calendar.creates, 0);
      expect(calendar.deleted, isEmpty);
    },
  );

  test(
    'syncs two profiles into a shared calendar with independent ownership',
    () async {
      final second = await addProfile('Second team', 'second');
      calendar.events['one'] = event('one');
      calendar.events['two'] = event('two', calendar: 'second');
      expect((await sync()).synced, ['one']);
      expect((await sync(forProfile: second)).synced, ['two']);
      final preview = await engine.previewProfileDeletion(profile.id);
      expect(preview.single.event.eventId, 'created-1');
      expect(await engine.deleteConfirmedTargets(preview), isTrue);
      expect(calendar.events.containsKey('created-2'), isTrue);
      expect(
        (await db.listMappingsForProfile(second.id)).single['target_event_id'],
        'created-2',
      );
    },
  );

  test(
    'shared target mapping is ambiguous and cannot be written or deleted',
    () async {
      final second = await addProfile('Second team', 'second');
      calendar.events['match'] = event('match', title: 'Changed');
      calendar.events['target'] = target('target');
      await map('match', 'target');
      await map('other', 'target', owner: second);
      expect((await sync()).errors, isNotEmpty);
      await expectLater(
        engine.previewProfileDeletion(profile.id),
        throwsStateError,
      );
      expect(calendar.updated, isEmpty);
      expect(calendar.deleted, isEmpty);
    },
  );

  test(
    'foreign, unregistered and marker-only targets never establish ownership',
    () async {
      calendar.events['match'] = event('match', title: 'Changed');
      for (final foreign in [
        event('target', calendar: 'family', description: 'Manual'),
        event('target', calendar: 'another-calendar', description: marker),
        target('target'),
      ]) {
        calendar.events['target'] = foreign;
        if (!await db.isEventSynced(profile.id, 'source', 'match')) {
          await map('match', 'target', registered: false);
        }
        expect((await sync()).errors, isNotEmpty);
        await expectLater(
          engine.previewProfileDeletion(profile.id),
          throwsStateError,
        );
      }
      expect(calendar.updated, isEmpty);
      expect(calendar.deleted, isEmpty);
    },
  );

  test(
    'an unmapped marked candidate is displayed but never adopted or deleted',
    () async {
      calendar.events['orphan'] = target('orphan');
      calendar.events['match'] = event('match');
      final plan = await preview();
      expect(plan.unmappedCandidates.single.eventId, 'orphan');
      expect(plan.toCreate, isEmpty);
      expect(plan.toDelete, isEmpty);
      expect((await sync()).synced, isEmpty);
      expect(await db.listMappingsForProfile(profile.id), isEmpty);
      expect(calendar.deleted, isEmpty);
    },
  );

  test('removing only a profile retains the calendar events', () async {
    calendar.events['target'] = target('target');
    await map('match', 'target');
    await profiles.deleteProfile(profile.id);
    expect(calendar.events.containsKey('target'), isTrue);
    expect(await db.listMappingsForProfile(profile.id), isEmpty);
  });

  test(
    'an uncertain create response does not allow a second calendar write',
    () async {
      calendar.events['match'] = event('match');
      calendar.failAfterCreate = true;
      expect((await sync()).errors, isNotEmpty);
      // Hide the committed calendar row as if the next local read were stale.
      calendar.events.remove('created-1');
      expect((await sync()).errors, isNotEmpty);
      expect(calendar.creates, 1);
      expect(await db.hasPendingCreations(profile.id), isTrue);
    },
  );

  test(
    'a DB failure rolls back the mapping but preserves the reservation',
    () async {
      calendar.events['match'] = event('match');
      final raw = await db.database;
      await raw.execute("""
      CREATE TRIGGER fail_created_events BEFORE INSERT ON sync_created_events
      BEGIN SELECT RAISE(ABORT, 'test failure'); END
    """);
      expect((await sync()).errors, isNotEmpty);
      expect(await db.listMappingsForProfile(profile.id), isEmpty);
      expect(await db.hasPendingCreations(profile.id), isTrue);
      await expectLater(profiles.deleteProfile(profile.id), throwsStateError);
      expect(calendar.creates, 1);
    },
  );

  test('concurrent runs share the durable create reservation', () async {
    calendar.events['match'] = event('match');
    await Future.wait([sync(), sync()]);
    expect(calendar.creates, 1);
    expect(await db.listMappingsForProfile(profile.id), hasLength(1));
  });

  test(
    'standalone and multi-day all-day dates keep their calendar-day semantics',
    () async {
      final day = DateTime(start.year, start.month, start.day);
      final next = DateTime(day.year, day.month, day.day + 1);
      final later = DateTime(day.year, day.month, day.day + 3);
      calendar.events['single'] = event(
        'single',
        from: day,
        until: day,
        allDay: true,
      );
      calendar.events['multi'] = event(
        'multi',
        from: day,
        until: later,
        allDay: true,
      );
      expect((await sync()).synced, ['single', 'multi']);
      expect(calendar.events['created-1']!.endDate, next);
      expect(calendar.events['created-2']!.endDate, later);
      expect((await sync()).updated, isEmpty);
    },
  );

  test(
    'a listed exception receives a stable original occurrence mapping',
    () async {
      calendar.events['master-slot'] = event(
        'series',
        instance: 'series@one',
        recurring: true,
      );
      calendar.events['exception'] = event(
        'exception',
        title: 'Moved training',
      );
      calendar.exceptionKeys['exception'] = ('series', 'series@one');
      expect((await sync()).synced, ['series']);
      final mapping = (await db.listMappingsForProfile(profile.id)).single;
      expect(mapping['source_instance_id'], 'series@one');
      expect(calendar.events['created-1']!.title, 'Moved training');
      expect((await sync()).skipped, ['exception']);
      expect(calendar.creates, 1);
    },
  );

  test(
    'past instances are retained when the provider reports a removed series',
    () async {
      final old = DateTime.now().subtract(const Duration(days: 1));
      calendar.events['past'] = event(
        'past',
        calendar: 'family',
        from: old,
        until: old,
        description: buildDescription('Training', null, false),
      );
      calendar.events['future'] = target('future');
      await map('series', 'past', instance: 'series@past');
      await map('series', 'future', instance: 'series@future');
      calendar.changes[('series', 'series@past')] = (
        removed: true,
        movedId: null,
      );
      calendar.changes[('series', 'series@future')] = (
        removed: true,
        movedId: null,
      );
      expect((await preview()).toDelete.map((row) => row.event.eventId), [
        'future',
      ]);
      expect(calendar.events.containsKey('past'), isTrue);
    },
  );

  test(
    'database failure after deletion preserves the original association',
    () async {
      await removeSource();
      final plan = await preview();
      final raw = await db.database;
      await raw.execute("""
      CREATE TRIGGER fail_mapping_removal BEFORE DELETE ON sync_mappings
      BEGIN SELECT RAISE(ABORT, 'test failure'); END
    """);
      expect(await engine.deleteConfirmedTargets(plan.toDelete), isFalse);
      expect(await db.isEventSynced(profile.id, 'source', 'match'), isTrue);
      expect(await db.isEventCreatedBySync('family', 'target'), isTrue);
      expect(await engine.deleteConfirmedTargets(plan.toDelete), isFalse);
      expect(calendar.deleted, ['target']);
    },
  );

  test(
    'database upgrade from v9 preserves profiles and ownership records',
    () async {
      await map('match', 'target');
      final old = await db.database;
      await old.execute('DROP TABLE sync_creation_reservations');
      await old.execute('PRAGMA user_version = 9');
      await old.close();
      DatabaseProvider.setTestPath('${temp.path}/calendar.db');
      db = MappingDatabase();
      profiles = ProfileService();
      final migrated = await db.database;
      expect(
        (await migrated.rawQuery('PRAGMA user_version')).single.values.single,
        10,
      );
      expect((await profiles.getProfile(profile.id))!.name, 'First team');
      expect(await db.isEventSynced(profile.id, 'source', 'match'), isTrue);
      expect(await db.isEventCreatedBySync('family', 'target'), isTrue);
      expect(await db.hasPendingCreations(profile.id), isFalse);
    },
  );

  test(
    'neither a generated event nor a marked source is copied back',
    () async {
      calendar.events['tracked'] = event('tracked');
      calendar.events['marked'] = event('marked', description: marker);
      await db.insertCreatedEvent('source', 'tracked');
      expect((await sync()).skipped, ['tracked', 'marked']);
      expect(calendar.creates, 0);
    },
  );

  group('buildDescription', () {
    const marker = '🔃 Automatically created by CalSync';

    test('copyDescription=false returns standard format', () {
      final result = buildDescription('Doctor Appointment', 'Q3 notes', false);
      expect(result, 'Doctor Appointment\n---\n$marker');
    });

    test('copyDescription=true with non-empty description prepends it', () {
      final result = buildDescription('Doctor Appointment', 'Q3 notes', true);
      expect(result, 'Q3 notes\n\nDoctor Appointment\n---\n$marker');
    });

    test(
      'copyDescription=true with null description returns standard format',
      () {
        final result = buildDescription('Doctor Appointment', null, true);
        expect(result, 'Doctor Appointment\n---\n$marker');
      },
    );

    test(
      'copyDescription=true with empty description returns standard format',
      () {
        final result = buildDescription('Doctor Appointment', '', true);
        expect(result, 'Doctor Appointment\n---\n$marker');
      },
    );

    test(
      'copyDescription=false with null description returns standard format',
      () {
        final result = buildDescription('Doctor Appointment', null, false);
        expect(result, 'Doctor Appointment\n---\n$marker');
      },
    );

    test('omitSourceTitle=true replaces title with SHA256 fingerprint', () {
      final result = buildDescription(
        'Doctor Appointment',
        'Q3 notes',
        false,
        omitSourceTitle: true,
      );
      expect(
        result,
        'de691f9d29a02d009e10def2bd0c4b8e7fe3eff4e0ef002eadbc329e27882333\n---\n$marker',
      );
    });

    test(
      'omitSourceTitle=true with copyDescription prepends source description',
      () {
        final result = buildDescription(
          'Doctor Appointment',
          'Q3 notes',
          true,
          omitSourceTitle: true,
        );
        expect(
          result,
          'Q3 notes\n\nde691f9d29a02d009e10def2bd0c4b8e7fe3eff4e0ef002eadbc329e27882333\n---\n$marker',
        );
      },
    );

    test(
      'omitSourceTitle=true with copyDescription and null source description',
      () {
        final result = buildDescription(
          'Doctor Appointment',
          null,
          true,
          omitSourceTitle: true,
        );
        expect(
          result,
          'de691f9d29a02d009e10def2bd0c4b8e7fe3eff4e0ef002eadbc329e27882333\n---\n$marker',
        );
      },
    );

    test(
      'omitSourceTitle=true with copyDescription and empty source description',
      () {
        final result = buildDescription(
          'Doctor Appointment',
          '',
          true,
          omitSourceTitle: true,
        );
        expect(
          result,
          'de691f9d29a02d009e10def2bd0c4b8e7fe3eff4e0ef002eadbc329e27882333\n---\n$marker',
        );
      },
    );

    test(
      'omitSourceTitle=true with empty title uses well-known SHA256 of empty string',
      () {
        final result = buildDescription('', null, false, omitSourceTitle: true);
        expect(
          result,
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n---\n$marker',
        );
      },
    );

    test('omitSourceTitle=true with known title matches hardcoded SHA256', () {
      // Locks the algorithm: any change to the hashing approach will fail this test.
      // SHA256 of "Doctor Appointment" computed via: echo -n "Doctor Appointment" | sha256sum
      final result = buildDescription(
        'Doctor Appointment',
        null,
        false,
        omitSourceTitle: true,
      );
      expect(
        result,
        'de691f9d29a02d009e10def2bd0c4b8e7fe3eff4e0ef002eadbc329e27882333\n---\n$marker',
      );
    });
  });
}
