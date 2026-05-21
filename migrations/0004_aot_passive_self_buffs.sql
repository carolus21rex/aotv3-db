-- AoTv3: self-passive spells and Throw Stone
-- Self-passive spells use buffdurationformula=52 and targettype=6 (ST_Self).
-- They auto-apply while memorized and persist with no visible timer.
-- Resource costs per tick are handled by the SPA itself in DoBuffTic,
-- not by the passive upkeep system (recast_time=0 = free to maintain).
--
-- New custom SPAs (common/spdat.h):
--   527 = EnduranceToMana: base=flat endurance drained, limit=% of max mana restored
--   528 = HPToMana:        base=% of max HP drained, limit=% of max mana restored

INSERT INTO spells_new
(id, name, cast_time, recovery_time, recast_time, buffdurationformula, buffduration, mana, EndurCost,
 effectid1, effect_base_value1, effect_limit_value1,
 resisttype, ResistDiff, targettype, goodEffect, IsDiscipline, `range`,
 you_cast, cast_on_you, cast_on_other, spell_fades)
VALUES

-- Breeze: drains 1 endurance per tick, restores 2% of max mana per tick
(60033, 'Breeze', 0, 0, 0,
 52, 0, 0, 0,
 527, 1, 2,
 0, 0, 6, 1, 0, 0,
 '', 'A gentle breeze flows through you.', '', 'The breeze fades.'),

-- Life Ebb: drains 4% of max HP per tick, restores 1% of max mana per tick
(60034, 'Life Ebb', 0, 0, 0,
 52, 0, 0, 0,
 528, 4, 1,
 0, 0, 6, 1, 0, 0,
 '', 'Vitality flows inward.', '', 'Life Ebb fades.');

-- Throw Stone: instant physical DD, 5 damage, 2 endurance cost, 25s cooldown
-- Simple SPA 0 (CurrentHP) spell through the normal spell damage path.
-- No skill attack mechanics — just a reliable minor interrupt/opener.
INSERT INTO spells_new
(id, name, cast_time, recovery_time, recast_time, buffdurationformula, buffduration, mana, EndurCost,
 effectid1, effect_base_value1,
 resisttype, ResistDiff, targettype, goodEffect, IsDiscipline, `range`,
 you_cast, cast_on_you, cast_on_other, spell_fades)
VALUES
(60035, 'Throw Stone', 0, 1500, 25000,
 7, 0, 0, 2,
 0, -5,
 8, 0, 5, 0, 0, 100,
 'You throw a stone at %t.', 'A stone strikes you!', '%n is struck by a thrown stone.', '');
