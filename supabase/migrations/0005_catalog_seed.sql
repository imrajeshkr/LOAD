-- =============================================================================
-- LOAD — global exercise catalog
--
-- Replaces the hardcoded `defaultExercises`, `formCues`, `defaultCues` and
-- `exerciseAlts` constants in lib/models/models.dart and lib/services/app_state.dart.
-- Idempotent: safe to re-run as the catalog grows.
-- =============================================================================

-- ── muscles ─────────────────────────────────────────────────────────────
insert into muscles (slug, name, muscle_group) values
  ('chest',      'Chest',            'chest'),
  ('front-delt', 'Front Delt',       'shoulders'),
  ('side-delt',  'Side Delt',        'shoulders'),
  ('rear-delt',  'Rear Delt',        'shoulders'),
  ('triceps',    'Triceps',          'arms'),
  ('biceps',     'Biceps',           'arms'),
  ('forearms',   'Forearms',         'arms'),
  ('lats',       'Lats',             'back'),
  ('traps',      'Traps',            'back'),
  ('rhomboids',  'Rhomboids',        'back'),
  ('lower-back', 'Lower Back',       'back'),
  ('glutes',     'Glutes',           'legs'),
  ('quads',      'Quads',            'legs'),
  ('hamstrings', 'Hamstrings',       'legs'),
  ('calves',     'Calves',           'legs'),
  ('adductors',  'Adductors',        'legs'),
  ('abs',        'Abs',              'core'),
  ('obliques',   'Obliques',         'core')
on conflict (slug) do nothing;

-- ── joints ──────────────────────────────────────────────────────────────
insert into joints (slug, name) values
  ('shoulder', 'Shoulder'),
  ('elbow',    'Elbow'),
  ('wrist',    'Wrist'),
  ('knee',     'Knee'),
  ('hip',      'Hip'),
  ('lumbar',   'Lower Back'),
  ('ankle',    'Ankle')
on conflict (slug) do nothing;

-- ── equipment ───────────────────────────────────────────────────────────
insert into equipment (slug, name) values
  ('barbell',      'Barbell'),
  ('dumbbell',     'Dumbbell'),
  ('cable',        'Cable Machine'),
  ('machine',      'Fixed Machine'),
  ('bench',        'Bench'),
  ('rack',         'Squat Rack'),
  ('pull-up-bar',  'Pull-Up Bar'),
  ('kettlebell',   'Kettlebell'),
  ('bodyweight',   'None')
on conflict (slug) do nothing;

-- What each environment can be assumed to have.
insert into environment_equipment (environment, equipment_id)
select v.env::train_environment, eq.id
  from (values
    ('commercial_gym','barbell'), ('commercial_gym','dumbbell'), ('commercial_gym','cable'),
    ('commercial_gym','machine'), ('commercial_gym','bench'),    ('commercial_gym','rack'),
    ('commercial_gym','pull-up-bar'), ('commercial_gym','kettlebell'), ('commercial_gym','bodyweight'),
    ('home_gym','barbell'), ('home_gym','dumbbell'), ('home_gym','bench'), ('home_gym','rack'),
    ('home_gym','pull-up-bar'), ('home_gym','kettlebell'), ('home_gym','bodyweight'),
    ('bodyweight_only','bodyweight'), ('bodyweight_only','pull-up-bar')
  ) as v(env, eq_slug)
  join equipment eq on eq.slug = v.eq_slug
on conflict do nothing;

