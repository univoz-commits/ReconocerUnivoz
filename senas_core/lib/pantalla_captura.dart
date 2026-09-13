/// Grabar muestras nuevas desde el telefono, etiquetadas con la palabra.
///
/// Esta pensada para grabar MUCHAS repeticiones seguidas: la palabra queda
/// fija arriba y el boton vuelve a estar listo apenas se guarda una, sin
/// tener que reescribir nada. Es lo que hace la diferencia entre juntar 5
/// muestras y juntar 50.
library pantalla_captura;

import 'package:flutter/material.dart';

import 'camera_bridge.dart';
import 'controlador_captura.dart';
import 'muestras_locales.dart';
import 'skeleton_painter.dart' show SkeletonPainter;

/// Debajo de esto la grabacion casi seguro salio mal (mano fuera de cuadro,
/// boton apretado dos veces sin querer).
const int kMinFramesUtiles = 8;

/// Categorias que ya usa el equipo (las mismas de videos/palabras_sm.xlsx,
/// cargadas a la base con sql/003_categorizar_senas.sql). Se ofrecen como
/// punto de partida al elegir la categoria, ademas de las que ya se hayan
/// usado en este telefono -- no es una lista cerrada: se puede escribir
/// cualquier otra y queda guardada tal cual.
const List<String> kCategoriasBase = [
  'Acciones / Verbos',
  'Entorno y Educación',
  'Entorno y Familia',
  'Familia',
  'Familia y Relaciones',
  'Identidad / Personal',
  'LSM / Comunicación',
  'Necesidades y Entorno',
  'Preguntas',
  'Preguntas e Interacción',
  'Respuestas BÁSICAS',
  'Saludos y Cortesía',
  'Sentimientos y Expresiones',
];

class PantallaCaptura extends StatefulWidget {
  const PantallaCaptura({Key? key}) : super(key: key);

  @override
  State<PantallaCaptura> createState() => _PantallaCapturaState();
}

class _PantallaCapturaState extends State<PantallaCaptura> {
  final _ctrl = ControladorCaptura();
  final _almacen = AlmacenMuestras.instancia;
  final _palabraCtrl = TextEditingController();
  final _signerCtrl = TextEditingController();

  /// Controller real del campo de categoria -- lo crea y lo destruye el
  /// propio widget Autocomplete (ver fieldViewBuilder en _campoCategoria);
  /// aca solo guardamos la referencia para poder leerlo al guardar y
  /// completarlo automaticamente si se reconoce la palabra.
  TextEditingController? _categoriaCtrl;

