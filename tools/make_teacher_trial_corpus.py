"""Deterministic synthetic text corpus for a P2 training-pipeline trial.

The output exercises splits and distributions; it is not a real-reception corpus.
"""
import argparse
import json
import random
import string
from pathlib import Path

KANA = 'イロハニホヘトチリヌルヲワカヨタレソツネナラムウヰノオクヤマケフコエテアサキユメミシヱヒモセスン'
GREETINGS = [
    'こんにちは、よろしくおねがいします', 'おはようございます', 'こんばんは',
    'きょうのてんきははれ', 'こちらはとうきょうです',
    'でんぱはよくきこえます', 'ありがとう、またおあいしましょう',
    'こちらのなまえはたろうです', 'しんごうはつよくとどいています',
    'つぎのこうしんをたのしみにしています',
]
ENGLISH = ['CQ CQ DE', 'UR RST 5NN', 'QTH TOKYO', 'TNX FER QSO', 'WX FINE',
           'PSE QRS', 'TEST TEST', 'HW CPY', 'NAME TARO', '73 TU']


def main():
    cli = argparse.ArgumentParser()
    cli.add_argument('output', type=Path)
    cli.add_argument('--seed', type=int, default=20260924)
    cli.add_argument('--groups-per-mode', type=int, default=100)
    a = cli.parse_args()
    if not 30 <= a.groups_per_mode <= 1000:
        raise ValueError('Use 30..1000 groups per mode')
    rng = random.Random(a.seed)
    records = []
    for mode in ('international', 'wabun'):
        used = set()
        for n in range(a.groups_per_mode):
            while True:
                if mode == 'international':
                    call = rng.choice(('JA', 'JE', 'JH', 'JF', 'JR', 'JM', 'JI')) + str(rng.randint(0, 9)) + ''.join(rng.choices(string.ascii_uppercase, k=3))
                    if n % 3 == 0:
                        text = rng.choice(ENGLISH) + ' ' + call + ' {AR}'
                        category = 'qso'
                    elif n % 3 == 1:
                        text = ' '.join(''.join(rng.choices(string.ascii_uppercase + string.digits, k=5)) for _ in range(3))
                        category = 'random_groups'
                    else:
                        text = call + ' ' + rng.choice(('RST 5NN', 'QTH TOKYO', '73 TU', 'PSE QRS'))
                        category = 'callsign'
                else:
                    if n % 3 == 0:
                        text = rng.choice(GREETINGS) + '、' + ''.join(rng.choices(KANA, k=5))
                        category = 'phrase'
                    elif n % 3 == 1:
                        text = ''.join(rng.choices(KANA, k=rng.randint(12, 25)))
                        category = 'random_kana'
                    else:
                        text = rng.choice(('がぎぐげご', 'ぱぴぷぺぽ', 'ざじずぜぞ', 'だぢづでど')) + ''.join(rng.choices(KANA, k=8))
                        category = 'diacritics'
                if text not in used:
                    used.add(text)
                    break
            records.append(dict(group_id=f'{mode[:3]}-{n+1:04d}', mode=mode,
                                category=category, text=text))
    rng.shuffle(records)
    corpus = dict(schema_version='teacher-corpus-1', generator='make_teacher_trial_corpus_v1',
                  seed=a.seed, items=records)
    a.output.write_text(json.dumps(corpus, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'Wrote {len(records)} synthetic records to {a.output}')


if __name__ == '__main__':
    main()
