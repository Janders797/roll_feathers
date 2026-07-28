import 'package:flutter_test/flutter_test.dart';

import 'package:roll_feathers/domains/roll_parser/parser_rules.dart';
import 'package:roll_feathers/testing/dsl_test_harness.dart';

/// A rule's `for roll ...` die-matcher passing (`ruleReturn`) does not mean the
/// rule produced a result. `doubles` is `for roll *d*`, so it matches every roll;
/// before `matchedResult` existed, RollDomain treated that as "this rule owns the
/// roll" and recorded its dupe-count aggregate — 0 on a roll with no pair — in
/// place of the natural sum, while also shadowing every later rule.
void main() {
  group('matchedResult vs ruleReturn', () {
    test('doubles: no pair → die-matcher passes but no result is claimed', () async {
      final runner = await DslTestRunner.create();
      final res = await runner.run(
        rule: doubles,
        dice: [DieInput('d6', 1, id: 'A'), DieInput('d6', 2, id: 'B'), DieInput('d6', 3, id: 'C')],
      );

      expect(res.parse.ruleReturn, isTrue, reason: '*d* matches any roll');
      expect(res.parse.matchedResult, isFalse, reason: 'count of 0 is outside `on result [1:*]`');
      expect(res.actions, isEmpty);
    });

    test('doubles: a pair → result claimed, aggregate is the dupe count', () async {
      final runner = await DslTestRunner.create();
      final res = await runner.run(
        rule: doubles,
        dice: [DieInput('d6', 4, id: 'A'), DieInput('d6', 4, id: 'B'), DieInput('d6', 2, id: 'C')],
      );

      expect(res.parse.ruleReturn, isTrue);
      expect(res.parse.matchedResult, isTrue);
      expect(res.parse.result, 2);
    });

    test('rolledEvaluated is the matched selection, not every die', () async {
      final runner = await DslTestRunner.create();
      final res = await runner.run(
        rule: doubles,
        dice: [DieInput('d6', 4, id: 'A'), DieInput('d6', 4, id: 'B'), DieInput('d6', 2, id: 'C')],
      );

      // The pair only — C is part of the roll but not of what the rule acted on.
      expect(res.parse.rolledEvaluated.keys.toSet(), {'A', 'B'});
      expect(res.parse.allRolled.keys.toSet(), {'A', 'B', 'C'});
    });

    test('unmatched rule falls back to all rolled dice for rolledEvaluated', () async {
      final runner = await DslTestRunner.create();
      final res = await runner.run(
        rule: doubles,
        dice: [DieInput('d6', 1, id: 'A'), DieInput('d6', 2, id: 'B')],
      );

      expect(res.parse.matchedResult, isFalse);
      expect(res.parse.rolledEvaluated.keys.toSet(), {'A', 'B'});
    });

    test('nDupes: threshold met → claimed; threshold missed → not claimed', () async {
      final runner = await DslTestRunner.create();
      final triple = [
        DieInput('d6', 2, id: 'A'),
        DieInput('d6', 2, id: 'B'),
        DieInput('d6', 2, id: 'C'),
        DieInput('d6', 5, id: 'D'),
      ];

      final hit = await runner.run(rule: nDupes, threshold: 3, dice: triple);
      expect(hit.parse.matchedResult, isTrue);
      expect(hit.parse.result, 3);
      expect(hit.parse.rolledEvaluated.keys.toSet(), {'A', 'B', 'C'});

      // Same dice, looking for quads — nothing selected, nothing claimed.
      final miss = await runner.run(rule: nDupes, threshold: 4, dice: triple);
      expect(miss.parse.ruleReturn, isTrue);
      expect(miss.parse.matchedResult, isFalse);
    });

    test('standardRoll still claims an ordinary roll', () async {
      final runner = await DslTestRunner.create();
      final res = await runner.run(
        rule: standardRoll,
        dice: [DieInput('d6', 3, id: 'A'), DieInput('d6', 5, id: 'B')],
      );

      expect(res.parse.matchedResult, isTrue, reason: 'the default rule must keep reporting rolls');
      expect(res.parse.result, 8);
    });
  });
}