-- ── exercises ───────────────────────────────────────────────────────────
insert into exercises (slug, name, pattern, load_type, default_rep_low, default_rep_high, aliases) values
  -- push
  ('bench-press',        'Bench Press',           'push', 'weight_reps',      6, 10, array['bench','bb bench','flat bench','barbell bench']),
  ('incline-db-press',   'Incline DB Press',      'push', 'weight_reps',      8, 12, array['incline press','incline dumbbell press','incline db']),
  ('overhead-press',     'Overhead Press',        'push', 'weight_reps',      6, 10, array['ohp','military press','shoulder press','strict press']),
  ('db-bench-press',     'DB Bench Press',        'push', 'weight_reps',      8, 12, array['dumbbell bench','db bench','db press']),
  ('machine-chest-press','Machine Chest Press',   'push', 'weight_reps',      8, 12, array['chest press','machine press']),
  ('cable-fly',          'Cable Fly',             'push', 'weight_reps',     12, 15, array['fly','pec fly','cable flye']),
  ('tricep-pushdown',    'Tricep Pushdown',       'push', 'weight_reps',     10, 15, array['pushdown','rope pushdown','tricep extension']),
  ('overhead-tricep-ext','Overhead Tricep Ext',   'push', 'weight_reps',     10, 15, array['skullcrusher','overhead extension']),
  ('lateral-raise',      'Lateral Raise',         'push', 'weight_reps',     12, 20, array['lat raise','side raise','side delt raise']),
  ('floor-press',        'Floor Press',           'push', 'weight_reps',      6, 10, array['bb floor press']),
  ('landmine-press',     'Landmine Press',        'push', 'weight_reps',      8, 12, array['landmine']),
  ('push-up',            'Push-Up',               'push', 'bodyweight_reps', 10, 25, array['pushup','press up']),
  -- pull
  ('barbell-row',        'Barbell Row',           'pull', 'weight_reps',      6, 10, array['bb row','bent over row','pendlay row']),
  ('pull-up',            'Pull-Up',               'pull', 'bodyweight_reps',  5, 12, array['pullup','chin up','chinup']),
  ('lat-pulldown',       'Lat Pulldown',          'pull', 'weight_reps',      8, 12, array['pulldown','lat pull down']),
  ('seated-cable-row',   'Seated Cable Row',      'pull', 'weight_reps',      8, 12, array['cable row','seated row']),
  ('dumbbell-row',       'Dumbbell Row',          'pull', 'weight_reps',      8, 12, array['db row','single arm row','one arm row']),
  ('chest-supported-row','Chest Supported Row',   'pull', 'weight_reps',      8, 12, array['csr','machine row']),
  ('face-pull',          'Face Pull',             'pull', 'weight_reps',     15, 20, array['rope face pull']),
  ('barbell-curl',       'Barbell Curl',          'pull', 'weight_reps',      8, 12, array['bb curl','curl','bicep curl']),
  ('hammer-curl',        'Hammer Curl',           'pull', 'weight_reps',     10, 14, array['db hammer curl']),
  -- legs
  ('back-squat',         'Back Squat',            'legs', 'weight_reps',      5, 10, array['squat','bb squat','barbell squat']),
  ('front-squat',        'Front Squat',           'legs', 'weight_reps',      5,  8, array['fs']),
  ('deadlift',           'Deadlift',              'legs', 'weight_reps',      3,  6, array['dl','conventional deadlift']),
  ('romanian-deadlift',  'Romanian Deadlift',     'legs', 'weight_reps',      8, 12, array['rdl','stiff leg deadlift']),
  ('leg-press',          'Leg Press',             'legs', 'weight_reps',     10, 15, array['leg press machine']),
  ('leg-curl',           'Leg Curl',              'legs', 'weight_reps',     10, 15, array['hamstring curl','lying leg curl']),
  ('leg-extension',      'Leg Extension',         'legs', 'weight_reps',     12, 15, array['quad extension','knee extension']),
  ('bulgarian-split-squat','Bulgarian Split Squat','legs','weight_reps',      8, 12, array['bss','split squat','rear foot elevated split squat']),
  ('walking-lunge',      'Walking Lunge',         'legs', 'weight_reps',     10, 14, array['lunge','lunges']),
  ('hip-thrust',         'Hip Thrust',            'legs', 'weight_reps',      8, 12, array['barbell hip thrust','glute bridge']),
  ('goblet-squat',       'Goblet Squat',          'legs', 'weight_reps',     10, 15, array['db squat']),
  ('calf-raise',         'Calf Raise',            'legs', 'weight_reps',     12, 20, array['standing calf raise','calf press']),
  -- core
  ('plank',              'Plank',                 'core', 'time',           null, null, array['front plank']),
  ('hanging-leg-raise',  'Hanging Leg Raise',     'core', 'bodyweight_reps', 8, 15, array['leg raise','hanging knee raise']),
  ('cable-crunch',       'Cable Crunch',          'core', 'weight_reps',    12, 20, array['rope crunch','kneeling crunch'])
