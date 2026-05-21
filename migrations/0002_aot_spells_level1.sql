-- AoTv3 Level 1 Spell Roster
-- IDs 60000-60031 reserved for AoT custom spells (level 1 set)
-- Abilities requiring new SPAs are NOT included here:
--   Duel, Breeze, Life Ebb, Minor Regeneration, Sturdy Footing,
--   Passive Protection, Minor Fortify Attack, Concentration, Willpower,
--   Blade Turn, Kick, Strike, Throw Stone, Snipe, Divine Aura
--
-- SPA reference (spdat.h SpellEffect namespace):
--   0  = CurrentHP (repeats per tick if duration > 0)
--   79 = CurrentHPOnce (fires once on buff application, non-repeating)
--   1  = ArmorClass
--   3  = MovementSpeed   (negative = slow)
--   4  = STR, 5 = DEX, 6 = AGI, 7 = STA, 8 = INT, 9 = WIS, 10 = CHA
--   11 = AttackSpeed     (positive = haste, negative = slow)
--   15 = CurrentMana     (negative = drain, positive = restore)
--   21 = Stun            (base = duration ms)
--   55 = Rune            (absorb HP damage up to base value)
--   69 = TotalHP         (max HP modifier)
--   127= IncreaseSpellHaste (negative = reduce cast time %)
--   189= CurrentEndurance (negative = drain)
--
-- Resist types: 0=none 1=magic 2=fire 3=cold 4=poison 5=disease 8=physical 9=corruption
-- Target types: 5=single 6=self 8=targeted-AoE 41=group-v2

INSERT INTO spells_new
(id, name, cast_time, recovery_time, recast_time, buffdurationformula, buffduration, mana, EndurCost,
 effectid1, effect_base_value1, effectid2, effect_base_value2,
 resisttype, ResistDiff, targettype, goodEffect, aoerange, aemaxtargets, IsDiscipline, RecourseLink, `range`,
 you_cast, cast_on_you, cast_on_other, spell_fades)
VALUES

-- ── Damage: Fire ─────────────────────────────────────────────────────────────

-- Ember: -10 on application (SPA79) + -1/tick DoT (SPA0) for 5 ticks
(60000,'Ember',1500,1500,0,7,5,5,0,
 79,-10, 0,-1,
 2,0, 5,0, 0,0, 0,0, 100,
 'You cast Ember on %t.','You are set ablaze!','%n erupts in flames.','The flames die out.'),

-- Smolder: -7/tick DoT for 4 ticks
(60001,'Smolder',250,1500,10000,7,4,13,0,
 0,-7, 254,0,
 2,0, 5,0, 0,0, 0,0, 100,
 'You smolder %t.','You are set smoldering!','%n begins to smolder.','The smoldering fades.'),

-- ── Damage: Magic ────────────────────────────────────────────────────────────

-- Zap: -10 DD + 500ms stun (interrupt)
(60002,'Zap',250,1500,15000,7,0,10,0,
 0,-10, 21,500,
 1,0, 5,0, 0,0, 0,0, 100,
 'You zap %t.','You are jolted!','%n is struck by a jolt.',''),

-- Shock: -43 DD instant
(60003,'Shock',250,1500,20000,7,0,23,0,
 0,-43, 254,0,
 1,0, 5,0, 0,0, 0,0, 100,
 'You shock %t.','You are shocked!','%n is struck by high energy.',''),

-- ── Damage: Poison ───────────────────────────────────────────────────────────

-- Poison: -3/tick for 10 ticks
(60004,'Poison',2500,1500,0,7,10,8,0,
 0,-3, 254,0,
 4,0, 5,0, 0,0, 0,0, 100,
 'You poison %t.','You feel poisoned!','%n looks poisoned.','The poison wears off.'),

-- Toxic Gas: AoE -8/tick for 10 ticks, up to 4 targets
(60005,'Toxic Gas',1000,1500,45000,7,10,38,0,
 0,-8, 254,0,
 4,0, 8,0, 25,4, 0,0, 100,
 'You release a toxic gas.','You are engulfed in toxic gas!','%n is engulfed in toxic gas.','The toxic gas disperses.'),

-- ── Damage: Disease ──────────────────────────────────────────────────────────

-- Fever: -7/tick for 6 ticks
(60006,'Fever',250,1500,15000,7,6,17,0,
 0,-7, 254,0,
 5,0, 5,0, 0,0, 0,0, 100,
 'You inflict a fever on %t.','A nasty fever takes hold!','%n breaks into a fever.','The fever breaks.'),

-- Infection Cloud: AoE -11/tick for 6 ticks, up to 9 targets
(60007,'Infection Cloud',250,1500,60000,7,6,46,0,
 0,-11, 254,0,
 5,0, 8,0, 35,9, 0,0, 100,
 'You release an infection cloud.','You are infected!','%n is caught in the infection cloud.','The infection fades.'),

