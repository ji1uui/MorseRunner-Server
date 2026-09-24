"""Make a fixed 30-cell clean-audio study plan from a reviewed corpus JSON."""
import argparse
import hashlib
import json
import random
from pathlib import Path

BANDS = [(5, 9), (10, 19), (20, 29), (30, 39), (40, 60)]
PITCHES = [(200, 499), (500, 899), (900, 1200)]


def main():
    cli = argparse.ArgumentParser()
    cli.add_argument('corpus', type=Path)
    cli.add_argument('output', type=Path)
    cli.add_argument('--seed', type=int, default=20260924)
    cli.add_argument('--repetitions', type=int, default=1)
    a = cli.parse_args()
    if not (1 <= a.repetitions <= 100):
        raise ValueError('Repetitions must be 1..100')
    raw = a.corpus.read_bytes()
    corpus = json.loads(raw.decode('utf-8'))
    if corpus.get('schema_version') != 'teacher-corpus-1':
        raise ValueError('Unknown corpus version')
    sources = {}
    groups = {}
    for row in corpus['items']:
        if row['mode'] not in ('international', 'wabun'):
            raise ValueError('Corpus mode must be international or wabun')
        if not row['text'] or not row['group_id']:
            raise ValueError('Text and group_id are required')
        key = (row['mode'], row['text'])
        if key in sources and sources[key] != row['group_id']:
            raise ValueError('Identical text has different group ids')
        sources[key] = row['group_id']
        groups.setdefault(row['mode'], []).append(row)
    if any(not groups.get(m) for m in ('international', 'wabun')):
        raise ValueError('Both languages require corpus items')
    rng = random.Random(a.seed)
    items = []
    for mode in ('international', 'wabun'):
        for band, (lo, hi) in enumerate(BANDS):
            for pitch_band, (plo, phi) in enumerate(PITCHES):
                for repetition in range(a.repetitions):
                    source = groups[mode][(band * 3 * a.repetitions + pitch_band * a.repetitions + repetition) % len(groups[mode])]
                    group = source['group_id']
                    split_bucket = int.from_bytes(hashlib.sha256(group.encode('utf-8')).digest()[:4], 'big') % 10
                    split = 'train' if split_bucket < 8 else 'validation' if split_bucket == 8 else 'test'
                    start = rng.randint(lo * 1000, hi * 1000)
                    end = rng.randint(max(lo * 1000, start - 1000), min(hi * 1000, start + 1000))
                    items.append(dict(group_id=group, split=split, cell=f'{mode}:{band}:{pitch_band}',
                                      category=source.get('category', 'unspecified'),
                                      config=dict(schema_version='0.3', mode=mode, timing_profile='standard_v2',
                                                  text=source['text'], wpm=start / 1000, wpm_end=end / 1000,
                                                  pitch_hz=rng.randint(plo, phi), amplitude=12000,
                                                  chunk_seconds=60, gap_scale_milli=rng.randint(1000, 1400),
                                                  jitter_milli=rng.randint(0, 50), seed=rng.randint(1, 2147483647))))
    plan = dict(schema_version='teacher-batch-1', plan_generator='prepare_teacher_plan_v1',
                corpus_sha256=hashlib.sha256(raw).hexdigest(), seed=a.seed, items=items)
    a.output.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'Wrote {len(items)} sessions in {len(set(x["cell"] for x in items))} cells to {a.output}')


if __name__ == '__main__':
    main()
