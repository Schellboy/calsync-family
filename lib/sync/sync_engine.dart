import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:device_calendar_plus/device_calendar_plus.dart';
import '../calendar/calendar_service.dart';
import 'mapping_database.dart';

const _syncMarker = '\u{1F503} Automatically created by CalSync';

String buildDescription(
  String originalTitle,
  String? sourceDescription,
  bool copyDescription, {
  bool omitSourceTitle = false,
}) {
  final titleLine = omitSourceTitle
      ? sha256.convert(utf8.encode(originalTitle)).toString()
      : originalTitle;
  String description = '$titleLine\n---\n$_syncMarker';
  if (copyDescription &&
      sourceDescription != null &&
      sourceDescription.isNotEmpty) {
    description = '$sourceDescription\n\n$description';
  }
  return description;
}

class SyncPlan {
  final List<ToCreateEntry> toCreate;
  final List<ToUpdateEntry> toUpdate;
  final List<Event> toSkip;
  final List<MappedCalendarEvent> toDelete;
  final List<Event> unmappedCandidates;
  final List<String> errors;

  const SyncPlan({
    this.toCreate = const [],
    this.toUpdate = const [],
    this.toSkip = const [],
    this.toDelete = const [],
    this.unmappedCandidates = const [],
    this.errors = const [],
  });
}

class ToCreateEntry {
  final Event sourceEvent;
  final (String, String?) sourceKey;
  final String projectedTitle;
  final String projectedDescription;
  final String? projectedLocation;

  ToCreateEntry(
    this.sourceEvent, {
    required this.sourceKey,
    required String syncEventName,
    required bool copyDescription,
    required bool copyLocation,
    required bool omitSourceTitle,
  }) : projectedTitle = syncEventName.isEmpty
           ? sourceEvent.title
           : syncEventName,
       projectedDescription = buildDescription(
         sourceEvent.title,
         sourceEvent.description,
         copyDescription,
         omitSourceTitle: omitSourceTitle,
       ),
       projectedLocation = copyLocation ? sourceEvent.location : null;

  DateTime get projectedStart => sourceEvent.startDate;
  DateTime get projectedEnd {
    if (projectedAllDay && _sameDate(projectedStart, sourceEvent.endDate)) {
      final start = projectedStart;
      return DateTime(start.year, start.month, start.day + 1);
    }
    return sourceEvent.endDate;
  }

  bool get projectedAllDay => sourceEvent.isAllDay;

  bool matches(Event target) =>
      projectedTitle == target.title &&
      projectedDescription == target.description &&
      (projectedLocation ?? '') == (target.location ?? '') &&
      projectedAllDay == target.isAllDay &&
      _sameDate(projectedStart, target.startDate) &&
      _sameDate(projectedEnd, target.endDate);

  bool _sameDate(DateTime a, DateTime b) => projectedAllDay
      ? a.year == b.year && a.month == b.month && a.day == b.day
      : a.isAtSameMomentAs(b);
}

class MappedCalendarEvent {
  final Map<String, Object?> mapping;
  final Event event;

  MappedCalendarEvent(Map<String, Object?> mapping, this.event)
    : mapping = Map.unmodifiable(mapping);
}

class ToUpdateEntry {
  final ToCreateEntry projected;
  final MappedCalendarEvent target;

  const ToUpdateEntry(this.projected, this.target);

  Event get sourceEvent => projected.sourceEvent;
}

class SyncEngine {
  final CalendarService _calendarService;
  final MappingDatabase _mappingDb;

  SyncEngine(this._calendarService, this._mappingDb);

