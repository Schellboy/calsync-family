import 'package:flutter/material.dart';

import '../sync/sync_engine.dart';

Future<bool> confirmCalendarDeletions(
  BuildContext context,
  List<MappedCalendarEvent> targets, {
  bool removeProfile = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          removeProfile
              ? 'Confirm profile and calendar deletion'
              : 'Confirm calendar deletions',
        ),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              Text('Delete these ${targets.length} mapped target events?'),
              for (final target in targets)
                ListTile(
                  title: Text(target.event.title),
                  subtitle: Text(
                    '${target.event.startDate.toLocal()} · calendar ${target.event.calendarId}',
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              removeProfile
                  ? 'Delete profile and events'
                  : 'Delete listed events',
            ),
          ),
        ],
      ),
    ) ??
    false;