  String _glosa = '';
  int _guardadasEstaSesion = 0;
  String? _aviso;
  bool _avisoEsError = false;
  bool _volteando = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_alCambiar);
    _palabraCtrl.addListener(() {
      final g = aGlosa(_palabraCtrl.text);
      if (g == _glosa) return;
      setState(() => _glosa = g);
      // Si ya se grabo esta palabra antes y todavia no se toco el campo de
      // categoria a mano, se sugiere la misma de la ultima vez -- asi no
      // hay que volver a escribirla en cada repeticion de la misma sena.
      final categoriaCtrl = _categoriaCtrl;
      if (categoriaCtrl != null && categoriaCtrl.text.trim().isEmpty) {
        final sugerida = _almacen.categoriaDe(g);
        if (sugerida != null) categoriaCtrl.text = sugerida;
      }
    });
    _arrancar();
  }

  Future<void> _arrancar() async {
    await _almacen.cargar();
    if (!mounted) return;
    await _ctrl.iniciar(
      frontal: _almacen.ajustes.camaraFrontal,
      cruzarManos: _almacen.ajustes.cruzarManos,
    );
  }

  /// Cambia entre camara frontal y trasera sin salir de la pantalla, y deja
  /// el nuevo lado guardado en Ajustes para la proxima vez. No se permite
  /// mientras se esta grabando: cortaria la muestra a mitad de camino.
  Future<void> _voltearCamara() async {
    if (_volteando || _ctrl.grabando || !_ctrl.lista) return;
    setState(() => _volteando = true);
    final nuevos = _almacen.ajustes.copiar()
      ..camaraFrontal = !_almacen.ajustes.camaraFrontal;
    try {
      await _ctrl.reiniciar(
        frontal: nuevos.camaraFrontal,
        cruzarManos: nuevos.cruzarManos,
      );
      await _almacen.guardarAjustes(nuevos);
    } finally {
      if (mounted) setState(() => _volteando = false);
    }
  }

  void _alCambiar() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ctrl.removeListener(_alCambiar);
    _ctrl.dispose();
    _palabraCtrl.dispose();
    _signerCtrl.dispose();
    // _categoriaCtrl NO se destruye aca: es del propio Autocomplete (ver
    // _campoCategoria), que lo crea y lo libera solo.
    super.dispose();
  }

  bool get _puedeGrabar => _glosa.isNotEmpty && _ctrl.lista;

  Future<void> _alternarGrabacion() async {
    if (_ctrl.grabando) {
      final framesLeidos = _ctrl.framesGrabados;
      final captura = await _ctrl.terminarCaptura();
      if (!mounted) return;

      if (captura == null) {
        _mostrar(
          'No se capturó nada. Asegurate de que se vean los hombros y las manos en cámara.',
          error: true,
        );
        return;
      }
      if (framesLeidos < kMinFramesUtiles) {
        _mostrar(
          'Grabación demasiado corta ($framesLeidos frames). No se guardó — hacé la seña completa antes de detener.',
          error: true,
        );
        return;
      }

      await _almacen.agregar(
        gloss: _glosa,
        espanol: _palabraCtrl.text.trim(),
        seq: captura.secuencia.frames,
        nFramesOrig: captura.framesCrudos.length,
        categoria: (_categoriaCtrl?.text.trim().isEmpty ?? true)
            ? null
            : _categoriaCtrl!.text.trim(),
        signer:
            _signerCtrl.text.trim().isEmpty ? null : _signerCtrl.text.trim(),
        captura: captura,
      );
      if (!mounted) return;
      setState(() => _guardadasEstaSesion++);
      _mostrar(
          'Guardada. $_glosa tiene ${_almacen.cuantasDe(_glosa)} muestra(s).');
    } else {
      setState(() => _aviso = null);
      _ctrl.empezar();
    }
  }

  void _mostrar(String texto, {bool error = false}) {
    setState(() {
      _aviso = texto;
      _avisoEsError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agregar muestras'),
        actions: [
          IconButton(
            icon: _volteando
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cameraswitch_outlined),
            tooltip: _almacen.ajustes.camaraFrontal
                ? 'Cambiar a cámara trasera'
                : 'Cambiar a cámara frontal',
            onPressed: (_ctrl.grabando || !_ctrl.lista) ? null : _voltearCamara,
          ),
          if (_guardadasEstaSesion > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text('+$_guardadasEstaSesion',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          _formulario(),
          Expanded(child: _preview()),
          _barraInferior(),
        ],
      ),
    );
  }

  Widget _formulario() {
    final yaTiene = _glosa.isEmpty ? 0 : _almacen.cuantasDe(_glosa);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _palabraCtrl,
                  enabled: !_ctrl.grabando,
                  textCapitalization: TextCapitalization.none,
                  decoration: const InputDecoration(
                    labelText: '¿Qué palabra es?',
                    hintText: 'gracias, cómo estás...',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _signerCtrl,
                  enabled: !_ctrl.grabando,
                  decoration: const InputDecoration(
                    labelText: 'Tu nombre',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _campoCategoria(),
          const SizedBox(height: 6),
          if (_glosa.isNotEmpty)
            Text(
              'Se guardará como $_glosa  ·  ya tenés $yaTiene muestra(s)',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            )
          else
            Text(
              'Escribí la palabra para poder grabar.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
        ],
      ),
    );
  }

  /// Campo de categoria: se puede escribir cualquier cosa, pero a medida
  /// que se tipea aparecen como sugerencia las de kCategoriasBase y las que
  /// ya se usaron en este telefono -- asi el mismo nombre de categoria no
  /// termina escrito de dos formas distintas por error de tipeo.
  Widget _campoCategoria() {
    final sugerencias =
        {...kCategoriasBase, ..._almacen.categoriasUsadas}.toList()..sort();
    return Autocomplete<String>(
      optionsBuilder: (TextEditingValue valor) {
        if (valor.text.isEmpty) return sugerencias;
        final buscado = valor.text.toLowerCase();
        return sugerencias.where((c) => c.toLowerCase().contains(buscado));
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        // El controller de este campo lo crea y destruye el propio
        // Autocomplete -- solo guardamos la referencia (una vez; este
        // builder se re-invoca en cada rebuild del formulario, pero el
        // controller que nos pasa es siempre la misma instancia) para
        // poder leerlo al guardar y completarlo automaticamente desde el
        // listener de la palabra.
        _categoriaCtrl = controller;
        return TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: !_ctrl.grabando,
          decoration: const InputDecoration(
            labelText: 'Categoría (opcional)',
            hintText: 'Saludos y Cortesía...',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, opciones) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [
                for (final o in opciones)
                  ListTile(
                    dense: true,
                    title: Text(o),
                    onTap: () => onSelected(o),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _preview() {
    if (_ctrl.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_ctrl.error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                  onPressed: _arrancar, child: const Text('Reintentar')),
            ],
          ),
        ),
      );
    }

    final camara = _ctrl.iniciada;
    if (camara == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: camara.relacionAspecto,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Texture(textureId: camara.textureId),
                ),
                ValueListenableBuilder<LandmarkFrame?>(
                  valueListenable: _ctrl.frame,
                  builder: (_, frame, __) => CustomPaint(
                    painter: SkeletonPainter(frame: frame),
                    size: Size.infinite,
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 8,
          left: 8,
          child: ValueListenableBuilder<LandmarkFrame?>(
            valueListenable: _ctrl.frame,
            builder: (_, frame, __) => _chipEstado(frame),
          ),
        ),
        if (_ctrl.grabando)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('● ${_ctrl.framesGrabados} frames',
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ),
      ],
    );
  }

  Widget _chipEstado(LandmarkFrame? frame) {
    final cuerpo = frame?.pose != null;
    final izq = frame?.left != null;
    final der = frame?.right != null;
    Widget punto(String texto, bool ok) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text(
            '${ok ? "✓" : "✗"} $texto',
            style: TextStyle(
              fontSize: 12,
              color: ok ? Colors.greenAccent.shade400 : Colors.white54,
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        punto('Cuerpo', cuerpo),
        punto('Izq', izq),
        punto('Der', der),
      ]),
    );
  }

  Widget _barraInferior() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_aviso != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _avisoEsError
                      ? Colors.orange.shade800
                      : Colors.green.shade700,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_aviso!,
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _puedeGrabar ? _alternarGrabacion : null,
                icon: Icon(
                    _ctrl.grabando ? Icons.stop : Icons.fiber_manual_record),
                label: Text(
                    _ctrl.grabando ? 'Detener y guardar' : 'Grabar muestra'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _ctrl.grabando ? Colors.red : null,
                  foregroundColor: _ctrl.grabando ? Colors.white : null,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
