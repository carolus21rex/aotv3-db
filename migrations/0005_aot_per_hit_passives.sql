-- AoTv3: per-hit passive spells (Group B)
-- These are self/group passives (buffdurationformula=52) whose effects fire
-- inside Mob::ReduceDamage() on every melee hit received by the buff holder.
--
-- Custom SPAs (common/spdat.h):
--   529 = MeleeHitFlatAbsorb: base = flat damage absorbed per hit (no depletion)
--   530 = MeleeHitPctAbsorb:  base = % of damage reduced, limit = endurance cost per hit
--                              If holder endurance < cost: protection is skipped that hit.

INSERT INTO spells_new
(id, name, cast_time, recovery_time, recast_time, buffdurationformula, buffduration, mana, EndurCost,
 effectid1, effect_base_value1,
 resisttype, ResistDiff, targettype, goodEffect, IsDiscipline, `range`,
 you_cast, cast_on_you, cast_on_other, spell_fades)
VALUES
-- Passive Protection: absorb 1 damage on every melee hit, free upkeep, group range 200
(60036, 'Passive Protection', 0, 0, 0,
 52, 0, 0, 0,
 529, 1,
 0, 0, 41, 1, 0, 200,
 '', 'A protective ward settles around you.', '', 'The ward fades.');

INSERT INTO spells_new
(id, name, cast_time, recovery_time, recast_time, buffdurationformula, buffduration, mana, EndurCost,
 effectid1, effect_base_value1, effect_limit_value1,
 resisttype, ResistDiff, targettype, goodEffect, IsDiscipline, `range`,
 you_cast, cast_on_you, cast_on_other, spell_fades)
VALUES
-- Sturdy Footing: reduce 12% of melee damage per hit, costs 1 endurance per hit
-- Protection fails silently when endurance is exhausted.
(60037, 'Sturdy Footing', 0, 0, 0,
 52, 0, 0, 0,
 530, 12, 1,
 0, 0, 6, 1, 0, 0,
 '', 'Your footing becomes sturdy.', '', 'Sturdy Footing fades.');
