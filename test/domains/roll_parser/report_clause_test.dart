import 'package:flutter_test/flutter_test.dart';

import 'package:roll_feathers/domains/roll_parser/parser_rules.dart';
import 'package:roll_feathers/domains/roll_parser/rule_parser.dart';
import 'package:roll_feathers/testing/dsl_test_harness.dart';

/// A `use` block's aggregate decides both whether an `on result` range matches
/// and what the rule reports. `report <agg> over <selection>` separates them.
void main() {
  const withReport = '''
define reportRule "Report Rule" for roll *d*

  make selection @HIGH
    with top 1

  use selection @HIGH
    aggregate over selection max
    on result [1:*] action blink green

  report sum over \$ALL_DICE
''';

  const blockAggBaseline = '''
define plainRule "Plain Rule" for roll *d*

  make selection @HIGH
    with top 1

  use selection @HIGH
    aggregate over selection max
    on result [1:*] action blink green
  report max over @HIGH
''';

  group('report clause', () {
    test('reports the clause aggregate, not the matching block aggregate', () async {
      final runner = await DslTestRunner.create();
      final res = await runner.run(
        rule: withReport,
        dice: [DieInput('d6', 6, id: 'X'), DieInput('d6', 1, id: 'Y'), DieInput('d6', 3, id: 'Z')],
      );

      expect(res.parse.result, 10, reason: 'sum over all dice');
      expect(res.actions.map((a) => a.dieId), ['X'], reason: 'block still matched on max');
    });

    test('report can mirror the block aggregate', () async {
      final runner = await DslTestRunner.create();
      final res = await runner.run(
        rule: blockAggBaseline,
        dice: [DieInput('d6', 6, id: 'X'), DieInput('d6', 1, id: 'Y'), DieInput('d6', 3, id: 'Z')],
      );

      expect(res.parse.result, 6, reason: 'max of @HIGH');
    });

    test('rolledEvaluated stays the acted-on selection, not the report selection', () async {
      final runner = await DslTestRunner.create();
      final res = await runner.run(rule: withReport, dice: [DieInput('d6', 6, id: 'X'), DieInput('d6', 1, id: 'Y')]);

      expect(res.parse.rolledEvaluated.keys.toSet(), {'X'});
      expect(res.parse.allRolled.keys.toSet(), {'X', 'Y'});
    });

    test('the clause does not make an unmatched rule claim the roll', () async {
      final runner = await DslTestRunner.create();
      // `dupes [2:2]` selects nothing, so the range misses despite the report clause.
      const gated = '''
define gated "Gated" for roll *d*

  make selection @DUPE2
    with dupes [2:2]

  use selection @DUPE2
    aggregate over selection count
    on result [1:*] action blink blue

  report sum over \$ALL_DICE
''';
      final res = await runner.run(rule: gated, dice: [DieInput('d6', 1, id: 'A'), DieInput('d6', 2, id: 'B')]);

      expect(res.parse.matchedResult, isFalse);
      expect(res.actions, isEmpty);
    });

    test('parses', () {
      final parsed = RuleParser.parse(rule: withReport, threshold: 0, modifier: 0, rolledCount: 3);
      expect(parsed.report.selectionToken, r'$ALL_DICE');
    });

    test('is required — a rule without one is rejected', () {
      const missing = '''
define noReportRule "No Report" for roll *d*

  use selection \\\$ALL_DICE
    aggregate over selection sum
    on result [*:*] action blink green
''';
      expect(
        () => RuleParser.parse(rule: missing, threshold: 0, modifier: 0, rolledCount: 2),
        throwsA(anything),
        reason: 'report is mandatory — the intended breaking change',
      );
    });

    test('must be last — a report before the use blocks is rejected', () {
      const early = '''
define earlyReport "Early" for roll *d*

  report sum over \\\$ALL_DICE

  use selection \\\$ALL_DICE
    aggregate over selection sum
    on result [*:*] action blink green
''';
      expect(() => RuleParser.parse(rule: early, threshold: 0, modifier: 0, rolledCount: 2), throwsA(anything));
    });
  });

  group('block outputs', () {
    test('every use block is reported, matched or not, in script order', () async {
      final runner = await DslTestRunner.create();
      // @ALL_MAX matches (count 1 in [1:3)); @DUPE_ANY does not (count 0).
      final res = await runner.run(
        rule: highLowAllTies,
        dice: [DieInput('d6', 6, id: 'X'), DieInput('d6', 1, id: 'Y'), DieInput('d6', 3, id: 'Z')],
      );

      expect(res.parse.blockOutputs.length, 3, reason: 'three use blocks in the rule');
      expect(res.parse.blockOutputs.map((b) => b.selection).toList(), [
        '@DUPE_ANY',
        '@ALL_MAX',
        '@ALL_MIN',
      ], reason: 'script order');

      final dupes = res.parse.blockOutputs.first;
      expect(dupes.matched, isFalse, reason: 'no duplicates in 6/1/3');
      expect(dupes.aggregate, 0);
      expect(dupes.dice, isEmpty);

      final maxBlock = res.parse.blockOutputs[1];
      expect(maxBlock.matched, isTrue);
      expect(maxBlock.dice.keys.toSet(), {'X'});

      // The headline value still comes from the report clause, not any block.
      expect(res.parse.result, 10);
    });

    test('blocks are still reported when the rule claims nothing', () async {
      final runner = await DslTestRunner.create();
      // No pair, so the only block misses and the rule does not claim the roll —
      // the per-block detail is still available to whoever wants to show why.
      final res = await runner.run(rule: doubles, dice: [DieInput('d6', 1, id: 'A'), DieInput('d6', 2, id: 'B')]);

      expect(res.parse.matchedResult, isFalse);
      expect(res.parse.blockOutputs, hasLength(1));
      expect(res.parse.blockOutputs.single.matched, isFalse);
      expect(res.parse.blockOutputs.single.aggregate, 0, reason: 'count of an empty selection');
    });

    test('a single-block rule reports one output', () async {
      final runner = await DslTestRunner.create();
      final res = await runner.run(rule: withReport, dice: [DieInput('d6', 6, id: 'X'), DieInput('d6', 2, id: 'Y')]);

      expect(res.parse.blockOutputs.length, 1);
      expect(res.parse.blockOutputs.single.aggregate, 6, reason: 'max of @HIGH');
      expect(res.parse.result, 8, reason: 'report sum over all dice');
    });
  });

  group('use-block reconciliation', () {
    test('a trailing block that matched nothing no longer sets the value', () async {
      final runner = await DslTestRunner.create();
      // @ALL_MAX matches first; the old code let the @ALL_MIN block overwrite it.
      final res = await runner.run(
        rule: highLowAllTies,
        dice: [DieInput('d6', 6, id: 'X'), DieInput('d6', 1, id: 'Y'), DieInput('d6', 6, id: 'Z')],
      );

      // These rules now carry a report clause, so the roll total is authoritative.
      expect(res.parse.result, 13);
      expect(res.parse.rolledEvaluated.keys.toSet(), {'X', 'Z'}, reason: 'the acting block');
    });

    test('shipped high/low rules report the roll total', () async {
      final runner = await DslTestRunner.create();
      final dice = [DieInput('d6', 6, id: 'X'), DieInput('d6', 1, id: 'Y'), DieInput('d6', 3, id: 'Z')];

      for (final rule in [highLowSinglePreferMax, highLowTiesSingle, highLowAllTies]) {
        final res = await runner.run(rule: rule, dice: dice);
        expect(res.parse.result, 10, reason: 'natural sum, not max (6) or min (1)');
      }
    });
  });
}
