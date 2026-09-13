/// Calibracion del reconocedor, sin recompilar.
///
/// Los umbrales por defecto (0.55 / 0.12) estan calibrados contra datos
/// sinteticos, no contra grabaciones reales -- el README ya avisaba que hay
/// que ajustarlos con las primeras señas grabadas. Esta pantalla es para
/// hacerlo probando, que es la unica forma honesta de calibrarlos.
library pantalla_ajustes;

import 'package:flutter/material.dart';

import 'motion_contract.dart';
import 'muestras_locales.dart';
import 'pantalla_espejo.dart';
import 'voz.dart';

class PantallaAjustes extends StatefulWidget {
  const PantallaAjustes({Key? key}) : super(key: key);

  @override
  State<PantallaAjustes> createState() => _PantallaAjustesState();
}

class _PantallaAjustesState extends State<PantallaAjustes> {
  final _almacen = AlmacenMuestras.instancia;
  late Ajustes _a;
  bool _listo = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    await _almacen.cargar();
    if (!mounted) return;
    setState(() {
      _a = _almacen.ajustes.copiar();
      _listo = true;
    });
  }

  Future<void> _guardar() async {
    await _almacen.guardarAjustes(_a);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text(
              'Ajustes guardados. Volvé a entrar a Reconocer para aplicarlos.')),
    );
  }

  Future<void> _calibrarPulgares() async {
    await _almacen.guardarAjustes(_a);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const PantallaEspejo(iniciarCalibracion: true),
    ));
    if (!mounted) return;
    setState(() => _a = _almacen.ajustes.copiar());
  }

  @override
  Widget build(BuildContext context) {
    if (!_listo) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _titulo('Umbrales de reconocimiento'),
          _explicacion(
            'Una seña se acepta solo si la distancia está POR DEBAJO del máximo '
            'y el margen POR ENCIMA del mínimo. Si te reconoce cosas que no hiciste, '
            'bajá la distancia máxima o subí el margen. Si no te reconoce nada, al revés.',
          ),
          _slider(
            etiqueta: 'Distancia máxima',
            valor: _a.maxDistance,
            min: 0.10,
            max: 1.50,
            divisiones: 28,
            ayuda: 'más bajo = más estricto',
            onChanged: (v) => setState(() => _a.maxDistance = v),
          ),
          _slider(
            etiqueta: 'Margen mínimo',
            valor: _a.minMargin,
            min: 0.0,
            max: 0.50,
            divisiones: 25,
            ayuda:
                'cuánto tiene que ganarle a la segunda candidata; más alto = más estricto',
            onChanged: (v) => setState(() => _a.minMargin = v),
          ),
          TextButton(
            onPressed: () => setState(() {
              _a.maxDistance = 0.55;
              _a.minMargin = 0.12;
            }),
            child: const Text('Volver a los valores por defecto (0.55 / 0.12)'),
          ),
          const Divider(height: 32),
          _titulo('RigBody / avatar 3D'),
          _explicacion(
            'Ajusta cómo el espacio 3D normalizado mueve el avatar. Estos '
            'valores no cambian vectores ni entrenamiento; solo calibran el rig.',
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Invertir profundidad Z'),
            subtitle: const Text('Úsalo si el avatar mueve manos hacia atrás.'),
            value: _a.rigCalibration.invertZ,
            onChanged: (v) => setState(() =>
                _a.rigCalibration = _a.rigCalibration.copyWith(invertZ: v)),
          ),
          _slider(
            etiqueta: 'Escala del avatar',
            valor: _a.rigCalibration.avatarScale,
            min: 0.70,
            max: 1.30,
            divisiones: 60,
            ayuda: 'ajusta tamaño visual, no datos IA',
            onChanged: (v) => setState(() =>
                _a.rigCalibration = _a.rigCalibration.copyWith(avatarScale: v)),
          ),
          _slider(
            etiqueta: 'Ganancia brazo izquierdo',
            valor: _a.rigCalibration.leftArmGain,
            min: 0.50,
            max: 1.50,
            divisiones: 50,
            ayuda: 'respuesta del IK izquierdo',
            onChanged: (v) => setState(() =>
                _a.rigCalibration = _a.rigCalibration.copyWith(leftArmGain: v)),
          ),
          _slider(
            etiqueta: 'Ganancia brazo derecho',
            valor: _a.rigCalibration.rightArmGain,
            min: 0.50,
            max: 1.50,
            divisiones: 50,
            ayuda: 'respuesta del IK derecho',
            onChanged: (v) => setState(() => _a.rigCalibration =
                _a.rigCalibration.copyWith(rightArmGain: v)),
          ),
          _slider(
            etiqueta: 'Sensibilidad de dedos',
            valor: _a.rigCalibration.fingerSensitivity,
            min: 0.50,
            max: 1.50,
            divisiones: 50,
            ayuda: 'amplitud de flexión de falanges',
            onChanged: (v) => setState(() => _a.rigCalibration =
                _a.rigCalibration.copyWith(fingerSensitivity: v)),
          ),
          _slider(
            etiqueta: 'Límite mínimo de codo',
            valor: _a.rigCalibration.ikMin,
            min: 0.0,
            max: 1.50,
            divisiones: 30,
            ayuda: 'evita soluciones IK demasiado cerradas',
            onChanged: (v) => setState(() {
              final max =
                  _a.rigCalibration.ikMax < v ? v : _a.rigCalibration.ikMax;
              _a.rigCalibration =
                  _a.rigCalibration.copyWith(ikMin: v, ikMax: max);
            }),
          ),
          _slider(
            etiqueta: 'Límite máximo de codo',
            valor: _a.rigCalibration.ikMax,
            min: _a.rigCalibration.ikMin,
            max: 3.14,
            divisiones: 62,
            ayuda: 'evita soluciones IK imposibles',
            onChanged: (v) => setState(
                () => _a.rigCalibration = _a.rigCalibration.copyWith(ikMax: v)),
          ),
          _slider(
            etiqueta: 'Compensación de muñeca',
            valor: _a.rigCalibration.wristCompensation,
            min: -1.0,
            max: 1.0,
            divisiones: 40,
            ayuda: 'corrección angular de palma',
            onChanged: (v) => setState(() => _a.rigCalibration =
                _a.rigCalibration.copyWith(wristCompensation: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Restablecer mano si se pierde'),
            subtitle: const Text(
                'Tras un margen breve, devuelve dedos y muñeca a reposo; '
                'evita dejar una mano congelada o deformada.'),
            value: _a.rigCalibration.resetHandOnLoss,
            onChanged: (v) => setState(() => _a.rigCalibration =
                _a.rigCalibration.copyWith(resetHandOnLoss: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Modo diagnóstico RigBody'),
            subtitle: const Text(
                'Muestra FPS, skew, tracks, contacto y errores. Apagado por defecto; '
                'guarda hasta 300 frames sin video.'),
            value: _a.rigDiagnosticMode,
            onChanged: (v) => setState(() => _a.rigDiagnosticMode = v),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.pan_tool_alt_outlined, size: 18),
              label: const Text('Calibrar pulgares con cámara'),
              onPressed: _calibrarPulgares,
            ),
          ),
          TextButton(
            onPressed: () =>
                setState(() => _a.rigCalibration = const RigCalibration()),
            child: const Text('Restablecer calibración RigBody'),
          ),
          const Divider(height: 32),
          _titulo('Cámara'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Usar cámara frontal'),
            subtitle: const Text(
                'La trasera evita la ambigüedad del espejo, pero necesitás que alguien sostenga el teléfono.'),
            value: _a.camaraFrontal,
            onChanged: (v) => setState(() => _a.camaraFrontal = v),
          ),
          const Divider(height: 32),
          _titulo('Voz'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Decir el resultado en voz alta'),
            subtitle: const Text(
                'Apenas se reconoce una seña con confianza, el teléfono dice la palabra. '
                'Apagalo para que quede solo en pantalla.'),
            value: _a.hablarResultado,
            onChanged: (v) => setState(() => _a.hablarResultado = v),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.volume_up, size: 18),
              label: const Text('Probar voz ("Hola, gracias")'),
              onPressed: () async {
                final err = await LectorVoz.instancia.decir('Hola, gracias');
                if (!mounted) return;
                if (err != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error de voz: $err')),
                  );
                }
              },
            ),
          ),
          const Divider(height: 32),
          _titulo('Diccionario'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Agregar versión espejada de cada muestra'),
            subtitle: const Text(
                'Cubre a quien seña con la otra mano sin grabar de nuevo. '
                'Desactivalo solo si alguna seña usa izquierda/derecha como parte del significado.'),
            value: _a.espejoAutomatico,
            onChanged: (v) => setState(() => _a.espejoAutomatico = v),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _guardar,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Guardar ajustes'),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _titulo(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      );

  Widget _explicacion(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(t,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
      );

  Widget _slider({
    required String etiqueta,
    required double valor,
    required double min,
    required double max,
    required int divisiones,
    required String ayuda,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(etiqueta),
            Text(valor.toStringAsFixed(2),
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        Slider(
          value: valor.clamp(min, max),
          min: min,
          max: max,
          divisions: divisiones,
          onChanged: onChanged,
        ),
        Text(ayuda,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        const SizedBox(height: 12),
      ],
    );
  }
}
