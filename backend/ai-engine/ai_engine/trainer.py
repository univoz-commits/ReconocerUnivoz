"""Adaptación 152D del entrenador SVM de UNIVOZ."""

import json
from pathlib import Path
from typing import Dict, List, Tuple

from .classifier import flatten_sequence
from .contract import NORM_VERSION, MotionSequenceV2

MIN_CLASSES = 3
MIN_SAMPLES_PER_CLASS = 5


def can_train(sample_store: Dict[str, List[MotionSequenceV2]]) -> Tuple[bool, str]:
    if len(sample_store) < MIN_CLASSES:
        return False, f'Need >= {MIN_CLASSES} classes, have {len(sample_store)}'
    low = [label for label, samples in sample_store.items()
           if len(samples) < MIN_SAMPLES_PER_CLASS]
    if low:
        return False, f'Classes {low} have < {MIN_SAMPLES_PER_CLASS} samples each'
    return True, 'ok'


def train_svm(sample_store: Dict[str, List[MotionSequenceV2]], output_dir: Path,
              *, model_version: str = 'svm-v2'):
    """Entrena SVM dinámico sobre 32x152 aplanado.

    numpy/scikit-learn/joblib son dependencias del servicio, importadas aquí
    para que validación y fallback kNN funcionen sin ellas.
    """
    ok, reason = can_train(sample_store)
    if not ok:
        return {'trained': False, 'reason': reason}

    try:
        import joblib
        import numpy as np
        from sklearn.model_selection import StratifiedKFold, cross_val_score
        from sklearn.pipeline import Pipeline
        from sklearn.preprocessing import LabelEncoder, StandardScaler
        from sklearn.svm import SVC
    except ImportError as error:
        return {'trained': False, 'reason': f'SVM dependencies missing: {error}'}

    rows, labels = [], []
    for label, sequences in sample_store.items():
        for sequence in sequences:
            rows.append(flatten_sequence(sequence))
            labels.append(label)
    x = np.asarray(rows, dtype=np.float32)
    encoder = LabelEncoder()
    y = encoder.fit_transform(labels)
    folds = min(5, min(len(samples) for samples in sample_store.values()))
    pipeline = Pipeline([
        ('scaler', StandardScaler()),
        ('svc', SVC(kernel='rbf', C=10.0, gamma='scale', probability=True)),
    ])
    scores = cross_val_score(
        pipeline, x, y,
        cv=StratifiedKFold(n_splits=folds, shuffle=True, random_state=42),
        scoring='accuracy',
    )
    pipeline.fit(x, y)

    output_dir.mkdir(parents=True, exist_ok=True)
    joblib.dump(pipeline, output_dir / 'svm_dynamic.joblib')
    joblib.dump(encoder, output_dir / 'label_encoder_dynamic.joblib')
    metadata = {
        'model_version': model_version,
        'norm_version': NORM_VERSION,
        'frame_dim': 152,
        't_frames': 32,
        'classes': sorted(str(label) for label in encoder.classes_),
    }
    (output_dir / 'model_metadata.json').write_text(
        json.dumps(metadata, indent=2) + '\n', encoding='utf-8'
    )
    return {
        'trained': True,
        **metadata,
        'n_samples': len(rows),
        'cv_accuracy_mean': round(float(scores.mean()), 4),
        'cv_accuracy_std': round(float(scores.std()), 4),
        'cv_folds': folds,
    }
