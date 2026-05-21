-- Flag passive aura spells with buffdurationformula=52.
-- The server checks this value to identify spells that should be auto-applied
-- and maintained while the caster has them on their spellbar.
--
-- buffdurationformula=52 is a custom sentinel outside EQEmu's normal range (0-15, 50-51).
-- formula=50 means "permanent" in vanilla EQEmu and is intentionally avoided here.
--
-- Passive conditions:
--   group buffs  (targettype=41): caster on spellbar + target in group + target in range
--   self buffs   (targettype=6):  caster on spellbar only (no group/range check)
--
-- The server applies these as permanent buffs (ticsremaining=-1, no timer shown).
-- Fading is handled server-side when the caster unmems, dies, disconnects, or for
-- group spells when the target leaves the group or walks out of range.
--
-- Active buffs (heals, Woodskin, Divine Aura, etc.) are NOT touched here —
-- they keep buffdurationformula=7 and behave as normal cast-and-forget spells.

UPDATE spells_new
SET buffdurationformula = 52,
    buffduration        = 0
WHERE id IN (
    -- group auras
    60024, -- Courage
    60025, -- Thoughtfulness
    60026, -- Brawn
    60027, -- Nimbleness
    60028, -- Haste
    60029  -- Alacrity
);

-- Resource cost schema (fields repurposed for passive maintenance; these spells
-- are never cast through the normal casting system so the cast-use meaning is unused):
--   mana         → mana drained from caster per recast_time interval
--   EndurCost    → endurance drained from caster per recast_time interval
--   recast_time  → payment interval in ms (0 = free passive, no drain)
--
-- Level 1 group auras: light mana drain every 30 s (recast_time=30000).
-- Adjust per spell as balancing warrants.
UPDATE spells_new
SET recast_time = 30000,   -- pay every 30 s
    mana        = 1        -- 5 mana per interval
WHERE id IN (60024, 60025, 60026, 60027);  -- Courage, Thoughtfulness, Brawn, Nimbleness

UPDATE spells_new
SET recast_time = 30000,
    mana        = 2        -- slightly more expensive (combat-relevant)
WHERE id IN (60028, 60029);  -- Haste, Alacrity

-- Self passives (spellbar-only condition, no group/range check needed)
-- These IDs will be assigned when the custom-SPA spells are added:
--   Breeze, Life Ebb, Minor Regeneration, Sturdy Footing, Passive Protection,
--   Minor Fortify Attack, Concentration, Willpower, Blade Turn
-- Placeholder so the pattern is clear when those spells are inserted:
-- UPDATE spells_new SET buffdurationformula=52, buffduration=0,
--        recast_time=<interval_ms>, mana=<cost>, EndurCost=<cost> WHERE id IN (...);
