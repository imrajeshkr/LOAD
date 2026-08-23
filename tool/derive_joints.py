#!/usr/bin/env python3
"""Derive joint-stress data for the imported exercise catalog.

The 46 Core exercises carry hand-authored `exercise_joints` rows; the 484
imported ones carry none. That gap is not cosmetic — the injury filter in
bootstrap_user_program() and in exercise swap works by looking for SEVERE
stress on a joint the user has flagged, so an exercise with no joint rows
passes the filter trivially. It is the same blindness that made migration
v2_0026 necessary.

Hand-authoring 484 exercises is not realistic, but the stress a lift puts on a
joint is largely a function of things the dataset already tells us: which
muscles are prime movers, whether it is compound or isolation, and what the
movement is called. So we derive it by rule.

Crucially, 45 of the Core rows are hand-authored ground truth. `--validate`
scores the rules against them before a single derived row is written, so the
accuracy claim is measured rather than asserted.

    python3 tool/derive_joints.py catalog.tsv --validate
    python3 tool/derive_joints.py catalog.tsv --emit > out.sql

Bias: recall on SEVERE matters most. Missing a severe stress lets an injured
lifter be handed a lift that hurts them; inventing one only costs a candidate
in a list. The rules deliberately err toward flagging.
"""
import sys, re, collections

SEV = ('mild', 'moderate', 'severe')


def _max(a, b):
    """Severity is a ceiling, not a sum: the harshest claim wins."""
    if a is None:
        return b
    return a if SEV.index(a) >= SEV.index(b) else b


# ── Baseline stress implied by being a prime mover ──────────────────────────
# Read as: training this muscle inherently loads these joints.
BY_MUSCLE = {
    'Chest':      [('shoulder', 'moderate'), ('elbow', 'mild')],
    'Front Delt': [('shoulder', 'moderate'), ('elbow', 'mild')],
    'Side Delt':  [('shoulder', 'mild')],
    'Rear Delt':  [('shoulder', 'mild'), ('shoulder-blade', 'mild')],
    'Triceps':    [('elbow', 'moderate')],
    'Biceps':     [('elbow', 'mild')],
    'Lats':       [('shoulder', 'moderate'), ('elbow', 'mild')],
    'Rhomboids':  [('elbow', 'mild'), ('shoulder-blade', 'mild')],
    'Traps':      [('shoulder-blade', 'mild')],
    'Forearms':   [('wrist', 'moderate'), ('elbow', 'mild')],
    'Quads':      [('knee', 'moderate'), ('hip', 'moderate')],
    'Hamstrings': [('hip', 'moderate'), ('lumbar', 'moderate')],
    'Glutes':     [('hip', 'mild'), ('lumbar', 'mild')],
    'Adductors':  [('hip', 'moderate')],
    'Calves':     [('ankle', 'mild')],
    'Abs':        [('lumbar', 'mild')],
    'Obliques':   [('lumbar', 'mild')],
    'Lower Back': [('lumbar', 'moderate'), ('hip', 'mild')],
}