-- ── Damage: Cold ─────────────────────────────────────────────────────────────

-- Frost: -16 DD instant
(60008,'Frost',2500,1500,0,7,0,3,0,
 0,-16, 254,0,
 3,0, 5,0, 0,0, 0,0, 100,
 'You freeze %t.','You are frozen!','%n is suddenly frozen.',''),

-- Chill: -27 on application (SPA79) + -5% movement slow for 5 ticks
(60009,'Chill',1250,1500,20000,7,5,12,0,
 79,-27, 3,-5,
 3,0, 5,0, 0,0, 0,0, 100,
 'You chill %t.','A deep chill runs through you!','%n shivers from the chill.','The chill fades.'),

-- ── Damage: Corruption ───────────────────────────────────────────────────────

-- Lifetap: -16 on target; RecourseLink 60011 returns +16 to caster
(60010,'Lifetap',250,1500,15000,7,0,16,0,
 0,-16, 254,0,
 9,0, 5,0, 0,0, 0,60011, 100,
 'You steal life from %t.','Your life force is stolen!','%n''s life is drained away.',''),

-- Lifetap recourse: heals caster for 16 (self-target, fires via RecourseLink)
(60011,'Lifetap Recourse',0,0,0,7,0,0,0,
 0,16, 254,0,
 0,0, 6,1, 0,0, 0,0, 0,
 '','You feel your wounds close.','',''),

-- Dread: -10 STR + -4/tick DoT for 11 ticks
(60012,'Dread',250,1500,30000,7,11,18,0,
 4,-10, 0,-4,
 9,0, 5,0, 0,0, 0,0, 100,
 'You fill %t with dread.','A deep dread fills you!','%n is filled with dread.','The dread lifts.'),

-- Harm Touch: -200 DD, discipline, near-unresistable
(60013,'Harm Touch',250,1500,900000,7,0,0,0,
 0,-200, 254,0,
 9,-200, 5,0, 0,0, 1,0, 100,
 'You harm touch %t.','You are gripped in agony!','%n writhes in agony.',''),

-- ── Healing ──────────────────────────────────────────────────────────────────

-- Basic Healing: +17 HP instant
(60014,'Basic Healing',1500,1500,0,7,0,11,0,
 0,17, 254,0,
 0,0, 5,1, 0,0, 0,0, 100,
 'You heal %t.','You feel better.','%n looks healthier.',''),

-- Languid Healing: +5/tick HoT for 2 ticks (10 total; approximates "after 2 tick delay")
(60015,'Languid Healing',250,1500,0,7,2,2,0,
 0,5, 254,0,
 0,0, 5,1, 0,0, 0,0, 100,
 'You cast Languid Healing on %t.','A slow warmth begins to heal you.','%n is slowly healed.','The healing fades.'),

-- Tepid Recovery: +5/tick HoT for 10 ticks
(60016,'Tepid Recovery',250,1500,15000,7,10,19,0,
 0,5, 254,0,
 0,0, 5,1, 0,0, 0,0, 100,
 'You cast Tepid Recovery on %t.','A tepid recovery begins.','%n begins to recover.','The recovery fades.'),

-- Desperate Recovery: +1466/tick HoT for 5 ticks (1-hour cooldown)
(60017,'Desperate Recovery',6000,1500,3600000,7,5,0,0,
 0,1466, 254,0,
 0,0, 5,1, 0,0, 0,0, 100,
 'You cast Desperate Recovery on %t.','A desperate surge of healing washes over you.','%n is surrounded by desperate healing energy.','The desperate recovery fades.'),

-- Lay on Hands: +600 HP instant, discipline, 15-min cooldown
(60018,'Lay on Hands',250,1500,900000,7,0,0,0,
 0,600, 254,0,
 0,0, 5,1, 0,0, 1,0, 100,
 'You lay hands on %t.','Healing hands are laid upon you.','%n is healed by laying on of hands.',''),

-- ── Absorption ───────────────────────────────────────────────────────────────

-- Woodskin: absorb 13 HP damage for 10 ticks (self-only)
(60019,'Woodskin',250,1500,10000,7,10,4,0,
 55,13, 254,0,
 0,0, 6,1, 0,0, 0,0, 0,
 'You cast Woodskin on yourself.','Your skin hardens like wood.','','The woodskin fades.'),

-- Minor Magic Barrier: absorb 20 HP damage for 10 ticks
(60020,'Minor Magic Barrier',2500,1500,7500,7,10,6,0,
 55,20, 254,0,
 0,0, 5,1, 0,0, 0,0, 100,
 'You cast Minor Magic Barrier on %t.','A minor magic barrier surrounds you.','%n is surrounded by a magic barrier.','The magic barrier fades.'),