  Future<SyncPlan> runDryRun({
    required String profileId,
    required String sourceCalendarId,
    required String targetCalendarId,
    required String syncEventName,
    int syncWindowDays = 30,
    bool copyDescription = false,
    bool copyLocation = false,
    bool omitSourceTitle = false,
  }) async {
    try {
      if (sourceCalendarId == targetCalendarId) {
        throw StateError('Source and target must be different calendars.');
      }
      await _calendarService.verifyCalendars(sourceCalendarId, {
        targetCalendarId,
      });
      final now = DateTime.now();
      final end = now.add(Duration(days: syncWindowDays));
      final listed = await _calendarService.listEvents(
        sourceCalendarId,
        end: end,
      );
      final mappings = await _mappingDb.listMappingsForCalendar(
        profileId,
        sourceCalendarId,
      );
      final exceptionKeys = await _calendarService.sourceExceptionKeys(
        sourceCalendarId,
        {for (final event in listed) event.eventId},
      );
      final rawSources = <(String, String?), Event>{};
      final sources = <(String, String?), Event>{};
      final cancelledExceptions = <(String, String?)>{};
      for (final event in listed) {
        if (!_validSource(event, sourceCalendarId)) {
          throw StateError('The source calendar returned incomplete data.');
        }
        final exactKey = _eventKey(event);
        final exceptionKey = exceptionKeys[event.eventId];
        final key = exceptionKey ?? exactKey;
        if (event.status == EventStatus.canceled) {
          if (exceptionKey != null) cancelledExceptions.add(key);
          continue;
        }
        if (rawSources.containsKey(exactKey)) {
          throw StateError(
            'The source calendar returned a duplicate event instance.',
          );
        }
        rawSources[exactKey] = event;
        final existing = sources[key];
        if (existing != null && exceptionKeys[existing.eventId] != null) {
          if (exceptionKey != null) {
            throw StateError('Ambiguous series exception.');
          }
          continue;
        }
        sources[key] = event;
      }
      for (final key in cancelledExceptions) {
        sources.remove(key);
      }
      final mapped = <(String, String?)>{};
      final ambiguousSeries = <String>{};
      final toDelete = <MappedCalendarEvent>[];
      final toUpdate = <ToUpdateEntry>[];
      final toSkip = <Event>[];
      final errors = <String>[];

      ToCreateEntry project(Event event, (String, String?) key) =>
          ToCreateEntry(
            event,
            sourceKey: key,
            syncEventName: syncEventName,
            copyDescription: copyDescription,
            copyLocation: copyLocation,
            omitSourceTitle: omitSourceTitle,
          );

      for (final row in mappings) {
        final eventId = row['source_event_id'] as String;
        final instanceId = row['source_instance_id'] as String?;
        final key = (eventId, instanceId);
        final canonicalKey = exceptionKeys[eventId] ?? key;
        if (!mapped.add(canonicalKey)) {
          throw StateError('Duplicate source mappings need review.');
        }
        final target = await _readOwnedTarget(row);
        if (target == null || target.calendarId != targetCalendarId) {
          errors.add(
            'A mapped target is missing, ambiguous, or on a different calendar.',
          );
        }
        if (instanceId == null &&
            sources.keys.any((key) => key.$1 == eventId && key.$2 != null)) {
          ambiguousSeries.add(eventId);
          errors.add('A legacy recurring target needs manual review.');
          continue;
        }
        var source = sources[canonicalKey];
        if (source == null && instanceId != null) {
          final change = await _calendarService.sourceChange(
            sourceCalendarId,
            eventId,
            instanceId,
          );
          if (change.movedId != null) {
            // Suppress creation even if the moved exception is visible only in
            // the range query or its target can no longer be verified.
            mapped.add((change.movedId!, null));
            source = await _calendarService.getEvent(change.movedId!);
            if (source == null ||
                !_validSource(source, sourceCalendarId) ||
                source.status == EventStatus.canceled ||
                source.eventId != change.movedId) {
              throw StateError('A moved occurrence could not be verified.');
            }
            mapped.add(_eventKey(source));
          } else if (change.removed &&
              target != null &&
              target.endDate.isAfter(now)) {
            toDelete.add(MappedCalendarEvent(row, target));
            ambiguousSeries.add(eventId);
          } else if (target == null || target.endDate.isAfter(now)) {
            // A new slot belonging to this series may be a move. Do not create
            // it until the provider supplies an unambiguous link.
            ambiguousSeries.add(eventId);
          }
        } else if (source == null &&
            target != null &&
            target.endDate.isAfter(now.subtract(const Duration(days: 7)))) {
          final change = await _calendarService.sourceChange(
            sourceCalendarId,
            eventId,
            null,
          );
          if (change.removed) {
            toDelete.add(MappedCalendarEvent(row, target));
          } else {
            final current = await _calendarService.getEvent(eventId);
            if (current != null &&
                _validSource(current, sourceCalendarId) &&
                current.status != EventStatus.canceled &&
                !current.isRecurring) {
              source = current;
            }
          }
        }
        if (source == null) continue;
        if (target == null || target.calendarId != targetCalendarId) continue;
        final projected = project(source, key);
        if (projected.matches(target)) {
          toSkip.add(source);
        } else {
          toUpdate.add(
            ToUpdateEntry(projected, MappedCalendarEvent(row, target)),
          );
        }
      }

      final toCreate = <ToCreateEntry>[];
      final unmappedCandidates = <Event>[];
      List<Event>? unknownTargets;
      for (final entry in sources.entries) {
        final source = entry.value;
        if (mapped.contains(entry.key)) continue;
        if (ambiguousSeries.contains(entry.key.$1) ||
            (source.description?.contains(_syncMarker) ?? false) ||
            await _mappingDb.isEventCreatedBySync(
              sourceCalendarId,
              source.eventId,
            )) {
          toSkip.add(source);
          continue;
        }
        unknownTargets ??= await _readUnmappedTargets(targetCalendarId, end);
        final projected = project(source, entry.key);
        final identity = buildDescription(
          source.title,
          null,
          false,
          omitSourceTitle: omitSourceTitle,
        );
        final candidates = unknownTargets.where(
          (event) =>
              (event.description == identity ||
                  (event.description?.endsWith('\n\n$identity') ?? false)) ||
              (event.title == projected.projectedTitle &&
                  event.isAllDay == projected.projectedAllDay &&
                  projected._sameDate(
                    event.startDate,
                    projected.projectedStart,
                  ) &&
                  projected._sameDate(event.endDate, projected.projectedEnd)),
        );
        if (candidates.isNotEmpty) {
          for (final candidate in candidates) {
            if (!unmappedCandidates.any(
              (event) => event.eventId == candidate.eventId,
            )) {
              unmappedCandidates.add(candidate);
            }
          }
        } else {
          toCreate.add(projected);
        }
      }
      return SyncPlan(
        toCreate: toCreate,
        toUpdate: toUpdate,
        toSkip: toSkip,
        toDelete: toDelete,
        unmappedCandidates: unmappedCandidates,
        errors: errors,
      );
    } catch (_) {
      return const SyncPlan(
        errors: [
          'Calendar or database verification failed. No changes were made.',
        ],
      );
    }
  }