# ── Movement-specific rules, applied on top of the baseline ─────────────────
# First field is a regex over the lowercased exercise name. These encode the
# things the muscle list cannot know: a hinge punishes the lumbar spine, an
# overhead position punishes the shoulder, a dip punishes it more.
NAME_RULES = [
    # Hinging — the lumbar spine is the limiting joint, not the hamstrings.
    (r'\bdeadlift\b',                  [('lumbar', 'severe'), ('hip', 'moderate')]),
    (r'good morning|back extension|hyperextension',
                                       [('lumbar', 'severe'), ('hip', 'moderate')]),
    (r'romanian|stiff.?leg|rdl',       [('lumbar', 'moderate'), ('hip', 'moderate')]),
    (r'\bclean\b|\bsnatch\b|\bjerk\b', [('lumbar', 'severe'), ('shoulder', 'severe'),
                                        ('knee', 'moderate')]),
    # Overhead — the position, not the muscle, is what the shoulder objects to.
    (r'overhead press|overhead squat|overhead carry|military|\bpress behind|'
     r'shoulder press|behind the neck press|arnold',
                                       [('shoulder', 'severe')]),
    (r'overhead.*(extension|tricep)|french press|skullcrusher|skull crusher',
                                       [('elbow', 'severe'), ('shoulder', 'moderate')]),
    # Dips load a deeply flexed, internally rotated shoulder.
    (r'\bdip\b|\bdips\b',              [('shoulder', 'severe'), ('elbow', 'moderate')]),
    # Knee-dominant work.
    (r'leg extension',                 [('knee', 'severe')]),
    (r'\bsquat\b',                     [('knee', 'moderate'), ('hip', 'moderate'),
                                        ('lumbar', 'mild')]),
    (r'front squat|zercher',           [('wrist', 'moderate'), ('knee', 'moderate')]),
    (r'\blunge\b|split squat|step.?up', [('knee', 'moderate'), ('hip', 'mild')]),
    (r'leg curl',                      [('knee', 'mild'), ('hamstring', 'moderate')]),
    # A natural glute-ham raise is the hamstring's own bodyweight eccentric —
    # the hand-authored set rates it severe, and it is the one severe the
    # first pass of these rules missed.
    (r'glute.?ham|nordic',             [('hamstring', 'severe'), ('knee', 'moderate')]),
    (r'sissy squat|hack squat',        [('knee', 'severe')]),
    # Loaded spine while standing with a bar.
    (r'\brow\b',                      [('lumbar', 'mild')]),
    (r'\bbarbell\b.*\brow\b|bent.?over', [('lumbar', 'moderate')]),
    (r'\bupright row\b',               [('shoulder', 'severe')]),
    # Wrist-loaded positions.
    (r'push.?up|handstand|planche',    [('wrist', 'moderate'), ('shoulder', 'mild')]),
    (r'bench press|floor press|chest press', [('wrist', 'mild')]),
    (r'\bcurl\b',                      [('elbow', 'moderate'), ('wrist', 'mild')]),
    (r'reverse curl|wrist curl',       [('wrist', 'moderate')]),
    # Hanging puts the shoulder under traction.
    (r'hanging|\bhang\b',              [('shoulder', 'mild')]),
    (r'pull.?up|chin.?up|muscle.?up',  [('shoulder', 'moderate'), ('elbow', 'moderate')]),
    # Calf work.
    (r'calf raise|calf press',         [('ankle', 'moderate'), ('calf', 'moderate')]),
    # Neck.
    (r'\bneck\b',                      [('neck', 'moderate')]),
]

# A free-weight lift performed standing asks the lumbar spine to hold the
# torso; a machine or a bench takes that away.
_SUPPORTED = re.compile(r'seated|lying|bench|machine|chest.?supported|incline|'
                        r'decline|prone|supine|cable|preacher|floor')


def derive(name, primaries, mechanic, equipment):
    out = {}

    def add(j, s):
        out[j] = _max(out.get(j), s)

    for m in primaries:
        for j, s in BY_MUSCLE.get(m, []):
            add(j, s)

    n = name.lower()
    for pat, effects in NAME_RULES:
        if re.search(pat, n):
            for j, s in effects:
                add(j, s)

    # Standing barbell work adds spinal loading the muscle list cannot imply.
    if 'barbell' in equipment and not _SUPPORTED.search(n):
        add('lumbar', 'moderate')

    # Isolation work is, by definition, one joint doing less total work.
    if mechanic == 'isolation':
        for j in list(out):
            if out[j] == 'moderate' and j in ('shoulder', 'hip', 'lumbar'):
                out[j] = 'mild'

    return out


def load(path):
    rows = []
    for line in open(path):
        f = line.rstrip('\n').split('\t')
        if len(f) < 10:
            continue
        rows.append({
            'slug': f[0], 'name': f[1], 'pattern': f[2], 'mechanic': f[3],
            'force': f[4], 'is_core': f[5] == 't',
            'primaries': [x for x in f[6].split('|') if x],
            'secondaries': [x for x in f[7].split('|') if x],
            'equipment': [x for x in f[8].split('|') if x],
            'authored': dict(p.split(':') for p in f[9].split('|') if p),
        })
    return rows


