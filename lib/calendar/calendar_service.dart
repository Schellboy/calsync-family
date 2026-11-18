import 'package:flutter/services.dart';
import 'package:device_calendar_plus/device_calendar_plus.dart';

class CalendarService {
  final DeviceCalendar _plugin = DeviceCalendar.instance;
  static const _channel = MethodChannel('calsync/calendar');

  static bool isFamilyTestBuild = false;

  static Future<void> initializeBuildMode() async {
    isFamilyTestBuild =
        await _channel.invokeMethod<bool>('isFamilyTestBuild') == true;
  }

  Future<Map<String, String>> familyTestCalendars() async =>
      await _channel.invokeMapMethod<String, String>('familyTestCalendars') ??
      {};

  Future<void> prepareFamilyTestCalendars() async {
    if (await _channel.invokeMethod<bool>('prepareFamilyTestCalendars') !=
        true) {
      throw StateError('Could not create isolated test calendars.');
    }
  }

  Future<List<Calendar>> listCalendars() async {
    try {
      if (isFamilyTestBuild) {
        final ids = await familyTestCalendars();
        const labels = {
          'sourceA': 'CalSync Family Test - Source A',
          'sourceB': 'CalSync Family Test - Source B',
          'target': 'CalSync Family Test - Target',
        };
        return [
          for (final entry in ids.entries)
            if (labels.containsKey(entry.key))
              Calendar(
                id: entry.value,
                name: labels[entry.key]!,
                readOnly: false,
              ),
        ];
      }
      return await _plugin.listCalendars();
    } on DeviceCalendarException {
      return [];
    } on PlatformException {
      return [];
    }
  }

  Future<List<Event>> listEvents(String calendarId, {DateTime? end}) async {
    if (isFamilyTestBuild &&
        !(await familyTestCalendars()).containsValue(calendarId)) {
      throw StateError('Only isolated test calendars can be queried.');
    }
    final now = DateTime.now();
    final endDate = end ?? now.add(const Duration(days: 30));
    return _plugin.listEvents(now, endDate, calendarIds: [calendarId]);
  }

  Future<void> verifyCalendars(String? sourceId, Set<String> targetIds) async {
    if (isFamilyTestBuild) {
      final ids = await familyTestCalendars();
      if ((sourceId != null &&
              sourceId != ids['sourceA'] &&
              sourceId != ids['sourceB']) ||
          targetIds.any((id) => id != ids['target'])) {
        throw StateError('Select an isolated test source and target calendar.');
      }
      return;
    }
    final calendars = await _plugin.listCalendars();
    if ((sourceId != null && !calendars.any((c) => c.id == sourceId)) ||
        !targetIds.every(
          (id) => calendars.any((c) => c.id == id && !c.readOnly),
        )) {
      throw StateError('A required calendar is unavailable or read-only.');
    }
  }

  Future<bool> canDeleteEvents() async =>
      await _channel.invokeMethod<bool>('canDeleteEvents') == true;

  Future<Map<String, (String, String)>> sourceExceptionKeys(
    String calendarId,
    Set<String> eventIds,
  ) async {
    if (eventIds.isEmpty) return {};
    final result = await _channel.invokeMapMethod<String, List<Object?>>(
      'sourceExceptionKeys',
      {'calendarId': calendarId, 'eventIds': eventIds.toList()},
    );
    if (result == null) {
      throw StateError('The provider did not verify the source.');
    }
    return {
      for (final entry in result.entries)
        entry.key: (entry.value[0] as String, entry.value[1] as String),
    };
  }

  Future<({bool removed, String? movedId})> sourceChange(
    String calendarId,
    String eventId,
    String? instanceId,
  ) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'sourceChange',
      {'calendarId': calendarId, 'eventId': eventId, 'instanceId': instanceId},
    );
    if (result == null) {
      throw StateError('The provider did not verify the source.');
    }
    return (
      removed: result['removed'] == true,
      movedId: result['movedId'] as String?,
    );
  }

  Future<String?> createEvent(
    String calendarId,
    String title,
    DateTime start,
    DateTime end, {
    String? description,
    bool? isAllDay,
    String? location,
  }) async {
    if (isFamilyTestBuild &&
        (await familyTestCalendars())['target'] != calendarId) {
      throw StateError('Only the isolated test target can receive events.');
    }
    try {
      return await _plugin.createEvent(
        calendarId: calendarId,
        title: title,
        startDate: start,
        endDate: end,
        description: description,
        isAllDay: isAllDay ?? false,
        location: location,
      );
    } on DeviceCalendarException {
      return null;
    }
  }

  Future<Event?> getEvent(String eventId) async {
    if (isFamilyTestBuild &&
        await _channel.invokeMethod<bool>('familyTestAllowsEventRead', {
              'eventId': eventId,
            }) !=
            true) {
      return null;
    }
    return _plugin.getEvent(eventId);
  }

  Future<bool> updateOwnedEvent(
    Event expected, {
    required String title,
    required DateTime start,
    required DateTime end,
    required String description,
    required bool allDay,
    required String? location,
  }) async =>
      await _channel.invokeMethod<bool>('updateOwnedEvent', {
        ..._snapshot(expected),
        'title': title,
        'start': start.millisecondsSinceEpoch,
        'end': end.millisecondsSinceEpoch,
        'description': description,
        'allDay': allDay,
        'location': location,
      }) ==
      true;

  Future<bool> deleteOwnedEvent(Event expected) async =>
      await _channel.invokeMethod<bool>(
        'deleteOwnedEvent',
        _snapshot(expected),
      ) ==
      true;

  Map<String, Object?> _snapshot(Event event) => {
    'eventId': event.eventId,
    'calendarId': event.calendarId,
    'oldDescription': event.description,
    'oldTitle': event.title,
    'oldStart': event.startDate.millisecondsSinceEpoch,
    'oldEnd': event.endDate.millisecondsSinceEpoch,
    'oldAllDay': event.isAllDay,
    'oldLocation': event.location,
  };
}