  static (String, String?) _eventKey(Event event) => (
    event.eventId,
    event.eventId == event.instanceId ? null : event.instanceId,
  );

  static bool _validSource(Event event, String calendarId) =>
      event.calendarId == calendarId &&
      event.eventId.isNotEmpty &&
      event.instanceId.isNotEmpty &&
      !event.endDate.isBefore(event.startDate);

  Future<List<Event>> _readUnmappedTargets(
    String calendarId,
    DateTime end,
  ) async {
    final events = await _calendarService.listEvents(calendarId, end: end);
    final candidates = <Event>[];
    for (final event in events) {
      if (!_validSource(event, calendarId)) {
        throw StateError('The target calendar returned incomplete data.');
      }
      if (event.status != EventStatus.canceled &&
          (event.description?.endsWith(_syncMarker) ?? false) &&
          !await _mappingDb.isEventCreatedBySync(calendarId, event.eventId)) {
        candidates.add(event);
      }
    }
    return candidates;
  }

  Future<Event?> _readOwnedTarget(Map<String, Object?> row) async {
    final id = row['target_event_id'] as String;
    final target = await _calendarService.getEvent(id);
    if (target == null ||
        target.eventId != id ||
        target.calendarId != row['target_calendar_id'] ||
        target.instanceId != id ||
        target.isRecurring ||
        target.status == EventStatus.canceled ||
        !(target.description?.endsWith(_syncMarker) ?? false) ||
        !await _mappingDb.ownsTarget(row)) {
      return null;
    }
    return target;
  }

  Future<List<MappedCalendarEvent>> previewProfileDeletion(
    String profileId,
  ) async {
    if (!await _calendarService.canDeleteEvents()) {
      throw StateError(
        'Calendar deletion requires permissions and an active connection.',
      );
    }
    if (await _mappingDb.hasPendingCreations(profileId)) {
      throw StateError('This profile has an unresolved calendar write.');
    }
    final mappings = await _mappingDb.listMappingsForProfile(profileId);
    await _calendarService.verifyCalendars(null, {
      for (final row in mappings) row['target_calendar_id'] as String,
    });
    final targets = <MappedCalendarEvent>[];
    for (final row in mappings) {
      final event = await _readOwnedTarget(row);
      if (event == null) {
        throw StateError(
          'Some targets could not be verified. Calendar deletion is unavailable.',
        );
      }
      targets.add(MappedCalendarEvent(row, event));
    }
    return targets;
  }

