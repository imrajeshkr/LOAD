-- =============================================================================
-- v2_0058 — the middle environment means dumbbells, and now owns only dumbbells
--
-- The intake tile for `home_gym` used to read "Home gym", which told a lifter
-- nothing: home is a place, and the tile beside it ("Bodyweight") is a kit, so
-- the two read as alternatives when they are not — you can train at home with
-- dumbbells. The tile now reads "Dumbbells".
--
-- That makes the seeded equipment a lie. `home_gym` was granted a barbell, a
-- rack and kettlebells, so someone who picked it to mean "I own dumbbells"
-- would be prescribed back squats in a rack they do not have, and would find
-- that out on day one.
--
-- What stays: dumbbell, bench, bodyweight, pull-up-bar. The bar is kept
-- deliberately — `bodyweight_only` already assumes one, and a tier that is
-- strictly worse equipped than the tier below it is not a tier, it is a bug.
-- =============================================================================

delete from environment_equipment ee
 using equipment eq
 where ee.equipment_id = eq.id
   and ee.environment = 'home_gym'
   and eq.slug in ('barbell', 'rack', 'kettlebell');

-- Anyone already on this tier has a plan built against the old assumption.
-- Their next generation picks up the change; nothing is rewritten under them
-- here, because a silent rewrite of a live week is worse than a stale one.
