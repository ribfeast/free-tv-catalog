// Proves the checker still rejects what it claims to reject.
//
//   dart tools/validate_catalog_selftest.dart                 built-in sample
//   dart tools/validate_catalog_selftest.dart catalog.json    damage copies of
//                                                             a real catalogue
//
// WHY: a checker that quietly stops checking is worse than none, because its
// green tick goes on being believed. "The real file passes" proves nothing on
// its own - a checker that accepted everything would say the same. So this
// takes a good catalogue, makes one deliberately damaged COPY per rule in a
// temporary folder (the real file is never touched), runs the checker on each
// as a separate program exactly the way GitHub does, and insists that every
// copy is refused FOR THE EXPECTED REASON. It runs on every pull request,
// before the checker's verdict on the real file is trusted.
//
// When a rule is added to validate_catalog.dart, add its damaged copy here.

import 'dart:convert';
import 'dart:io';

import 'validate_catalog.dart' show publicDomainChannelIds;

typedef Json = Map<String, dynamic>;

/// A small catalogue with one of everything: a public-domain channel (no
/// credits), a Creative Commons one (credits), and a plain live stream.
const _sample = '''
{
  "version": 3,
  "updated": "2026-01-01",
  "channels": [
    { "id": "nasa", "name": "Space", "category": "Science", "kind": "scheduled",
      "schedule": { "epoch": "2026-01-01T00:00:00Z", "items": [
        { "title": "Launch", "seconds": 120, "url": "https://example.org/pd/1.mp4" },
        { "title": "Orbit", "seconds": 240, "url": "https://example.org/pd/2.mp4" } ] } },
    { "id": "sky", "name": "Night Sky", "category": "Science", "kind": "scheduled",
      "schedule": { "epoch": "2026-01-01T00:00:00Z", "items": [
        { "title": "One", "seconds": 100, "url": "https://example.org/cc/1.mp4", "credit": "A / CC BY 4.0" },
        { "title": "Two", "seconds": 200, "url": "https://example.org/cc/2.mp4", "credit": "B / CC BY 4.0" },
        { "title": "Three", "seconds": 300, "url": "https://example.org/cc/3.mp4", "credit": "C / CC BY 4.0" },
        { "title": "Four", "seconds": 400, "url": "https://example.org/cc/4.mp4", "credit": "D / CC BY 4.0" },
        { "title": "Five", "seconds": 500, "url": "https://example.org/cc/5.mp4", "credit": "E / CC BY 4.0" } ] } },
    { "id": "test", "name": "Test", "category": "Test",
      "streamUrl": "https://example.org/live/master.m3u8" }
  ]
}
''';

late final Directory _temp;
late final String _validator;
late final String _goodText;
var _caseNumber = 0;
var _bad = 0;

void main(List<String> args) {
  _validator = Platform.script.resolve('validate_catalog.dart').toFilePath();
  _temp = Directory.systemTemp.createTempSync('catalog_selftest_');
  try {
    _goodText = args.isEmpty ? _sample : _prepare(File(args[0]).readAsBytesSync());
    _run();
  } finally {
    _temp.deleteSync(recursive: true);
  }
  stdout.writeln();
  if (_bad > 0) {
    stdout.writeln('SELF-TEST FAILED: $_bad of $_caseNumber cases. The checker '
        'no longer does what it says, so its tick means nothing until fixed.');
    exit(1);
  }
  stdout.writeln('SELF-TEST PASSED: all $_caseNumber cases behaved.');
}

