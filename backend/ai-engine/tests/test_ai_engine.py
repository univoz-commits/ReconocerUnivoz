import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))

from ai_engine.classifier import MotionClassifier  # noqa: E402
from ai_engine.contract import (  # noqa: E402
    FRAME_DIM,
    T_FRAMES,
    ContractError,
    MotionSequenceV2,
)
from ai_engine.data import decode_float16_sequence  # noqa: E402


def sequence(offset: float):
    return [
        [offset + frame * 0.01 + dim * 0.0001 for dim in range(FRAME_DIM)]
        for frame in range(T_FRAMES)
    ]


def test_sequence_contract_rejects_old_format():
    with pytest.raises(ContractError):
        MotionSequenceV2([[0.0] * 63 for _ in range(8)])


def test_classifier_uses_152d_sequences_and_returns_stable_result():
    classifier = MotionClassifier(model_version='baseline-v2')
    classifier.add_sample('A', sequence(0.0))
    classifier.add_sample('B', sequence(10.0))

    result = classifier.classify(sequence(0.02))

    assert result.label == 'A'
    assert result.classifier == 'knn'
    assert result.model_version == 'baseline-v2'
    assert 0.0 <= result.confidence <= 1.0


def test_classifier_rejects_mixed_sequence_version():
    classifier = MotionClassifier()
    with pytest.raises(ContractError):
        classifier.classify(
            sequence(0.0),
            norm_version='1.0.0',
        )


def test_data_loader_decodes_only_canonical_float16_shape():
    import struct

    raw = struct.pack('<%de' % (T_FRAMES * FRAME_DIM),
                      *([0.5] * (T_FRAMES * FRAME_DIM)))
    decoded = decode_float16_sequence(raw)

    assert len(decoded.frames) == T_FRAMES
    assert len(decoded.frames[0]) == FRAME_DIM
    assert decoded.frames[0][0] == pytest.approx(0.5)

    with pytest.raises(ContractError):
        decode_float16_sequence(raw[:-2])
