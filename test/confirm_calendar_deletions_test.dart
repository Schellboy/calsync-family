import 'package:calendar_sync/sync/sync_engine.dart';
import 'package:calendar_sync/widgets/confirm_calendar_deletions.dart';
import 'package:device_calendar_plus/device_calendar_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('calendar cleanup lists its targets and requires confirmation', (
    tester,
  ) async {
    bool? result;
    final target = MappedCalendarEvent(
      {'id': 1},
      Event(
        eventId: 'family-1',
        instanceId: 'family-1',
        calendarId: 'family',
        title: 'Training',
        startDate: DateTime(2030, 6, 1, 16),
        endDate: DateTime(2030, 6, 1, 18),
        isAllDay: false,
        isRecurring: false,
        status: EventStatus.confirmed,
        availability: EventAvailability.busy,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await confirmCalendarDeletions(context, [
                  target,
                ], removeProfile: true);
              },
              child: const Text('Review'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(find.text('Training'), findsOneWidget);
    expect(result, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete profile and events'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
