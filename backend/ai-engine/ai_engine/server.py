"""API opcional de inferencia backend para ReconocerUnivoz."""

import json
import os
from pathlib import Path
from typing import List, Optional

from .classifier import MotionClassifier
from .contract import ContractError, FRAME_DIM, NORM_VERSION, T_FRAMES


def load_engine(model_dir: Optional[Path] = None) -> MotionClassifier:
    """Carga modelo SVM compatible; si no existe, deja fallback kNN activo.

    Modelos serializados son artefactos locales del backend, nunca datos que
    lleguen desde APK. Un modelo ausente o incompatible no tumba el servicio:
    clasificador conserva operación con muestras/prototipos cargados por el
    proceso que lo use.
    """
    engine = MotionClassifier()
    directory = Path(model_dir or os.environ.get('AI_ENGINE_MODEL_DIR', 'models'))
    metadata_path = directory / 'model_metadata.json'
    pipeline_path = directory / 'svm_dynamic.joblib'
    encoder_path = directory / 'label_encoder_dynamic.joblib'
    if metadata_path.is_file() and pipeline_path.is_file() and encoder_path.is_file():
        try:
            metadata = json.loads(metadata_path.read_text(encoding='utf-8'))
            if (metadata.get('norm_version') == NORM_VERSION and
                    metadata.get('frame_dim') == FRAME_DIM and
                    metadata.get('t_frames') == T_FRAMES):
                import joblib
                pipeline = joblib.load(pipeline_path)
                encoder = joblib.load(encoder_path)
                version = str(metadata.get('model_version') or 'svm-v2')
                engine.set_svm(pipeline, encoder, model_version=version)
                return engine
        except Exception:
            # Artefacto incompleto/incompatible: continuar con fallback.
            pass

    # Sin artefacto SVM, usar muestras aprobadas si backend tiene DATABASE_URL.
    # Si base no está disponible, endpoint sigue vivo y devuelve rechazo limpio.
    if os.environ.get('DATABASE_URL'):
        try:
            from .data import approved_sequences, connect_database
            conn = connect_database()
            try:
                grouped, _ = approved_sequences(conn)
            finally:
                conn.close()
            for label, sequences in grouped.items():
                for sequence in sequences:
                    engine.add_sample(label, sequence)
        except Exception:
            pass
    return engine


def create_app(classifier: Optional[MotionClassifier] = None):
    try:
        from fastapi import FastAPI, HTTPException
        from pydantic import BaseModel
    except ImportError as error:
        raise RuntimeError(
            'Instala backend/ai-engine/requirements.txt para levantar API'
        ) from error

    class ClassifyRequest(BaseModel):
        norm_version: str = NORM_VERSION
        frames: List[List[float]]

    app = FastAPI(title='ReconocerUnivoz AI Engine', version=NORM_VERSION)
    engine = classifier or load_engine()

    @app.get('/health')
    def health():
        return {
            'status': 'ok',
            'norm_version': NORM_VERSION,
            'frame_dim': FRAME_DIM,
            't_frames': T_FRAMES,
        }

    @app.post('/v1/classify')
    def classify(payload: ClassifyRequest):
        try:
            prediction = engine.classify(
                payload.frames,
                norm_version=payload.norm_version,
            )
        except ContractError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error
        return prediction.to_json()

    return app


try:
    app = create_app()
except RuntimeError:
    app = None


if __name__ == '__main__':
    if app is None:
        raise SystemExit('Instala requirements.txt para ejecutar uvicorn')
    import uvicorn
    uvicorn.run('ai_engine.server:app', host='127.0.0.1', port=8000)
