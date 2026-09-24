"""Independent P2 oracle for the official code tables and timing contract."""
import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'lib/teacher'
RUN = Path(tempfile.mkdtemp(prefix='teacher-p2-', dir=ROOT / 'lib'))


def config(text, mode='wabun', wpm=20, end=20, gap=1000, jitter=0, seed=123):
    return dict(schema_version='0.3', mode=mode, timing_profile='standard_v2',
                text=text, wpm=wpm, wpm_end=end, pitch_hz=700, amplitude=12000,
                chunk_seconds=1, gap_scale_milli=gap, jitter_milli=jitter, seed=seed)


def call(tool, *args, code=0):
    p = subprocess.run([str(BIN / (tool + '.exe')), *map(str, args)],
                       capture_output=True, text=True, encoding='utf-8')
    assert p.returncode == code, (p.returncode, p.stdout, p.stderr)


def generate(name, c):
    cpath = RUN / (name + '.json')
    cpath.write_text(json.dumps(c, ensure_ascii=False), encoding='utf-8')
    out = RUN / name
    call('export_teacher', cpath, out)
    call('validate_dataset', out)
    manifest = json.loads((out / 'manifest.json').read_text(encoding='utf-8'))
    tokens = [json.loads(line) for line in (out / 'tokens.jsonl').read_text(encoding='utf-8').splitlines()]
    events = [json.loads(line) for line in (out / 'symbols.jsonl').read_text(encoding='utf-8').splitlines()]
    pcm = bytearray()
    for f in manifest['files']:
        data = (out / f['path']).read_bytes()
        assert hashlib.sha256(data).hexdigest() == f['sha256']
        if f.get('role') == 'r':
            with wave.open(str(out / f['path']), 'rb') as wav:
                pcm.extend(wav.readframes(wav.getnframes()))
    assert len(pcm) // 2 == manifest['session_sample_count']
    return out, manifest, tokens, events, bytes(pcm)


# Table copied independently from e-Gov Annex 1 and checked against JARL's table.
kana = 'イロハニホヘトチリヌルヲワカヨタレソツネナラムウヰノオクヤマケフコエテアサキユメミシヱヒモセスン'
codes = '.- .-.- -... -.-. -.. . ..-.. ..-. --. .... -.--. .--- -.- .-.. -- -. --- ---. .--. --.- .-. ... - ..- .-..- ..-- .-... ...- .-- -..- -.-- --.. ---- -.--- .-.-- --.-- -.-.- -.-.. -..-- -...- ..-.- --.-. .--.. --..- -..-. .---. ---.- .-.-.'.split()
assert len(kana) == len(codes) == 48
out, m, tokens, events, pcm = generate('all-kana', config(kana))
assert [(t['emitted_value'], t['morse_pattern']) for t in tokens] == list(zip(kana, codes))
assert all(t['mode'] == 'wabun' for t in tokens)
assert m['symbol_table_id'] == 'international_wabun_v2'

punctuation = dict(zip('゛゜ー、。「」', '.. ..--. .--.- .-.-.- .-.-.. .-..-. -.--.-'.split()))
out, _, tokens, _, _ = generate('wabun-punctuation', config(''.join(punctuation)))
assert [(t['emitted_value'], t['morse_pattern']) for t in tokens] == list(punctuation.items())
_, _, tokens, _, _ = generate('wabun-digits', config('〇一二三四五六七八九１２３４５６７８９０'))
assert ''.join(t['emitted_value'] for t in tokens) == '01234567891234567890'
assert [t['morse_pattern'] for t in tokens[:10]] == [
    '-----', '.----', '..---', '...--', '....-', '.....', '-....', '--...', '---..', '----.']

latin = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/.,?=:' + "'" + '-()"+@'
latin_codes = ('.- -... -.-. -.. . ..-. --. .... .. .--- -.- .-.. -- -. --- .--. --.- .-. ... - ..- ...- .-- -..- -.-- --.. '
               '----- .---- ..--- ...-- ....- ..... -.... --... ---.. ----. '
               '-..-. .-.-.- --..-- ..--.. -...- ---... .----. -....- -.--. -.--.- .-..-. .-.-. .--.-.').split()
assert len(latin) == len(latin_codes) == 49
_, _, tokens, _, _ = generate('all-latin', config(latin, mode='international'))
assert [(t['emitted_value'], t['morse_pattern']) for t in tokens] == list(zip(latin, latin_codes))

out, _, tokens, _, _ = generate('voiced', config('ガパヴがぱ'))
assert [(t['emitted_value'], t['source_token_index']) for t in tokens] == [
    ('カ', 0), ('゛', 0), ('ハ', 1), ('゜', 1), ('ウ', 2), ('゛', 2),
    ('カ', 3), ('゛', 3), ('ハ', 4), ('゜', 4)]
