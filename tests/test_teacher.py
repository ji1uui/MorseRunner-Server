"""Independent integration oracle, Python standard library only. Build tools first."""
import base64
import hashlib
import json
import math
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'lib' / 'teacher'
EXE = '.exe' if os.name == 'nt' else ''
RUN = Path(tempfile.mkdtemp(prefix='teacher-', dir=ROOT / 'lib'))


def run(tool, *args, expect=0, env=None):
    p = subprocess.run([str(BIN / (tool + EXE)), *map(str, args)],
                       capture_output=True, text=True, encoding='utf-8', env=env)
    assert p.returncode == expect, (tool, p.returncode, p.stdout, p.stderr)
    return p


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def rows(path):
    return [json.loads(s) for s in path.read_text(encoding='utf-8').splitlines()]


def config(text='EE T', wpm=20, chunk=60):
    return dict(schema_version='0.2', mode='international', timing_profile='standard_v1',
                text=text, wpm=wpm, pitch_hz=700, amplitude=12000, chunk_seconds=chunk)


def generate(name, c):
    path = RUN / (name + '.json')
    path.write_text(json.dumps(c), encoding='utf-8')
    out = RUN / name
    run('export_teacher', path, out)
    run('validate_dataset', out)
    m = read(out / 'manifest.json')
    expected_code = base64.b32encode(uuid.UUID(m['session_id']).bytes).decode().lower().rstrip('=')
    assert m['session_code'] == expected_code
    assert uuid.UUID(m['session_id']).version == 4
    pcm = bytearray()
    for entry in m['files']:
        data = (out / entry['path']).read_bytes()
        assert entry['sha256'] == hashlib.sha256(data).hexdigest()
        assert entry['byte_count'] == len(data)
        if entry.get('role') == 'r':
            assert len(entry['path']) == 42
            assert entry['global_start_sample'] == len(pcm) // 2
            with wave.open(str(out / entry['path']), 'rb') as f:
                assert (f.getnchannels(), f.getframerate(), f.getsampwidth()) == (1, 22050, 2)
                assert f.getnframes() == entry['sample_count']
                pcm.extend(f.readframes(f.getnframes()))
    assert len(pcm) // 2 == m['session_sample_count']
    return out, m, bytes(pcm)


def corrupt(name, source, fn):
    dest = RUN / name
    shutil.copytree(source, dest)
    fn(dest)
    run('validate_dataset', dest, expect=4)