-- ── Mana / Endurance ─────────────────────────────────────────────────────────

-- Minor Manaflow: +30 mana to target
(60021,'Minor Manaflow',3000,1500,0,7,0,30,0,
 15,30, 254,0,
 0,0, 5,1, 0,0, 0,0, 100,
 'You transfer mana to %t.','Mana flows into you.','%n receives a flow of mana.',''),

-- Manatap: drain 11 mana from target (steal requires custom RecourseLink when implemented)
(60022,'Manatap',3000,1500,3000,7,0,8,0,
 15,-11, 254,0,
 1,0, 5,0, 0,0, 0,0, 100,
 'You tap the mana of %t.','Your mana is stolen!','%n''s mana is drained.',''),

-- Yawn: drain 10 endurance from target
(60023,'Yawn',250,1500,10000,7,0,15,0,
 189,-10, 254,0,
 5,0, 5,0, 0,0, 0,0, 100,
 'You make %t yawn.','A wave of fatigue hits you!','%n suddenly looks tired.',''),

-- ── Group Buffs (auto-applied while on spellbar — needs server-side aura logic) ──

-- Courage: +15 max HP, +4 AC
(60024,'Courage',0,0,0,7,65,0,0,
 69,15, 1,4,
 0,0, 41,1, 0,0, 0,0, 0,
 '','Courage fills you.','','Courage fades.'),

-- Thoughtfulness: +10 INT/WIS/CHA
(60025,'Thoughtfulness',0,0,0,7,65,0,0,
 8,10, 9,10,
 0,0, 41,1, 0,0, 0,0, 0,
 '','Clarity of thought fills your mind.','','Thoughtfulness fades.'),

-- Brawn: +12 STR/STA  (STA uses slot 3 since only 2 effectid cols in our short INSERT)
(60026,'Brawn',0,0,0,7,65,0,0,
 4,12, 7,12,
 0,0, 41,1, 0,0, 0,0, 0,
 '','Raw strength surges through you.','','Brawn fades.'),

-- Nimbleness: +12 AGI/DEX
(60027,'Nimbleness',0,0,0,7,65,0,0,
 6,12, 5,12,
 0,0, 41,1, 0,0, 0,0, 0,
 '','Your movements become nimble.','','Nimbleness fades.'),

-- Haste: +5% melee attack speed
(60028,'Haste',0,0,0,7,65,0,0,
 11,5, 254,0,
 0,0, 41,1, 0,0, 0,0, 0,
 '','You feel yourself moving faster.','','Haste fades.'),

-- Alacrity: -5% cast time (IncreaseSpellHaste: negative = faster)
(60029,'Alacrity',0,0,0,7,65,0,0,
 127,-5, 254,0,
 0,0, 41,1, 0,0, 0,0, 0,
 '','Your spells feel more fluid.','','Alacrity fades.');

-- Thoughtfulness only has 2 effect slots in the short form above; add CHA via UPDATE
UPDATE spells_new SET effectid3=10, effect_base_value3=10 WHERE id=60025;

-- ── Physical Disciplines (SkillAttack SPA 193) ────────────────────────────────
-- skill field routes the attack: 30=SkillKick, 1=Skill1HSlashing, 7=SkillArchery
-- base_value = weapon damage, limit_value = hit chance bonus

-- Kick: kick skill attack + 500ms stun (interrupt)
INSERT INTO spells_new
(id, name, cast_time, recovery_time, recast_time, buffdurationformula, buffduration, mana, EndurCost,
 effectid1, effect_base_value1, effect_limit_value1, effectid2, effect_base_value2,
 resisttype, ResistDiff, targettype, goodEffect, IsDiscipline, skill, `range`,
 you_cast, cast_on_you, cast_on_other, spell_fades)
VALUES
(60030,'Kick',250,1500,10000,7,0,0,5,
 193,100,0, 21,500,
 8,0, 5,0, 1,30, 8,
 'You kick %t.','You are kicked!','%n is kicked.',''),

-- Strike: 1-hand slash, 600 base damage
(60031,'Strike',500,1500,3000,7,0,0,12,
 193,600,0, 254,0,
 8,0, 5,0, 1,1, 8,
 'You strike %t.','You are struck!','%n is struck by a powerful blow.',''),

-- Snipe: archery, 900 base damage, +50 hit bonus (1.5x accuracy)
(60032,'Snipe',3000,1500,7500,7,0,0,10,
 193,900,50, 254,0,
 8,0, 5,0, 1,7, 100,
 'You take careful aim at %t.','An arrow strikes you with precision!','%n is struck by a precise shot.','');