/// Makes a real catalogue fit to be the self-test's starting point.
///
/// Two things can go wrong with the file we are handed, and both used to end
/// in a Dart stack trace - which reads as "the checker is broken" when the
/// truth is "your file is". So first the checker itself is run on the file,
/// and a file it refuses stops the self-test with a plain message instead:
/// the damaged copies would be refused for the file's own faults, not the
/// damage, and prove nothing.
///
/// Second, the cases need a channel of each shape to damage: a live stream
/// (`streamUrl`) and a Creative Commons running order with at least five
/// items. The real catalogue is not obliged to contain either - the only live
/// stream today is a test placeholder due to be removed before the store -
/// and a look-up that found nothing threw. So any shape the file lacks is
/// borrowed from the built-in sample and added to the COPY the cases start
/// from (never the real file), and the report says so. Nothing is skipped.
///
/// It takes BYTES, not text, on purpose. Dart's text reader quietly drops a
/// BOM (the invisible marker the checker's very first rule exists to catch),
/// so reading the file as text and handing the checker a copy meant a BOM file
/// was declared fit, and the self-test then "passed" on a file every phone
/// would have read as empty. The checker must see the file exactly as it is.
String _prepare(List<int> bytes) {
  final verdict = Process.runSync(
    Platform.resolvedExecutable,
    [_validator, (File('${_temp.path}/given.json')..writeAsBytesSync(bytes)).path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (verdict.exitCode != 0) {
    stdout.writeln('SELF-TEST NOT RUN: the catalogue it was given is refused by '
        'the checker as it stands, so damaging copies of it would prove '
        'nothing. Fix the file first - run the checker on it to see why:');
    final lines = const LineSplitter().convert('${verdict.stdout}${verdict.stderr}');
    for (final line in lines.where((l) => l.startsWith('  - ')).take(4)) {
      stdout.writeln('  ${line.substring(4)}');
    }
    exit(1);
  }

  // Past the checker, so the bytes are known to be clean UTF-8 JSON.
  final text = utf8.decode(bytes);
  final cat = jsonDecode(text) as Json;
  final channels = (cat['channels'] as List).cast<Json>();
  final sample = (jsonDecode(_sample) as Json)['channels'] as List;
  final borrowed = <String>[];
  if (_find(cat, _isStream) == null) {
    channels.add((sample[2] as Json)..['id'] = 'selftest_stream');
    borrowed.add('live stream');
  }
  if (_find(cat, _isCc) == null) {
    channels.add((sample[1] as Json)..['id'] = 'selftest_cc');
    borrowed.add('Creative Commons running order');
  }
  if (borrowed.isEmpty) return text;
  stdout.writeln('The catalogue has no ${borrowed.join(' and no ')} to damage, '
      'so one from the built-in sample is added to the copy under test.\n');
  return const JsonEncoder.withIndent('  ').convert(cat);
}

// Handles on the parts of a catalogue the cases damage. After _prepare a real
// catalogue always has one of each, so the look-ups cannot come up empty.
bool _isCc(Json c) =>
    c['schedule'] != null &&
    !publicDomainChannelIds.contains(c['id']) &&
    _items(c).length >= 5;
bool _isStream(Json c) => c['streamUrl'] != null;
Json? _find(Json cat, bool Function(Json) test) {
  for (final c in (cat['channels'] as List).cast<Json>()) {
    if (test(c)) return c;
  }
  return null;
}
Json _cc(Json cat) => _find(cat, _isCc)!;
Json _stream(Json cat) => _find(cat, _isStream)!;
List<dynamic> _items(Json channel) =>
    (channel['schedule'] as Json)['items'] as List<dynamic>;
Json _item(Json cat, [int i = 1]) => _items(_cc(cat))[i] as Json;
void _bump(Json cat) => cat['version'] = (cat['version'] as int) + 1;

void _run() {
  final good = utf8.encode(_goodText);

  stdout.writeln('A good file, and changes that are fine:');
  _expect('the undamaged catalogue passes', good, pass: true);
  _expect('compared with itself: passes without raising "version"', good,
      base: good, pass: true, saying: 'byte-for-byte the same');
  _expect('a reworded title with "version" raised passes', _edit((c) {
    _bump(c);
    _item(c)['title'] = 'A better title';
  }), base: good, pass: true, saying: 'title(s) reworded');

  stdout.writeln('\nDamage to the file itself:');
  _expect('a BOM', [0xEF, 0xBB, 0xBF, ...good], saying: 'starts with a BOM');
  _expect('JSON cut off half way', good.sublist(0, good.length ~/ 2),
      saying: 'not valid JSON');
  _expect('bytes that are not UTF-8', [...good, 0xFF], saying: 'not valid UTF-8');
  _expect('a bare list instead of an object',
      utf8.encode(jsonEncode((jsonDecode(_goodText) as Json)['channels'])),
      saying: 'top level must be an object');
  _expect('no "version"', _edit((c) => c.remove('version')),
      saying: '"version" must be a whole number');
  _expect('"version" written as text', _edit((c) => c['version'] = '9'),
      saying: '"version" must be a whole number');

  stdout.writeln('\nDamage to a channel:');
  _expect('a channel with no id', _edit((c) => _cc(c).remove('id')),
      saying: 'has no "id"');
  _expect('the same id twice',
      _edit((c) => _stream(c)['id'] = _cc(c)['id']),
      saying: 'used by more than one channel');
  _expect('a channel with no name', _edit((c) => _cc(c)['name'] = '  '),
      saying: 'has no "name"');
  _expect('a channel with nothing to play',
      _edit((c) => _stream(c).remove('streamUrl')),
      saying: 'neither "streamUrl" nor "schedule"');
  _expect('a stream address that is not https', _edit((c) {
    final s = _stream(c);
    s['streamUrl'] = (s['streamUrl'] as String).replaceFirst('https:', 'http:');
  }), saying: 'must be an https:// address');
  _expect('a schedule without kind: scheduled',
      _edit((c) => _cc(c).remove('kind')),
      saying: '"kind" must be "scheduled"');

  stdout.writeln('\nDamage to a schedule:');
  _expect('an epoch that does not parse',
      _edit((c) => (_cc(c)['schedule'] as Json)['epoch'] = 'next Tuesday'),
      saying: 'does not parse');
  _expect('an epoch with no time zone',
      _edit((c) => (_cc(c)['schedule'] as Json)['epoch'] = '2026-01-01T00:00:00'),
      saying: 'has no time zone');
  _expect('a channel with one item',
      _edit((c) => _items(_cc(c)).removeRange(1, _items(_cc(c)).length)),
      saying: 'needs at least 2');
  _expect('an empty title', _edit((c) => _item(c)['title'] = ''),
      saying: 'empty "title"');
  _expect('an item address that is not https', _edit((c) {
    final i = _item(c);
    i['url'] = (i['url'] as String).replaceFirst('https:', 'http:');
  }), saying: 'must be an https:// address');
  _expect('seconds: 0', _edit((c) => _item(c)['seconds'] = 0),
      saying: 'would stall the channel');
  _expect('seconds: -5', _edit((c) => _item(c)['seconds'] = -5),
      saying: 'would stall the channel');
  _expect('seconds written as text (the app accepts this; we do not)',
      _edit((c) => _item(c)['seconds'] = '107'),
      saying: '"seconds" must be a whole number');
  _expect('seconds with a decimal point',
      _edit((c) => _item(c)['seconds'] = 107.5),
      saying: '"seconds" must be a whole number');
  _expect('the same address twice in one channel',
      _edit((c) => _item(c, 2)['url'] = _item(c, 1)['url']),
      saying: 'appears twice');
  _expect('a Creative Commons item with no credit',
      _edit((c) => _item(c).remove('credit')),
      saying: 'has no "credit"');
  _expect('a blank credit', _edit((c) => _item(c)['credit'] = ' '),
      saying: 'present but blank');
  _expect('a nonsense aspect', _edit((c) => _item(c)['aspect'] = 'wide'),
      saying: '"aspect" must be a number');

  stdout.writeln('\nCompared with the live file - refused:');
  _expect('a change with "version" left alone',
      _edit((c) => _item(c)['title'] = 'Changed'),
      base: good, saying: '"version" did not go up');
  _expect('"version" going down', _edit((c) {
    c['version'] = (c['version'] as int) - 1;
    _item(c)['title'] = 'Changed';
  }), base: good, saying: '"version" did not go up');
  final channelGone = _edit((c) {
    _bump(c);
    (c['channels'] as List).remove(_stream(c));
  });
  _expect('a channel removed without saying so', channelGone,
      base: good, saying: 'is REMOVED');
  final itemsGone = _edit((c) {
    _bump(c);
    final items = _items(_cc(c));
    items.removeRange(items.length - (items.length * 0.4).ceil(), items.length);
  });
  _expect('a channel losing 40% of its items without saying so', itemsGone,
      base: good, saying: 'falls from');

  stdout.writeln('\nCompared with the live file - allowed, but shouted about:');
  _expect('the same removals WITH --allow-drop', channelGone,
      base: good, flags: ['--allow-drop'], pass: true, saying: 'is REMOVED');
  _expect('the same item loss WITH --allow-drop', itemsGone,
      base: good, flags: ['--allow-drop'], pass: true, saying: 'REMOVED');
  _expect('an epoch change', _edit((c) {
    _bump(c);
    (_cc(c)['schedule'] as Json)['epoch'] = '2031-05-05T00:00:00Z';
  }), base: good, pass: true, saying: 'EPOCH CHANGED');
  _expect('two items swapped', _edit((c) {
    _bump(c);
    final items = _items(_cc(c));
    final first = items.removeAt(0);
    items.insert(1, first);
  }), base: good, pass: true, saying: 'items REORDERED');
  final extra = {
    'title': 'Extra',
    'seconds': 60,
    'url': 'https://example.org/extra.mp4',
    'credit': 'X / CC BY 4.0',
  };
  _expect('an item inserted in the middle', _edit((c) {
    _bump(c);
    _items(_cc(c)).insert(2, extra);
  }), base: good, pass: true, saying: '1 item(s) INSERTED');
  _expect('an item added at the end', _edit((c) {
    _bump(c);
    _items(_cc(c)).add(extra);
  }), base: good, pass: true, saying: '1 item(s) ADDED at the end');
  _expect('one item changing length', _edit((c) {
    _bump(c);
    _item(c)['seconds'] = (_item(c)['seconds'] as int) + 6;
  }), base: good, pass: true, saying: 'changed LENGTH');
  _expect('a changed credit', _edit((c) {
    _bump(c);
    _item(c)['credit'] = 'Somebody else';
  }), base: good, pass: true, saying: 'the credit changed');
  _expect('a misspelt key', _edit((c) => _item(c)['descripton'] = 'typo'),
      pass: true, saying: 'does not read "descripton"');
}

/// A copy of the good catalogue with one thing done to it.
List<int> _edit(void Function(Json catalogue) damage) {
  final copy = jsonDecode(_goodText) as Json;
  damage(copy);
  return utf8.encode(const JsonEncoder.withIndent('  ').convert(copy));
}

/// Runs the checker on [bytes]. Unless [pass] is set the file must be REFUSED
/// (exit code 1), and either way the output must contain [saying] - so a copy
/// refused for the wrong reason still counts as a broken rule.
void _expect(
  String name,
  List<int> bytes, {
  List<int>? base,
  List<String> flags = const [],
  bool pass = false,
  String? saying,
}) {
  _caseNumber++;
  final file = File('${_temp.path}/case_$_caseNumber.json')
    ..writeAsBytesSync(bytes);
  final args = [_validator, file.path];
  if (base != null) {
    final baseFile = File('${_temp.path}/base_$_caseNumber.json')
      ..writeAsBytesSync(base);
    args.add(baseFile.path);
  }
  final result = Process.runSync(
    Platform.resolvedExecutable,
    [...args, ...flags],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final output = '${result.stdout}${result.stderr}';

  final wantCode = pass ? 0 : 1;
  final problems = <String>[
    if (result.exitCode != wantCode)
      'exit code ${result.exitCode}, expected $wantCode',
    if (saying != null && !output.contains(saying))
      'the output never said "$saying"',
  ];
  final verb = pass ? 'allows ' : 'refuses';
  if (problems.isEmpty) {
    stdout.writeln('  ok   $verb  $name');
  } else {
    _bad++;
    stdout.writeln('  BAD  $verb  $name  <-- ${problems.join('; ')}');
    final lines = const LineSplitter().convert(output);
    for (final line in lines.where((l) => l.startsWith('  - ')).take(4)) {
      stdout.writeln('           checker said: ${line.substring(4)}');
    }
  }
}
