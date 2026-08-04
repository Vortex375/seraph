import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/sync/gallery_backup_scheduler_io.dart';

/// Ticket 24 rework (defect 3): [shouldRearmContentTrigger] is the pure
/// decision behind [galleryBackupCallbackDispatcher]'s "re-arm the content
/// trigger from TWO places" durable backstop - both the content-trigger
/// task's own firing (it was just consumed) and the periodic task's (a
/// backstop independent of whether any earlier content-trigger re-arm
/// attempt survived a killed or timed-out isolate). Extracted as a plain
/// function specifically so this decision is unit-testable without a live
/// WorkManager (ticket 24's own "scheduling registration itself is verified
/// by inspection of what is scheduled, not by waiting on the OS") - the
/// actual `Workmanager().registerOneOffTask` call this gates is platform
/// glue with nothing further to unit test once this predicate is covered.
void main() {
  group('shouldRearmContentTrigger', () {
    test('true for the content-trigger task itself - it was just consumed '
        'and must be re-registered to keep watching', () {
      expect(shouldRearmContentTrigger(galleryContentTriggerTaskName), isTrue);
    });

    test('true for the periodic task - the durable backstop that keeps '
        're-arming even if every content-trigger firing\'s own re-arm was '
        'lost to a killed or timed-out isolate', () {
      expect(shouldRearmContentTrigger(galleryPeriodicTaskName), isTrue);
    });

    test('false for the fast-path task - it is event-driven and one-shot; '
        're-arming it here would be meaningless since it carries no '
        'content-URI trigger to begin with', () {
      expect(shouldRearmContentTrigger(galleryFastPathTaskName), isFalse);
    });

    test('false for an unrecognised task name', () {
      expect(shouldRearmContentTrigger('something-else'), isFalse);
    });
  });
}