  Future<bool> deleteConfirmedTargets(
    List<MappedCalendarEvent> targets, {
    bool verifySourceRemoval = false,
  }) async {
    try {
      if (!await _calendarService.canDeleteEvents()) return false;
      await _calendarService.verifyCalendars(null, {
        for (final target in targets) target.event.calendarId,
      });
      // Revalidate the entire selection before performing the first delete.
      for (final target in targets) {
        final row = target.mapping;
        final current = await _readOwnedTarget(row);
        if (current == null || !_sameSnapshot(current, target.event)) {
          return false;
        }
        if (verifySourceRemoval) {
          final source = row['source_calendar_id'] as String;
          await _calendarService.verifyCalendars(source, {current.calendarId});
          final change = await _calendarService.sourceChange(
            source,
            row['source_event_id'] as String,
            row['source_instance_id'] as String?,
          );
          if (!change.removed) return false;
        }
      }
      for (final target in targets) {
        final deleted = await _mappingDb.changeOwnedTarget(
          target.mapping,
          () async {
            if (verifySourceRemoval) {
              final row = target.mapping;
              final change = await _calendarService.sourceChange(
                row['source_calendar_id'] as String,
                row['source_event_id'] as String,
                row['source_instance_id'] as String?,
              );
              if (!change.removed) return false;
            }
            return _calendarService.deleteOwnedEvent(target.event);
          },
          removeMapping: true,
        );
        if (!deleted) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _sameSnapshot(Event a, Event b) =>
      a.title == b.title &&
      a.description == b.description &&
      a.location == b.location &&
      a.isAllDay == b.isAllDay &&
      a.startDate.isAtSameMomentAs(b.startDate) &&
      a.endDate.isAtSameMomentAs(b.endDate);

  Future<SyncResult> runSync({
    required String profileId,
    required String sourceCalendarId,
    required String targetCalendarId,
    required String syncEventName,
    int syncWindowDays = 30,
    bool copyDescription = false,
    bool copyLocation = false,
    bool omitSourceTitle = false,
  }) async {
    final plan = await runDryRun(
      profileId: profileId,
      sourceCalendarId: sourceCalendarId,
      targetCalendarId: targetCalendarId,
      syncEventName: syncEventName,
      syncWindowDays: syncWindowDays,
      copyDescription: copyDescription,
      copyLocation: copyLocation,
      omitSourceTitle: omitSourceTitle,
    );
    final synced = <String>[];
    final updated = <String>[];
    final errors = [...plan.errors];
    if (errors.isEmpty) {
      for (final entry in plan.toUpdate) {
        final projected = entry.projected;
        try {
          final changed = await _mappingDb.changeOwnedTarget(
            entry.target.mapping,
            () => _calendarService.updateOwnedEvent(
              entry.target.event,
              title: projected.projectedTitle,
              start: projected.projectedStart,
              end: projected.projectedEnd,
              description: projected.projectedDescription,
              allDay: projected.projectedAllDay,
              location: projected.projectedLocation,
            ),
            requireEnabledProfile: true,
          );
          if (!changed) throw StateError('Target changed during sync.');
          updated.add(projected.sourceEvent.eventId);
        } catch (_) {
          errors.add('Could not update a mapped event. The mapping was kept.');
        }
      }
      for (final projected in plan.toCreate) {
        final (eventId, instanceId) = projected.sourceKey;
        try {
          if (!await _mappingDb.reserveCreation(
            profileId,
            sourceCalendarId,
            eventId,
            instanceId,
            targetCalendarId,
          )) {
            errors.add(
              'An event creation is already mapped, pending, or no longer enabled.',
            );
            continue;
          }
          final target = await _calendarService.createEvent(
            targetCalendarId,
            projected.projectedTitle,
            projected.projectedStart,
            projected.projectedEnd,
            description: projected.projectedDescription,
            isAllDay: projected.projectedAllDay,
            location: projected.projectedLocation,
          );
          if (target == null) throw StateError('Calendar write not confirmed.');
          await _mappingDb.finishCreation(
            profileId: profileId,
            sourceCalendarId: sourceCalendarId,
            sourceEventId: eventId,
            sourceInstanceId: instanceId,
            targetCalendarId: targetCalendarId,
            targetEventId: target,
          );
          synced.add(eventId);
        } catch (_) {
          errors.add(
            'Could not record a new event. Check the target calendar before retrying.',
          );
        }
      }
    }
    return SyncResult(
      synced: UnmodifiableListView(synced),
      skipped: UnmodifiableListView(
        plan.toSkip.map((event) => event.eventId).toList(),
      ),
      deleted: UnmodifiableListView(const <String>[]),
      updated: UnmodifiableListView(updated),
      errors: UnmodifiableListView(errors),
    );
  }
}

class SyncResult {
  final UnmodifiableListView<String> synced;
  final UnmodifiableListView<String> skipped;
  final UnmodifiableListView<String> deleted;
  final UnmodifiableListView<String> updated;
  final UnmodifiableListView<String> errors;

  const SyncResult({
    required this.synced,
    required this.skipped,
    required this.deleted,
    required this.updated,
    required this.errors,
  });
}
