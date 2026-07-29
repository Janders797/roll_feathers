import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:roll_feathers/dice_sdks/dice_sdks.dart';
import 'package:roll_feathers/domains/roll_domain.dart';
import 'package:roll_feathers/domains/roll_parser/parser_rules.dart';
import 'package:roll_feathers/domains/roll_parser/rule_evaluator.dart';
import 'package:roll_feathers/domains/webhook_domain.dart';
import 'package:roll_feathers/testing/dsl_test_harness.dart';

import '../../test_util.dart';

/// `report` became mandatory, so any rule a user saved before that change now
/// throws at parse time. Rule evaluation runs in phase 1 of
/// `_stopRollWithResult`, upstream of the roll being recorded — an unguarded
/// throw there would destroy the roll record, the exact inversion
/// `docs/design/rule_effect_separation.md` exists to prevent.
const String legacyRuleWithoutReport = '''
define legacyRule "Legacy" for roll *d*

  use selection \$ALL_DICE
    aggregate over selection sum
    on result [*:*] action blink green
''';

/// Parses fine structurally but has a malformed transform — fails for a reason
/// that has nothing to do with the report clause.
const String brokenForOtherReasons = '''
define brokenRule "Broken" for roll *d*

  make selection @X
    with top notanumber

  use selection @X
    aggregate over selection sum
    on result [*:*] action blink green

  report sum over @X
''';

/// Captures SEVERE records emitted while [body] runs.
Future<List<String>> _capture(Future<void> Function() body) async {
  final messages = <String>[];
  final sub = Logger.root.onRecord.where((r) => r.level >= Level.SEVERE).listen((r) => messages.add(r.message));
  Logger.root.level = Level.ALL;
  try {
    await body();
  } finally {
    await sub.cancel();
  }
  return messages;
}

Future<RollDomain> _rollWith(String script) async {
  final dieDomain = RecordingDieDomain();
  final appService = InMemoryAppService();
  final rp = RuleEvaluator(dieDomain, appService, WebhookDomain(appService: appService));
  await rp.init();
  await appService.setSavedScripts([RuleScript(name: 'theRule', script: script, enabled: true).toJsonString()]);
  await rp.init();
  final rollDomain = await RollDomain.create(dieDomain, appService, ruleParser: rp);
  final die = TestBleDie('die-A');
  dieDomain.emitDice({'die-A': die});
  await Future.delayed(Duration.zero);
  die.fireRollState(DiceRollState.rolling);
  await Future.delayed(Duration.zero);
  die.fireRollState(DiceRollState.rolled);
  await Future.delayed(const Duration(milliseconds: 100));
  return rollDomain;
}

void main() {
  setupLogger(Level.SEVERE);

  test('a missing report clause is diagnosed as such', () async {
    late RollDomain rd;
    final msgs = await _capture(() async {
      rd = await _rollWith(legacyRuleWithoutReport);
    });
    expect(rd.rollHistory, hasLength(1));
    expect(msgs.single, contains('has no `report` clause'));
  });

  test('an unrelated parse failure is not blamed on the report clause', () async {
    late RollDomain rd;
    final msgs = await _capture(() async {
      rd = await _rollWith(brokenForOtherReasons);
    });
    expect(rd.rollHistory, hasLength(1), reason: 'still recorded');
    // The parser's own text mentions `report` (block parsing halts at the bad
    // transform, so `report` is what it expected next) — which is precisely why
    // the diagnosis keys off the script, not the exception. Our guidance must
    // not appear.
    expect(msgs.single, isNot(contains('has no `report` clause')));
    expect(msgs.single, isNot(contains('Every rule must')), reason: 'the script has a report clause; do not blame it');
    expect(msgs.single, contains('could not be evaluated'));
  });

  test('a saved rule with no report clause is rejected by the parser', () async {
    final runner = await DslTestRunner.create();
    expect(() => runner.parser.evaluateRule(legacyRuleWithoutReport, const []), throwsA(anything));
  });

  test('an unparseable saved rule does not stop the roll being recorded', () async {
    final dieDomain = RecordingDieDomain();
    final appService = InMemoryAppService();
    final rp = RuleEvaluator(dieDomain, appService, WebhookDomain(appService: appService));
    await rp.init();

    // Inject the legacy script the way persistence would, bypassing addRuleScript
    // (which validates and would reject it).
    await appService.setSavedScripts([
      RuleScript(name: 'legacyRule', script: legacyRuleWithoutReport, enabled: true).toJsonString(),
    ]);
    await rp.init();

    final rollDomain = await RollDomain.create(dieDomain, appService, ruleParser: rp);
    final die = TestBleDie('die-A');
    dieDomain.emitDice({'die-A': die});
    await Future.delayed(Duration.zero);

    die.fireRollState(DiceRollState.rolling);
    await Future.delayed(Duration.zero);
    die.fireRollState(DiceRollState.rolled);
    await Future.delayed(const Duration(milliseconds: 100));

    expect(
      rollDomain.rollHistory,
      hasLength(1),
      reason: 'the bad rule is skipped and logged; the roll is still recorded',
    );
  });
}
