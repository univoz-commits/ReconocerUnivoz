# ReconocerUnivoz AI Engine

Backend opcional. Consume únicamente `MotionSequenceV2`: 32 frames × 152
valores, `norm_version=2.0.0`.

No copia frontend React ni esquema antiguo de UNIVOZ. Flutter mantiene DTW
offline; este servicio agrega SVM/kNN/centroide cuando existe conectividad.

```bash
cd backend/ai-engine
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
PYTHONPATH=. python -m ai_engine.server
```

Endpoints:

- `GET /health`
- `POST /v1/classify` con `{ "norm_version": "2.0.0", "frames": [[...]] }`

SVM se entrena con `ai_engine.trainer.train_svm` usando muestras aprobadas
leídas por herramientas del proyecto. Modelos se guardan fuera del APK.
