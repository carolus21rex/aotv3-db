-- AoTv3 custom spells table
-- Stores the custom ability roster separate from the base PEQ spell data.

CREATE TABLE IF NOT EXISTS aot_spells (
    id            INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name          VARCHAR(64)  NOT NULL,
    resist_type   VARCHAR(32)  NOT NULL DEFAULT 'magic',
    resist_adjust INT          NOT NULL DEFAULT 0,
    mana_cost     INT UNSIGNED NOT NULL DEFAULT 0,
    end_cost      INT UNSIGNED NOT NULL DEFAULT 0,
    cast_time_ms  INT UNSIGNED NOT NULL DEFAULT 0,
    cooldown_ms   INT UNSIGNED NOT NULL DEFAULT 0,
    duration_ticks INT UNSIGNED NOT NULL DEFAULT 0,
    description   TEXT,
    created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
