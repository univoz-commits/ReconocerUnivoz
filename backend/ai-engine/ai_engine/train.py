"""CLI de entrenamiento SVM con muestras aprobadas del esquema UNIVOZ."""

import argparse
import json
from pathlib import Path

from .contract import MotionSequenceV2
from .data import approved_sequences, connect_database
from .trainer import train_svm


def _from_json(path: Path):
    raw = json.loads(path.read_text(encoding='utf-8'))
    if (raw.get('norm_version') not in (None, '2.0.0') or
            raw.get('frame_dim') not in (None, 152) or
            raw.get('t_frames') not in (None, 32)):
        raise ValueError('input JSON incompatible con MotionSequenceV2')
    grouped = {}
    for row in raw.get('plantillas', raw.get('muestras', [])):
        label = row['gloss']
        frames = row.get('seq') or row.get('frames')
        grouped.setdefault(label, []).append(MotionSequenceV2(frames))
    return grouped


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--input-json', type=Path)
    parser.add_argument('--output', type=Path, default=Path('models'))
    parser.add_argument('--model-version', default='svm-v2')
    args = parser.parse_args(argv)

    if args.input_json:
        samples = _from_json(args.input_json)
    else:
        conn = connect_database()
        try:
            samples, _ = approved_sequences(conn)
        finally:
            conn.close()
    metrics = train_svm(samples, args.output, model_version=args.model_version)
    print(json.dumps(metrics, indent=2, ensure_ascii=False))
    return 0 if metrics.get('trained') else 1


if __name__ == '__main__':
    raise SystemExit(main())