on conflict (slug) where owner_id is null do nothing;

-- ── which muscles each movement loads ───────────────────────────────────
insert into exercise_muscles (exercise_id, muscle_id, role, contribution)
select e.id, m.id, v.role::muscle_role, v.contribution
  from (values
    ('bench-press','chest','primary',1.0),        ('bench-press','triceps','secondary',0.5),
    ('bench-press','front-delt','secondary',0.5),
    ('incline-db-press','chest','primary',1.0),   ('incline-db-press','front-delt','secondary',0.5),
    ('incline-db-press','triceps','secondary',0.3),
    ('overhead-press','front-delt','primary',1.0),('overhead-press','triceps','secondary',0.5),
    ('overhead-press','side-delt','secondary',0.3),
    ('db-bench-press','chest','primary',1.0),     ('db-bench-press','triceps','secondary',0.4),
    ('machine-chest-press','chest','primary',1.0),('machine-chest-press','triceps','secondary',0.3),
    ('cable-fly','chest','primary',1.0),
    ('tricep-pushdown','triceps','primary',1.0),
    ('overhead-tricep-ext','triceps','primary',1.0),
    ('lateral-raise','side-delt','primary',1.0),
    ('floor-press','chest','primary',1.0),        ('floor-press','triceps','secondary',0.5),
    ('landmine-press','front-delt','primary',1.0),('landmine-press','chest','secondary',0.4),
    ('push-up','chest','primary',1.0),            ('push-up','triceps','secondary',0.4),
    ('barbell-row','lats','primary',1.0),         ('barbell-row','rhomboids','secondary',0.6),
    ('barbell-row','biceps','secondary',0.4),
    ('pull-up','lats','primary',1.0),             ('pull-up','biceps','secondary',0.5),
    ('lat-pulldown','lats','primary',1.0),        ('lat-pulldown','biceps','secondary',0.4),
    ('seated-cable-row','rhomboids','primary',1.0),('seated-cable-row','lats','secondary',0.6),
    ('dumbbell-row','lats','primary',1.0),        ('dumbbell-row','rhomboids','secondary',0.5),
    ('chest-supported-row','rhomboids','primary',1.0),('chest-supported-row','lats','secondary',0.6),
    ('face-pull','rear-delt','primary',1.0),      ('face-pull','traps','secondary',0.5),
    ('barbell-curl','biceps','primary',1.0),
    ('hammer-curl','biceps','primary',1.0),       ('hammer-curl','forearms','secondary',0.5),
    ('back-squat','quads','primary',1.0),         ('back-squat','glutes','secondary',0.7),
    ('back-squat','lower-back','stabiliser',0.3),
    ('front-squat','quads','primary',1.0),        ('front-squat','glutes','secondary',0.5),
    ('deadlift','hamstrings','primary',1.0),      ('deadlift','glutes','secondary',0.8),
    ('deadlift','lower-back','secondary',0.7),
    ('romanian-deadlift','hamstrings','primary',1.0),('romanian-deadlift','glutes','secondary',0.6),
    ('leg-press','quads','primary',1.0),          ('leg-press','glutes','secondary',0.5),
    ('leg-curl','hamstrings','primary',1.0),
    ('leg-extension','quads','primary',1.0),
    ('bulgarian-split-squat','quads','primary',1.0),('bulgarian-split-squat','glutes','secondary',0.7),
    ('walking-lunge','quads','primary',1.0),      ('walking-lunge','glutes','secondary',0.6),
    ('hip-thrust','glutes','primary',1.0),        ('hip-thrust','hamstrings','secondary',0.4),
    ('goblet-squat','quads','primary',1.0),       ('goblet-squat','glutes','secondary',0.5),
    ('calf-raise','calves','primary',1.0),
    ('plank','abs','primary',1.0),                ('plank','obliques','secondary',0.5),
    ('hanging-leg-raise','abs','primary',1.0),
    ('cable-crunch','abs','primary',1.0)
  ) as v(ex, mu, role, contribution)
  join exercises e on e.slug = v.ex and e.owner_id is null
  join muscles   m on m.slug = v.mu
