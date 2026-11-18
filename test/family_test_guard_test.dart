import 'package:calendar_sync/background/sync_scheduler.dart';
import 'package:calendar_sync/calendar/calendar_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('calsync/calendar');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late CalendarService service;

  setUp(() async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => switch (call.method) {
        'isFamilyTestBuild' => true,
        'familyTestCalendars' => {
          'sourceA': '101',
          'sourceB': '102',
          'target': '103',
        },
        'familyTestAllowsEventRead' => false,
        _ => throw StateError('Unexpected call: ${call.method}'),
      },
    );
    await CalendarService.initializeBuildMode();
    service = CalendarService();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    CalendarService.isFamilyTestBuild = false;
  });

  test(
    'test calendar picker shows only the isolated account calendars',
    () async {
      final calendars = await service.listCalendars();
      expect(calendars.map((c) => c.id), ['101', '102', '103']);
    },
  );

  test(
    'test sync rejects external calendars and reversed calendar roles',
    () async {
      await service.verifyCalendars('101', {'103'});
      await expectLater(
        service.verifyCalendars('production-source', {'103'}),
        throwsStateError,
      );
      await expectLater(
        service.verifyCalendars('103', {'101'}),
        throwsStateError,
      );
      await expectLater(
        service.listEvents('production-calendar'),
        throwsStateError,
      );
      expect(await service.getEvent('production-event'), isNull);
    },
  );

  test(
    'test event creation cannot use a production or test source calendar',
    () async {
      final start = DateTime(2030, 1, 1, 10);
      for (final id in ['production', '101']) {
        await expectLater(
          service.createEvent(
            id,
            'Synthetic',
            start,
            start.add(const Duration(hours: 1)),
          ),
          throwsStateError,
        );
      }
    },
  );

  test('the test build does not register periodic work', () async {
    await SyncScheduler.updatePeriodicTask();
  });
}
