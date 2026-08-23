#!/usr/bin/env python3
"""Generate SQL to import free-exercise-db into the LOAD catalog.

Source: https://github.com/yuhonas/free-exercise-db (The Unlicense, public domain)

Everything imported here lands as EXTENDED (is_core = false): browsable and
swappable, never auto-selected into a plan. Only exercises with authored joint
stress and muscle contributions may be prescribed, and that enrichment is a
separate, reviewed step.

Usage:
    python3 tool/import_catalog.py exercises.json > out.sql
"""
import json, re, sys, collections

# ── dataset value → our vocabulary ───────────────────────────────────────────
# Anything mapping to None is skipped: we have no equipment row for it, and
# inventing one would let the generator prescribe kit the user was never asked
# about.
EQUIPMENT = {
    'barbell': 'barbell', 'e-z curl bar': 'barbell', 'dumbbell': 'dumbbell',
    'kettlebells': 'kettlebell', 'cable': 'cable', 'machine': 'machine',
    'body only': 'bodyweight',
    'bands': None, 'medicine ball': None, 'exercise ball': None,
    'foam roll': None, 'other': None, None: None,
}

MUSCLE = {
    'quadriceps': 'Quads', 'hamstrings': 'Hamstrings', 'glutes': 'Glutes',
    'calves': 'Calves', 'chest': 'Chest', 'triceps': 'Triceps',
    'biceps': 'Biceps', 'lats': 'Lats', 'middle back': 'Rhomboids',
    'lower back': 'Lower Back', 'traps': 'Traps', 'forearms': 'Forearms',
    'abdominals': 'Abs', 'adductors': 'Adductors',
    'abductors': None, 'neck': None,     # no muscle row for these
    'shoulders': 'SPLIT',                # resolved by delt_of() below
}

LEVEL = {'beginner': 'beginner', 'intermediate': 'intermediate', 'expert': 'advanced'}

# Which of our three delts a "shoulders" exercise actually trains. Ordered:
# first match wins, so put the specific patterns before the general ones.
_DELT_RULES = [
    ('Rear Delt',  r'rear|reverse fly|reverse flye|back fly|back flye|pull apart|'
                   r'bent[- ]over lateral|face pull|external rotation|cuban'),
    ('Side Delt',  r'lateral raise|side lateral|side raise|lateral rais|upright row|'
                   r'shrug|scaption|abduction'),
    ('Front Delt', r'front raise|front cable|press|jerk|snatch|clean|overhead|'
                   r'military|arnold|internal rotation'),
]

def delt_of(name):
    n = name.lower()
    for target, pat in _DELT_RULES:
        if re.search(pat, n):
            return target
    return None          # genuinely ambiguous — caller drops the primary link

def pattern_of(primaries):
    """Our movement pattern, derived from the primary muscles."""
    P = set(primaries)
    if P & {'quadriceps', 'hamstrings', 'glutes', 'calves', 'adductors', 'abductors'}:
        return 'legs'
    if P & {'abdominals'}:
        return 'core'
    if P & {'lats', 'middle back', 'biceps', 'traps', 'forearms', 'lower back'}:
        return 'pull'
    if P & {'chest', 'triceps'}:
        return 'push'
    if P & {'shoulders'}:
        return 'push'    # refined per-exercise below when the delt resolves to rear
    return None

def slugify(name):
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip('-')
    return re.sub(r'-+', '-', s)

def q(s):
    return "null" if s is None else "'" + str(s).replace("'", "''") + "'"


def main(path):
    data = json.load(open(path))
    rows = [x for x in data if x.get('category') in ('strength', 'powerlifting')]

    seen, out, stats = set(), [], collections.Counter()
    for x in rows:
        equip = EQUIPMENT.get(x.get('equipment'))
        if equip is None:
            stats['skip_equipment'] += 1
            continue

        primaries = x.get('primaryMuscles') or []
        pattern = pattern_of(primaries)
        if pattern is None:
            stats['skip_no_pattern'] += 1
            continue

        # Resolve muscles, splitting "shoulders" into a specific delt.
        muscles, ambiguous = [], False
        for m in primaries:
            t = MUSCLE.get(m)
            if t == 'SPLIT':
                t = delt_of(x['name'])
                if t is None:
                    ambiguous = True
                    continue
                if t == 'Rear Delt' and pattern == 'push':
                    pattern = 'pull'          # rear delt work belongs with pulling
            if t:
                muscles.append(t)
        if not muscles:
            stats['skip_ambiguous_shoulder' if ambiguous else 'skip_no_muscle'] += 1
            continue

        slug = slugify(x['name'])
        if slug in seen:
            stats['skip_dup_slug'] += 1
            continue
        seen.add(slug)

        secondaries = []
        for m in (x.get('secondaryMuscles') or []):
            t = MUSCLE.get(m)
            if t and t != 'SPLIT' and t not in muscles:
                secondaries.append(t)

        out.append({
            'slug': slug, 'name': x['name'], 'pattern': pattern,
            'level': LEVEL.get(x.get('level'), 'beginner'),
            'mechanic': x.get('mechanic'), 'force': x.get('force'),
            'equip': equip, 'muscles': muscles, 'secondaries': secondaries,
            'desc': ' '.join(x.get('instructions') or [])[:1800],
            'images': x.get('images') or [],
        })
        stats['imported'] += 1

    # ── emit ────────────────────────────────────────────────────────────────
    print("-- Generated by tool/import_catalog.py — do not hand-edit.")
    print("-- Source: yuhonas/free-exercise-db (The Unlicense, public domain).")
    print("-- All rows land as EXTENDED (is_core = false): browse/swap only,")
    print("-- never auto-prescribed. Existing catalog rows are left untouched.")
    print("begin;")
    for e in out:
        print(f"""
insert into exercises (slug, name, pattern, load_type, min_experience, mechanic,
                       force, is_core, source, description, default_rep_low, default_rep_high)
values ({q(e['slug'])}, {q(e['name'])}, {q(e['pattern'])},
        {"'bodyweight_reps'" if e['equip']=='bodyweight' else "'weight_reps'"},
        {q(e['level'])}, {q(e['mechanic'])}, {q(e['force'])}, false,
        'free-exercise-db', {q(e['desc'])}, 8, 12)
on conflict (slug) where owner_id is null do nothing;""")
        for m in e['muscles']:
            print(f"""insert into exercise_muscles (exercise_id, muscle_id, role, contribution)
select e.id, m.id, 'primary', 1.0 from exercises e, muscles m
 where e.slug={q(e['slug'])} and e.owner_id is null and m.name={q(m)}
on conflict do nothing;""")
        for m in e['secondaries']:
            print(f"""insert into exercise_muscles (exercise_id, muscle_id, role, contribution)
select e.id, m.id, 'secondary', 0.5 from exercises e, muscles m
 where e.slug={q(e['slug'])} and e.owner_id is null and m.name={q(m)}
on conflict do nothing;""")
        print(f"""insert into exercise_equipment (exercise_id, equipment_id, is_required)
select e.id, q.id, true from exercises e, equipment q
 where e.slug={q(e['slug'])} and e.owner_id is null and q.slug={q(e['equip'])}
on conflict do nothing;""")
    print("commit;")

    for k, v in sorted(stats.items()):
        print(f"-- {k}: {v}", file=sys.stderr)
    print(f"-- emitted: {len(out)}", file=sys.stderr)


if __name__ == '__main__':
    main(sys.argv[1])