on conflict do nothing;

-- ── which joints each movement stresses ─────────────────────────────────
-- This is what turns "Cranky left shoulder" into a correct warning on every
-- movement in the catalog, rather than only the four that were hardcoded.
insert into exercise_joints (exercise_id, joint_id, stress_level)
select e.id, j.id, v.lvl::severity_level
  from (values
    ('bench-press','shoulder','moderate'),   ('bench-press','elbow','mild'),
    ('bench-press','wrist','mild'),
    ('incline-db-press','shoulder','moderate'),
    ('overhead-press','shoulder','severe'),  ('overhead-press','elbow','mild'),
    ('db-bench-press','shoulder','moderate'),
    ('machine-chest-press','shoulder','mild'),
    ('cable-fly','shoulder','moderate'),
    ('tricep-pushdown','elbow','moderate'),
    ('overhead-tricep-ext','elbow','severe'),('overhead-tricep-ext','shoulder','moderate'),
    ('lateral-raise','shoulder','mild'),
    ('floor-press','shoulder','mild'),       ('floor-press','elbow','mild'),
    ('landmine-press','shoulder','mild'),
    ('push-up','wrist','moderate'),          ('push-up','shoulder','mild'),
    ('barbell-row','lumbar','moderate'),     ('barbell-row','elbow','mild'),
    ('pull-up','shoulder','moderate'),       ('pull-up','elbow','moderate'),
    ('lat-pulldown','shoulder','mild'),
    ('seated-cable-row','lumbar','mild'),
    ('dumbbell-row','lumbar','mild'),
    ('face-pull','shoulder','mild'),
    ('barbell-curl','elbow','moderate'),     ('barbell-curl','wrist','moderate'),
    ('hammer-curl','elbow','mild'),
    ('back-squat','knee','moderate'),        ('back-squat','hip','moderate'),
    ('back-squat','lumbar','moderate'),
    ('front-squat','knee','moderate'),       ('front-squat','wrist','moderate'),
    ('deadlift','lumbar','severe'),          ('deadlift','hip','moderate'),
    ('romanian-deadlift','lumbar','moderate'),('romanian-deadlift','hip','moderate'),
    ('leg-press','knee','moderate'),
    ('leg-curl','knee','mild'),
    ('leg-extension','knee','severe'),
    ('bulgarian-split-squat','knee','moderate'),('bulgarian-split-squat','hip','mild'),
    ('walking-lunge','knee','moderate'),
    ('hip-thrust','hip','mild'),
    ('goblet-squat','knee','mild'),
    ('calf-raise','ankle','mild'),
    ('plank','lumbar','mild'),
    ('hanging-leg-raise','shoulder','mild'),
    ('cable-crunch','lumbar','mild')
  ) as v(ex, jt, lvl)
  join exercises e on e.slug = v.ex and e.owner_id is null
  join joints    j on j.slug = v.jt
on conflict do nothing;

