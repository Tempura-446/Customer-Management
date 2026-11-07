import 'package:cabinet_crm/core/checklist.dart';
import 'package:cabinet_crm/core/db.dart';
import 'package:cabinet_crm/core/logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDb db;
  late String pid;
  setUp(() {
    db = AppDb.memory(isHub: true);
    seedSettings(db);
    db.currentUserId = createUser(db, name: 'Owner', role: 'owner', pin: '1111');
    pid = createProject(db, customerId: saveCustomer(db, {'name': 'Jane'}), title: 'Kitchen');
  });

  String measure(String room, Map<String, String> values) => saveMeasurement(db,
      projectId: pid,
      room: room,
      source: 'onsite',
      lines: [for (final e in values.entries) MeasureLine(e.key, e.value, 'in')]);

  test('built-in checklists are used until edited', () {
    expect(measurementChecklists(db).keys, containsAll(['Kitchen', 'Bathroom', 'Closet', 'Laundry']));
  });

  test('room names match by word, longest first', () {
    saveMeasurementChecklists(db, {'Bathroom': ['A'], 'Master bathroom': ['B'], 'Kitchen': ['C']});
    expect(checklistForRoom(db, 'kitchen 2')!.$1, 'Kitchen');
    expect(checklistForRoom(db, 'Main Kitchen')!.$1, 'Kitchen');
    expect(checklistForRoom(db, 'Master bathroom upstairs')!.$1, 'Master bathroom');
    expect(checklistForRoom(db, 'Kitchenette'), isNull);
    expect(checklistForRoom(db, 'Garage'), isNull);
  });

  test('blank or missing checklist items are reported, punctuation and case ignored', () {
    saveMeasurementChecklists(db, {'Kitchen': ['Wall A length', 'Ceiling height', 'Window 1 (W x H)']});
    final mid = measure('Kitchen', {'wall a length': '120', 'Ceiling height': '', 'Window 1 (W x H) ': '36 x 48'});
    expect(missingMeasurements(db, mid), ['Ceiling height']);
    final warnings = projectWarnings(db, pid).map((w) => w.message).join('\n');
    expect(warnings, contains('1 checklist item(s) not measured: Ceiling height'));
  });

  test('rooms without a checklist report nothing; reset restores defaults', () {
    saveMeasurementChecklists(db, {'Pantry': ['Depth']});
    expect(missingMeasurements(db, measure('Garage', {'x': '1'})), isEmpty);
    expect(measurementChecklists(db).keys, ['Pantry']);
    resetMeasurementChecklists(db);
    expect(measurementChecklists(db).keys, contains('Kitchen'));
  });

  test('a damaged setting falls back to the defaults', () {
    setSetting(db, checklistSettingKey, '{not json');
    expect(measurementChecklists(db).keys, contains('Kitchen'));
  });
}