assert [t['morse_pattern'] for t in tokens[:4]] == ['.-..', '..', '-...', '..--.']
all_voiced = 'ガギグゲゴザジズゼゾダヂヅデドバビブベボヴパピプペポ'
base_voiced = 'カキクケコサシスセソタチツテトハヒフヘホウハヒフヘホ'
_, _, tokens, _, _ = generate('all-voiced', config(all_voiced))
assert len(tokens) == 2 * len(all_voiced)
for i, (v, base) in enumerate(zip(all_voiced, base_voiced)):
    assert tokens[2*i]['emitted_value'] == base
    assert tokens[2*i]['source_token_index'] == i
    assert tokens[2*i+1]['emitted_value'] == ('゛' if i < 21 else '゜')
    assert tokens[2*i+1]['source_token_index'] == i

out, _, tokens, events, _ = generate('mixed', config('CQ {DO}ガパ{SN} DE {AR}', 'mixed'))
assert [t['emitted_value'] for t in tokens if t['token_type'] == 'prosign'] == ['{DO}', '{SN}', '{AR}']
assert [(t['mode'], t['morse_pattern']) for t in tokens if t['emitted_value'] in ('{DO}', '{SN}')] == [
    ('international', '-..---'), ('wabun', '...-.')]
assert [t['mode'] for t in tokens if t['emitted_value'] == 'カ'] == ['wabun']
assert [t['mode'] for t in tokens if t['emitted_value'] == 'D'] == ['international']
for t in tokens:
    marks = [e for e in events if e['event_id'] in t['event_ids']]
    assert len(marks) == len(t['morse_pattern'])
    assert t['start_sample'] == marks[0]['start_sample']
    assert t['end_sample'] == marks[-1]['end_sample']
_, _, raw_tokens, _, _ = generate('unknown-pattern', config('ア{RAW:--------}イ'))
assert raw_tokens[1]['token_type'] == 'undefined' and raw_tokens[1]['morse_pattern'] == '--------'

# With no variation, standard_v2 uses the same ideal cumulative schedule.
_, _, _, events, _ = generate('fixed', config('イイ', wpm=17.321, end=17.321))
# The assertion below uses every event's actual Morse units, avoiding a copy of the generator table.
unit_count = 0
for e in events:
    assert e['start_sample'] == (unit_count * 22050 * 1200 + 17321 // 2) // 17321
    if e['kind'] == 'dit' or e['kind'] == 'intra_character_gap':
        unit_count += 1
    elif e['kind'] in ('dah', 'character_gap', 'trailing_gap'):
        unit_count += 3
    else:
        unit_count += 7
    assert e['end_sample'] == (unit_count * 22050 * 1200 + 17321 // 2) // 17321

dynamic = config('ガギグゲゴパピプペポ', wpm=8.321, end=13.456, gap=1300, jitter=80, seed=2718)
a, ma, ta, ea, pa = generate('dynamic-a', dynamic)
b, mb, tb, eb, pb = generate('dynamic-b', dynamic)
assert pa == pb
assert [(e['kind'], e['start_sample'], e['end_sample']) for e in ea] == [
    (e['kind'], e['start_sample'], e['end_sample']) for e in eb]
assert ma['session_id'] != mb['session_id']
assert ma['seed'] == 2718 and ma['rng_algorithm'] == 'xorshift32_v1'
# Separate Python timing calculation including the documented PRNG and rounding.
clock_micro = 0
state = 2718
token_no = 0
for e in ea:
    speed = 8321 + (13456 - 8321) * token_no // (len(ta) - 1)
    factor = 1300 if e['kind'] in ('character_gap', 'word_gap') else 1000
    if e['kind'] != 'trailing_gap':
        state ^= (state << 13) & 0xffffffff
        state ^= state >> 17
        state ^= (state << 5) & 0xffffffff
        state &= 0xffffffff
        factor = (factor * (1000 - 80 + state % 161) + 500) // 1000
    count = {'dit': 1, 'dah': 3, 'intra_character_gap': 1,
             'character_gap': 3, 'word_gap': 7, 'trailing_gap': 3}[e['kind']]
    assert e['start_sample'] == (clock_micro + 500000) // 1000000
    clock_micro += (count * 22050 * 1200 * 1000000 * factor + speed * 500) // (speed * 1000)
    assert e['end_sample'] == (clock_micro + 500000) // 1000000
    if e['kind'] in ('character_gap', 'word_gap'):
        token_no += 1
changed = dict(dynamic, seed=2719)
_, _, _, _, pc = generate('dynamic-other-seed', changed)
assert pa != pc
assert all(e['end_sample'] > e['start_sample'] for e in ea)

for name, bad in [('unknown', config('あ🗾')), ('bad-switch', config('{SN}A', 'mixed')),
                  ('bare-latin', config('ABC')), ('repeat-space', config('ア  イ')),
                  ('bad-speed', config('ア', end=60.001)), ('bad-seed', config('ア', seed=0)),
                  ('assigned-raw', config('ア{RAW:.-}イ'))]:
    p = RUN / (name + '.json')
    p.write_text(json.dumps(bad, ensure_ascii=False), encoding='utf-8')
    call('export_teacher', p, RUN / name, code=2)
    assert not (RUN / name).exists()

# A different P2 corpus/seed is audited without using a generated expectation.
report = dict(passed=True, evidence=str(RUN), kana_count=len(kana),
              deterministic_pcm_sha256=hashlib.sha256(pa).hexdigest())
(RUN / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