-- ── equipment requirements ──────────────────────────────────────────────
insert into exercise_equipment (exercise_id, equipment_id, is_required)
select e.id, eq.id, true
  from (values
    ('bench-press','barbell'),        ('bench-press','bench'),
    ('incline-db-press','dumbbell'),  ('incline-db-press','bench'),
    ('overhead-press','barbell'),
    ('db-bench-press','dumbbell'),    ('db-bench-press','bench'),
    ('machine-chest-press','machine'),
    ('cable-fly','cable'),
    ('tricep-pushdown','cable'),
    ('overhead-tricep-ext','dumbbell'),
    ('lateral-raise','dumbbell'),
    ('floor-press','barbell'),
    ('landmine-press','barbell'),
    ('push-up','bodyweight'),
    ('barbell-row','barbell'),
    ('pull-up','pull-up-bar'),
    ('lat-pulldown','cable'),
    ('seated-cable-row','cable'),
    ('dumbbell-row','dumbbell'),
    ('chest-supported-row','machine'),
    ('face-pull','cable'),
    ('barbell-curl','barbell'),
    ('hammer-curl','dumbbell'),
    ('back-squat','barbell'),         ('back-squat','rack'),
    ('front-squat','barbell'),        ('front-squat','rack'),
    ('deadlift','barbell'),
    ('romanian-deadlift','barbell'),
    ('leg-press','machine'),
    ('leg-curl','machine'),
    ('leg-extension','machine'),
    ('bulgarian-split-squat','dumbbell'),
    ('walking-lunge','dumbbell'),
    ('hip-thrust','barbell'),         ('hip-thrust','bench'),
    ('goblet-squat','dumbbell'),
    ('calf-raise','machine'),
    ('plank','bodyweight'),
    ('hanging-leg-raise','pull-up-bar'),
    ('cable-crunch','cable')
  ) as v(ex, eq_slug)
  join exercises e  on e.slug  = v.ex and e.owner_id is null
  join equipment eq on eq.slug = v.eq_slug
on conflict do nothing;

-- ── form cues (ported from lib/models/models.dart) ───────────────────────
insert into exercise_cues (exercise_id, position, body)
select e.id, v.pos, v.body
  from (values
    ('bench-press',1,'Retract shoulder blades before unracking.'),
    ('bench-press',2,'Bar path touches mid-chest, elbows around 45°.'),
    ('bench-press',3,'Drive feet into the floor, keep hips on the bench.'),
    ('bench-press',4,'Full lockout without flaring the elbows.'),
    ('overhead-press',1,'Brace your core, ribs down before pressing.'),
    ('overhead-press',2,'Bar starts at collarbone, path just in front of your face.'),
    ('overhead-press',3,'Lock out overhead, biceps by your ears.'),
    ('overhead-press',4,'Avoid excessive lower-back arch.'),
    ('incline-db-press',1,'Bench at 30–45°, dumbbells at chest level.'),
    ('incline-db-press',2,'Elbows around 45° from torso, not flared to 90°.'),
    ('incline-db-press',3,'Press up and slightly in, control the descent.'),
    ('incline-db-press',4,'Avoid bouncing the dumbbells off your chest.'),
    ('tricep-pushdown',1,'Elbows pinned to your sides throughout.'),
    ('tricep-pushdown',2,'Full extension without locking out aggressively.'),
    ('tricep-pushdown',3,'Control the eccentric, don''t let the bar fly up.'),
    ('tricep-pushdown',4,'Keep torso upright, no leaning into it.'),
    ('floor-press',1,'Upper arms rest on the floor at the bottom of each rep.'),
    ('floor-press',2,'Keeps the shoulder out of deep extension.'),
    ('floor-press',3,'Press straight up, pause briefly at the floor.'),
    ('floor-press',4,'Stop a rep short of form breakdown.'),
    ('landmine-press',1,'Angle keeps the shoulder in a friendlier path than vertical pressing.'),
    ('landmine-press',2,'Brace hard, press up and slightly forward.'),
    ('landmine-press',3,'Control the return, no crashing.'),
    ('landmine-press',4,'Keep ribs down throughout.'),
    ('machine-chest-press',1,'Set the seat so handles line up with mid-chest.'),
    ('machine-chest-press',2,'Elbows around 45° from your torso.'),
    ('machine-chest-press',3,'Press smoothly, control the return.'),
    ('machine-chest-press',4,'Stop a rep short of form breakdown.'),
    ('face-pull',1,'Pull toward your forehead, elbows high.'),
    ('face-pull',2,'Externally rotate at the end — thumbs back.'),
    ('face-pull',3,'Light weight, strict form. This is shoulder health work.'),
    ('face-pull',4,'Squeeze briefly at the end of each rep.'),
    ('back-squat',1,'Bar on the upper traps, elbows under the bar.'),
    ('back-squat',2,'Brace before you unrack, not after.'),
    ('back-squat',3,'Knees track over the toes, depth to parallel or below.'),
    ('back-squat',4,'Drive the whole foot through the floor.'),
    ('deadlift',1,'Bar over mid-foot, shoulders slightly ahead of the bar.'),
    ('deadlift',2,'Take the slack out before you pull.'),
    ('deadlift',3,'Push the floor away; hips and chest rise together.'),
    ('deadlift',4,'Lower under control — don''t dump the bar.'),
    ('romanian-deadlift',1,'Soft knees, hinge from the hips not the lower back.'),
    ('romanian-deadlift',2,'Bar stays in contact with the legs throughout.'),
    ('romanian-deadlift',3,'Stop when the hamstrings run out of range.'),
    ('romanian-deadlift',4,'Squeeze glutes to stand, don''t hyperextend.'),
    ('barbell-row',1,'Hinge to about 45°, keep the spine neutral.'),
    ('barbell-row',2,'Pull to the lower ribs, elbows past the torso.'),
    ('barbell-row',3,'No heaving — the torso angle stays fixed.'),
    ('barbell-row',4,'Control the bar back to full stretch.'),
    ('pull-up',1,'Start from a full hang, shoulders active.'),
    ('pull-up',2,'Drive the elbows down and back.'),
    ('pull-up',3,'Chin clears the bar without craning the neck.'),
    ('pull-up',4,'Lower under control to a full hang.')
  ) as v(ex, pos, body)
  join exercises e on e.slug = v.ex and e.owner_id is null