run('teacher_primitives')
# Explicit reference schedule for EE T: E, letter gap, E, word gap, T, tail.
units = [1, 3, 1, 7, 3, 3]
kinds = ['dit', 'character_gap', 'dit', 'word_gap', 'dah', 'trailing_gap']
for speed in (5, 10, 17.321, 20, 30, 40, 56, 60):
    out, m, pcm = generate('speed-' + str(speed), config(wpm=speed))
    events = rows(out / 'symbols.jsonl')
    assert [e['kind'] for e in events] == kinds
    numerator = 0
    denominator = round(speed * 1000)
    for event, count in zip(events, units):
        assert event['start_sample'] == (numerator + denominator // 2) // denominator
        numerator += count * 22050 * 1200
        assert event['end_sample'] == (numerator + denominator // 2) // denominator
        for offset in (0, 55, 110):
            sample = event['start_sample'] + offset
            env = (0.5 - 0.5*math.cos(math.pi*offset/110)) if event['kind'] in ('dit','dah') else (0.5 + 0.5*math.cos(math.pi*offset/110))
            expected = round(12000*env*math.cos(2*math.pi*700*sample/22050))
            actual = int.from_bytes(pcm[2*sample:2*sample+2], 'little', signed=True)
            assert abs(expected-actual)<=1
        if event['kind'] in ('dit', 'dah'):
            mid = (event['start_sample'] + event['end_sample']) // 2
            value = int.from_bytes(pcm[2*mid:2*mid+2], 'little', signed=True)
            expected = round(12000 * math.cos(2 * math.pi * 700 * mid / 22050))
            assert abs(value - expected) <= 1
    assert all(abs(int.from_bytes(pcm[-2*i:-2*i+2 or None], 'little', signed=True)) == 0 for i in range(1, 20))

# Non-integer unit length over many characters: final extent must not drift.
out, _, _ = generate('cumulative', config('E' * 600, 17.321))
end = rows(out / 'symbols.jsonl')[-1]['end_sample']
assert end == (2400 * 22050 * 1200 + 17321 // 2) // 17321

# Independent full symbol subset mapping, transcribed as fixed test fixtures.
symbols = dict(zip('ABCDEFGHIJKLMNOPQRSTUVWXYZ',
                  '.- -... -.-. -.. . ..-. --. .... .. .--- -.- .-.. -- -. --- .--. --.- .-. ... - ..- ...- .-- -..- -.-- --..'.split()))
symbols.update(dict(zip('0123456789', '----- .---- ..--- ...-- ....- ..... -.... --... ---.. ----.'.split())))
symbols.update({'/': '-..-.', '.': '.-.-.-', ',': '--..--', '?': '..--..', '=': '-...-'})
out, _, _ = generate('alphabet', config(''.join(symbols), 60))
for token in rows(out / 'tokens.jsonl'):
    assert token['morse_pattern'] == symbols[token['emitted_value']]

# File splitting may bisect a mark. PCM and physical labels remain unchanged.
a, ma, pa = generate('whole', config('0000 EE TEST', 5, 60))
b, mb, pb = generate('split', config('0000 EE TEST', 5, 1))
assert pa == pb
assert ma['session_id'] != mb['session_id']
assert [(e['kind'], e['start_sample'], e['end_sample']) for e in rows(a/'symbols.jsonl')] == [
    (e['kind'], e['start_sample'], e['end_sample']) for e in rows(b/'symbols.jsonl')]

# Parameter and input failures occur before an output directory is created.
bad = [dict(text='a'), dict(text='ア'), dict(text=' E'), dict(text='E '), dict(text='E  E'),
       dict(text=''), dict(text='E'*65537), dict(wpm=0), dict(wpm=60.001), dict(wpm=20.0001),
       dict(pitch_hz=1201), dict(pitch_hz=4294967996), dict(amplitude=0), dict(chunk_seconds=0), dict(extra=True), dict(wpm='20'), dict(wpm=20.0000000001)]
for i, change in enumerate(bad):
    c = config(); c.update(change)
    p = RUN / f'bad-{i}.json'; p.write_text(json.dumps(c), encoding='utf-8')
    d = RUN / f'bad-{i}'
    run('export_teacher', p, d, expect=2)
    assert not d.exists()

for i, text in enumerate([json.dumps(config())+' {}', json.dumps(config()).replace('"', "'"),
                          json.dumps(config()).replace('"wpm": 20', '"wpm": 20, "wpm": 30')]):
    p=RUN/f'malformed-{i}.json'; p.write_text(text,encoding='utf-8')
    run('export_teacher',p,RUN/f'malformed-{i}',expect=2)
generate('日本語フォルダ',config('TEST'))
path_config=RUN/'whole.json'
path_output=RUN/'path-invocation'
path_env=dict(os.environ, PATH=str(BIN)+os.pathsep+os.environ.get('PATH',''))
via_path=subprocess.run(['cmd.exe','/d','/c','export_teacher.exe',str(path_config),str(path_output)],cwd=RUN,
                        capture_output=True,text=True,encoding='utf-8',env=path_env)
assert via_path.returncode==0, (via_path.stdout,via_path.stderr)
assert read(path_output/'manifest.json')['generator_binary_sha256']==hashlib.sha256((BIN/'export_teacher.exe').read_bytes()).hexdigest()
run('validate_dataset',path_output)
raw_unicode=RUN/'raw-unicode.json'
raw_unicode.write_text(json.dumps(config('ア'),ensure_ascii=False),encoding='utf-8')
run('export_teacher',raw_unicode,RUN/'raw-unicode',expect=2)

# Excessive subdivision is rejected before publishing a manifest too large to read.
many=RUN/'too-many-parts.json'; many.write_text(json.dumps(config('0'*65536,5,1)))
run('export_teacher',many,RUN/'too-many-parts',expect=3)
assert not (RUN/'too-many-parts').exists()

run('export_teacher', RUN/'whole.json', a, expect=3)
assert pa == b''.join((a / e['path']).read_bytes()[44:] for e in ma['files'] if e.get('role') == 'r')
longdir = RUN / ('x'*120) / ('y'*120)
run('export_teacher', RUN/'whole.json', longdir, expect=3)
assert not longdir.exists()

def change_manifest(d):
    m = read(d/'manifest.json'); m['complete'] = False
    (d/'manifest.json').write_text(json.dumps(m))

def change_hash(d):
    m = read(d/'manifest.json'); m['files'][0]['sha256'] = '0'*64
    (d/'manifest.json').write_text(json.dumps(m))

def change_audio(d):
    m = read(d/'manifest.json'); p = d/m['files'][0]['path']
    data = bytearray(p.read_bytes()); data[1000] ^= 1; p.write_bytes(data)

def change_label(d):
    events = rows(d/'symbols.jsonl'); events[0]['end_sample'] += 1
    (d/'symbols.jsonl').write_text('\n'.join(map(json.dumps,events))+'\n')

def missing_provenance(d):
    m=read(d/'manifest.json'); del m['source_commit']; (d/'manifest.json').write_text(json.dumps(m))

for name, mutation in [('incomplete',change_manifest), ('bad-hash',change_hash),
                       ('oversize-line',lambda d:(d/'symbols.jsonl').write_bytes(b' '*1048577+b'\n')),
                       ('bad-audio',change_audio), ('bad-label',change_label),
                       ('missing-source',missing_provenance),
                       ('missing-tokens',lambda d:(d/'tokens.jsonl').unlink())]:
    corrupt(name,a,mutation)

# Concurrent directory ownership: exactly one process may publish.
command = [str(BIN/('export_teacher'+EXE)),str(RUN/'whole.json'),str(RUN/'concurrent')]
ps = [subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE) for _ in range(2)]
for p in ps: p.communicate()
assert sorted(p.returncode for p in ps)==[0,3]
run('validate_dataset',RUN/'concurrent')

# Build-only injected I/O fault must not produce a completed manifest.
assert (BIN/('export_teacher_fault'+EXE)).exists(), 'Build fault-test binary before running tests'
env=dict(os.environ, TEACHER_TEST_FAIL_WRITE='5')
run('export_teacher_fault', RUN/'whole.json', RUN/'write-failure', expect=3, env=env)
assert not (RUN/'write-failure'/'manifest.json').exists()
run('validate_dataset',RUN/'write-failure',expect=4)

# Abrupt process termination leaves no complete dataset.
cancel_config=RUN/'cancel.json'; cancel_config.write_text(json.dumps(config('0'*65536,5,60)))
cancel_dir=RUN/'cancelled'
p=subprocess.Popen([str(BIN/('export_teacher'+EXE)),str(cancel_config),str(cancel_dir)],
                   stdout=subprocess.PIPE,stderr=subprocess.PIPE)
try:
    deadline=time.monotonic()+10
    while not list(cancel_dir.glob('*.wav')) and p.poll() is None and time.monotonic()<deadline:
        time.sleep(0.01)
    assert p.poll() is None and list(cancel_dir.glob('*.wav')), 'Could not reach active writer'
    p.kill(); p.communicate()
finally:
    if p.poll() is None: p.kill(); p.communicate()
assert not (cancel_dir/'manifest.json').exists()
run('validate_dataset',cancel_dir,expect=4)

# Verified migration retains the original WAV bytes, including legacy padding.
for speed in (5,17,20,56,60):
    old=RUN/f'legacy-{speed}'; new=RUN/f'migrated-{speed}'
    run('export_sample',old,'EE  5NN TEST /?= 000 EEEEE',speed,700)
    run('migrate_dataset',old,new)
    run('validate_dataset',new)
    m=read(new/'manifest.json')
    assert m['timing_profile']=='upstream_keyer_legacy'
    assert m['migration']['original_provenance']=='unknown'
    assert (old/'received.wav').read_bytes()==(new/m['files'][0]['path']).read_bytes()
    run('validate_dataset',old,expect=4)

# A physical record corrupted in the old data must not be silently regenerated.
old=RUN/'legacy-20'; events=rows(old/'symbols.jsonl'); events[0]['morse_index_1based']=999
(old/'symbols.jsonl').write_text('\n'.join(map(json.dumps,events))+'\n')
run('migrate_dataset',old,RUN/'invalid-migration',expect=3)
assert not (RUN/'invalid-migration').exists()

# One-hour generation is intentionally offline; it is not a live-input test.
start=time.perf_counter()
hour, mh, _ = generate('hour', config('E'*15000, 20, 60))
elapsed=time.perf_counter()-start
assert mh['session_sample_count']==3600*22050
report=dict(passed=True, evidence=str(RUN), hour_generate_and_validate_seconds=elapsed,
            hour_generate_and_validate_rtf=elapsed/3600, live_audio_test=False)
(RUN/'test-report.json').write_text(json.dumps(report,indent=2))
(BIN/'last-test.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
