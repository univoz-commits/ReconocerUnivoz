"""Extrae landmarks (pose + manos) crudos de un video, frame por frame.

Usa los mismos dos modelos que el lado nativo (hand_landmarker.task,
pose_landmarker_lite.task) pero en RunningMode.VIDEO en vez de LIVE_STREAM:
aca no hay camara en vivo, así que se puede pedir el resultado de forma
sincronica, frame por frame, sin canales ni callbacks.

La salida (lista de (pose, pose_mundo, left, right) por frame) tiene EXACTAMENTE el
mismo formato que espera sign_norm.normalize_sequence -- es el mismo
"contrato" que ya usa el golden test entre Dart y Python.
"""

import cv2
import mediapipe as mp
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision


def _punto_pose(p):
    return [p.x, p.y, p.z, p.visibility]


def _punto_mano(p):
    return [p.x, p.y, p.z]


def _punto_pose_mundo(p):
    return [p.x, p.y, p.z]


class ExtractorLandmarks:
    def __init__(
        self,
        pose_model_path,
        hand_model_path,
        min_pose_conf=0.5,
        min_hand_conf=0.5,
        min_tracking_conf=0.5,
    ):
        base = mp_python.BaseOptions
        self.pose = vision.PoseLandmarker.create_from_options(
            vision.PoseLandmarkerOptions(
                base_options=base(model_asset_path=pose_model_path),
                running_mode=vision.RunningMode.VIDEO,
                num_poses=1,
                min_pose_detection_confidence=min_pose_conf,
                min_pose_presence_confidence=min_pose_conf,
                min_tracking_confidence=min_tracking_conf,
            )
        )
        self.hands = vision.HandLandmarker.create_from_options(
            vision.HandLandmarkerOptions(
                base_options=base(model_asset_path=hand_model_path),
                running_mode=vision.RunningMode.VIDEO,
                num_hands=2,
                min_hand_detection_confidence=min_hand_conf,
                min_hand_presence_confidence=min_hand_conf,
                min_tracking_confidence=min_tracking_conf,
            )
        )
        # Los modelos en RunningMode.VIDEO exigen timestamps estrictamente
        # crecientes durante TODA la vida del objeto, no por video. Para
        # poder reusar un mismo ExtractorLandmarks en varios videos seguidos
        # (tools/ingest_carpeta.py reusa uno solo para toda la carpeta, para
        # no recargar los modelos en cada archivo, que es lo que tarda),
        # cada llamada a extraer() arranca su reloj justo despues de donde
        # termino el video anterior, en vez de repetir desde 0.
        self._proximo_t_ms = 0

    def cerrar(self):
        self.pose.close()
        self.hands.close()

    def extraer(self, video_path):
        """Devuelve (raw_frames, fps, n_frames).

        raw_frames: lista de (pose, pose_mundo, left, right) por cada frame leido del
        video, en el mismo formato que sign_norm.normalize_sequence espera
        (pose: 33 x [x,y,z,vis] o None; left/right: 21 x [x,y,z] o None).
        """
        cap = cv2.VideoCapture(video_path)
        if not cap.isOpened():
            raise RuntimeError(f"no se pudo abrir el video: {video_path}")

        # Auto-rota segun la metadata de orientacion del archivo si el
        # build de OpenCV lo soporta (evita analizar un video "de costado"
        # cuando el telefono grabo en vertical pero guardo el pixel en
        # horizontal con un flag de rotacion aparte).
        try:
            cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
        except Exception:
            pass

        fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
        t_base = self._proximo_t_ms

        raw_frames = []
        idx = 0
        t_ms = t_base
        while True:
            ok, frame_bgr = cap.read()
            if not ok:
                break

            rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
            mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            t_ms = t_base + int(idx * 1000 / fps)

            pose_res = self.pose.detect_for_video(mp_image, t_ms)
            hand_res = self.hands.detect_for_video(mp_image, t_ms)

            pose = None
            if pose_res.pose_landmarks:
                pose = [_punto_pose(p) for p in pose_res.pose_landmarks[0]]

            pose_mundo = None
            if pose_res.pose_world_landmarks:
                pose_mundo = [_punto_pose_mundo(p)
                              for p in pose_res.pose_world_landmarks[0]]

            left = right = None
            for lm, handed in zip(hand_res.hand_landmarks, hand_res.handedness):
                etiqueta = handed[0].category_name if handed else None
                pts = [_punto_mano(p) for p in lm]
                if etiqueta == "Left":
                    left = pts
                else:
                    right = pts

            raw_frames.append((pose, pose_mundo, left, right))
            idx += 1

        cap.release()
        # Deja el reloj listo para el proximo video de esta misma instancia,
        # con 1 segundo de margen para no repetir el ultimo timestamp usado.
        self._proximo_t_ms = t_ms + 1000
        return raw_frames, fps, idx