on conflict (exercise_id, position) do nothing;

-- ── substitutions (ported from `exerciseAlts`, plus equipment fallbacks) ──
insert into exercise_alternatives (exercise_id, alternative_id, reason, rank)
select e.id, a.id, v.reason::alt_reason, v.rank
  from (values
    -- joint-friendly swaps: what the Swap button offers when a joint is flagged
    ('bench-press','floor-press','joint_friendly',1),
    ('bench-press','machine-chest-press','joint_friendly',2),
    ('overhead-press','landmine-press','joint_friendly',1),
    ('incline-db-press','machine-chest-press','joint_friendly',1),
    ('tricep-pushdown','face-pull','joint_friendly',1),
    ('overhead-tricep-ext','tricep-pushdown','joint_friendly',1),
    ('leg-extension','leg-press','joint_friendly',1),
    ('deadlift','romanian-deadlift','joint_friendly',1),
    ('back-squat','goblet-squat','joint_friendly',1),
    ('back-squat','leg-press','joint_friendly',2),
    ('pull-up','lat-pulldown','joint_friendly',1),
    ('barbell-row','chest-supported-row','joint_friendly',1),
    ('barbell-curl','hammer-curl','joint_friendly',1),
    -- equipment substitutes: what to offer in a home gym
    ('machine-chest-press','db-bench-press','equipment_substitute',1),
    ('lat-pulldown','pull-up','equipment_substitute',1),
    ('seated-cable-row','dumbbell-row','equipment_substitute',1),
    ('leg-press','goblet-squat','equipment_substitute',1),
    ('leg-curl','romanian-deadlift','equipment_substitute',1),
    ('cable-fly','db-bench-press','equipment_substitute',1),
    ('calf-raise','push-up','equipment_substitute',9),
    -- progressions and regressions
    ('push-up','bench-press','progression',1),
    ('pull-up','lat-pulldown','regression',1),
    ('front-squat','back-squat','variation',1),
    ('goblet-squat','back-squat','progression',1)
  ) as v(ex, alt, reason, rank)
  join exercises e on e.slug = v.ex  and e.owner_id is null
  join exercises a on a.slug = v.alt and a.owner_id is null
on conflict do nothing;
