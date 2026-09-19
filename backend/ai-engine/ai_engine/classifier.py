"""Clasificación sobre secuencias MotionSequenceV2.

SVM se conecta cuando existe modelo entrenado. Fallback siempre disponible:
kNN sobre secuencias y centroide. La app móvil conserva DTW offline.
"""

import math
from collections import defaultdict
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Tuple

from .contract import ContractError, MotionSequenceV2


@dataclass(frozen=True)
class Prediction:
    label: Optional[str]
    confidence: float
    classifier: str
    model_version: str

    def to_json(self):
        return {
            'label': self.label,
            'confidence': round(float(self.confidence), 4),
            'classifier': self.classifier,
            'model_version': self.model_version,
        }


def flatten_sequence(sequence: MotionSequenceV2) -> List[float]:
    return [value for frame in sequence.frames for value in frame]


def _distance(a: Iterable[float], b: Iterable[float]) -> float:
    values = [(x - y) ** 2 for x, y in zip(a, b)]
    return math.sqrt(sum(values) / max(1, len(values)))


class MotionClassifier:
    def __init__(self, *, model_version: str = 'baseline-v2', k: int = 5,
                 max_distance: float = 1.5):
        self.model_version = model_version
        self.k = max(1, k)
        self.max_distance = max_distance
        self._samples: Dict[str, List[MotionSequenceV2]] = defaultdict(list)
        self._prototypes: Dict[str, MotionSequenceV2] = {}
        self._svm = None
        self._encoder = None

    def add_sample(self, label: str, sequence,
                   *, norm_version: str = '2.0.0') -> None:
        self._samples[str(label)].append(
            sequence if isinstance(sequence, MotionSequenceV2)
            else MotionSequenceV2(sequence, norm_version=norm_version)
        )

    def add_prototype(self, label: str, sequence,
                      *, norm_version: str = '2.0.0') -> None:
        self._prototypes[str(label)] = (
            sequence if isinstance(sequence, MotionSequenceV2)
            else MotionSequenceV2(sequence, norm_version=norm_version)
        )

    def set_svm(self, pipeline, encoder, *, model_version: str) -> None:
        self._svm = pipeline
        self._encoder = encoder
        self.model_version = model_version

    def classify(self, frames, *, norm_version: str = '2.0.0') -> Prediction:
        sequence = (frames if isinstance(frames, MotionSequenceV2) else
                    MotionSequenceV2(frames, norm_version=norm_version))
        query = flatten_sequence(sequence)

        if self._svm is not None and self._encoder is not None:
            scores = self._predict_svm(query)
            return self._prediction_from_scores(scores, 'svm')

        if self._samples:
            scores = []
            for label, samples in self._samples.items():
                for sample in samples:
                    scores.append((_distance(query, flatten_sequence(sample)), label))
            scores.sort(key=lambda item: item[0])
            top = scores[:self.k]
            votes: Dict[str, List[float]] = defaultdict(list)
            for distance, label in top:
                votes[label].append(distance)
            ranked = sorted(
                ((sum(distances) / len(distances), label, len(distances))
                 for label, distances in votes.items()),
                key=lambda item: (-item[2], item[0]),
            )
            distance, label, _ = ranked[0]
            confidence = max(0.0, min(1.0, 1.0 / (1.0 + distance)))
            if distance > self.max_distance:
                label = None
            return Prediction(label, confidence, 'knn', self.model_version)

        if self._prototypes:
            ranked = sorted(
                (_distance(query, flatten_sequence(sequence)), label)
                for label, sequence in self._prototypes.items()
            )
            distance, label = ranked[0]
            confidence = max(0.0, min(1.0, 1.0 / (1.0 + distance)))
            if distance > self.max_distance:
                label = None
            return Prediction(label, confidence, 'centroid', self.model_version)

        return Prediction(None, 0.0, 'knn', self.model_version)

    def _predict_svm(self, query: List[float]):
        probabilities = self._svm.predict_proba([query])[0]
        return sorted(
            ((float(probability), str(self._encoder.classes_[index]))
             for index, probability in enumerate(probabilities)),
            reverse=True,
        )

    def _prediction_from_scores(self, scores: List[Tuple[float, str]], kind: str):
        if not scores:
            return Prediction(None, 0.0, kind, self.model_version)
        confidence, label = scores[0]
        return Prediction(label, max(0.0, min(1.0, confidence)), kind,
                          self.model_version)