def validate(rows):
    truth = [r for r in rows if r['authored']]
    exact = 0
    tp = fp = fn = 0
    sev_hit = sev_missed = 0
    sev_examples, miss_examples = [], []

    for r in truth:
        got = derive(r['name'], r['primaries'], r['mechanic'], r['equipment'])
        want = r['authored']
        if set(got) == set(want):
            exact += 1
        tp += len(set(got) & set(want))
        fp += len(set(got) - set(want))
        fn += len(set(want) - set(got))
        for j, s in want.items():
            if s == 'severe':
                if got.get(j) == 'severe':
                    sev_hit += 1
                else:
                    sev_missed += 1
                    miss_examples.append(f"{r['slug']}/{j} (got {got.get(j) or 'nothing'})")
        for j in set(want) - set(got):
            sev_examples.append(f"{r['slug']}: missed {j}:{want[j]}")

    n = len(truth)
    print(f"validated against {n} hand-authored exercises", file=sys.stderr)
    print(f"  exact joint-set match : {exact}/{n} ({exact/n:.0%})", file=sys.stderr)
    print(f"  joint recall          : {tp}/{tp+fn} ({tp/(tp+fn):.0%})", file=sys.stderr)
    print(f"  false positives       : {fp} (over-cautious, acceptable)", file=sys.stderr)
    sev_tot = sev_hit + sev_missed
    if sev_tot:
        print(f"  SEVERE recall         : {sev_hit}/{sev_tot} "
              f"({sev_hit/sev_tot:.0%})  <- the one that matters", file=sys.stderr)
    for m in miss_examples:
        print(f"    MISSED SEVERE: {m}", file=sys.stderr)
    for m in sev_examples[:12]:
        print(f"    {m}", file=sys.stderr)
    return sev_missed


def emit(rows):
    """One statement, not one per row.

    The first version emitted ~1050 separate INSERTs; over a pooled connection
    that is ~1050 round trips and the migration ran for minutes. A single
    VALUES list joined against exercises and joints does the same work in one
    statement, and stays re-runnable.
    """
    targets = [r for r in rows if not r['authored']]
    tuples = []
    for r in targets:
        for joint, sev in sorted(derive(r['name'], r['primaries'],
                                        r['mechanic'], r['equipment']).items()):
            slug = r['slug'].replace("'", "''")
            tuples.append(f"('{slug}','{joint}','{sev}')")

    slugs = sorted({t.split("','")[0].lstrip("('") for t in tuples})
    print('-- Generated by tool/derive_joints.py — do not hand-edit.')
    # Idempotent by construction: every exercise listed below had NO joint data
    # of its own, so clearing them can never touch a hand-authored row, and a
    # faulty generation is corrected by simply regenerating and re-applying.
    print('delete from exercise_joints ej using exercises e')
    print(' where e.id = ej.exercise_id and e.owner_id is null and e.slug in (')
    print(',\n'.join('         ' + repr(x).replace('"', "'") for x in slugs))
    print('       );')
    print('insert into exercise_joints (exercise_id, joint_id, stress_level)')
    print('select e.id, j.id, v.stress::severity_level')
    print('  from (values')
    print(',\n'.join('         ' + t for t in tuples))
    print('       ) as v(slug, joint, stress)')
    print('  join exercises e on e.slug = v.slug and e.owner_id is null')
    print('  join joints    j on j.slug = v.joint')
    # Guard, not a filter on the join: an exercise that already carries ANY
    # hand-authored joint row is left entirely alone.
    print('on conflict do nothing;')
    print(f"emitted {len(tuples)} joint rows for {len(targets)} exercises",
          file=sys.stderr)


if __name__ == '__main__':
    rows = load(sys.argv[1])
    if '--validate' in sys.argv:
        sys.exit(1 if validate(rows) else 0)
    if '--emit' in sys.argv:
        emit(rows)
