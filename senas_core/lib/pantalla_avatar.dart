/// Pantalla del avatar 3D: escribís, elegís de una lista, o hablás una
/// palabra, y el avatar (assets/avatar/univozM.vrm) hace la seña
/// correspondiente. Es el sentido inverso de PantallaDeTranslacion: en vez
/// de camara -> texto, es texto/voz -> avatar.
///
/// La fuente de las secuencias es la misma que usa el reconocedor DTW
/// (plantillas.dart / dtw.dart): no hay un banco de datos aparte para
/// animacion, se reusan las mismas muestras aprobadas.
library pantalla_avatar;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:webview_flutter/webview_flutter.dart';

import 'avatar_bridge.dart';
import 'dtw.dart';
import 'plantillas.dart';

/// Que brazos anima el avatar. Izquierda y derecha son las del AVATAR, tal
/// como las ve quien lo mira de frente invertidas -- igual que al aprender
/// una seña de un instructor sentado enfrente.
enum _Manos { ambas, izquierda, derecha }

class PantallaAvatar extends StatefulWidget {
  const PantallaAvatar({super.key});

  @override
  State<PantallaAvatar> createState() => _PantallaAvatarState();
}

class _PantallaAvatarState extends State<PantallaAvatar> {
  final _bridge = AvatarBridge();
  final _controladorTexto = TextEditingController();
  final _voz = stt.SpeechToText();

  Diccionario? _diccionario;
  bool _cargando = true;
  bool _reproduciendo = false;
  bool _vozLista = false;
  bool _escuchando = false;
  _Manos _manos = _Manos.ambas;
  String? _aviso;

  @override
  void initState() {
    super.initState();
    _bridge.onTerminado = () {
      if (mounted) setState(() => _reproduciendo = false);
    };
    _cargar();
    _iniciarVoz();
  }

  Future<void> _cargar() async {
    final d = await cargarDiccionario();
    if (!mounted) return;
    setState(() {
      _diccionario = d;
      _cargando = false;
    });
  }

  Future<void> _iniciarVoz() async {
    final ok = await _voz.initialize(
      onError: (e) {
        if (mounted) setState(() => _escuchando = false);
      },
      onStatus: (s) {
        if (s == 'done' || s == 'notListening') {
          if (mounted) setState(() => _escuchando = false);
        }
      },
    );
    if (mounted) setState(() => _vozLista = ok);
  }

  /// Busca una plantilla por glosa o por su traduccion al español. Si hay
  /// varias muestras de la misma palabra, usa la primera -- para elegir
  /// "la mejor" habria que ver calidad/quality_score, que no viaja en el
  /// paquete de plantillas.
  Template? _buscar(String texto) {
    final d = _diccionario;
    if (d == null) return null;
    final q = texto.trim().toUpperCase();
    if (q.isEmpty) return null;
    for (final t in d.clasificador.templates) {
      if (t.gloss.toUpperCase() == q) return t;
    }
    for (final t in d.clasificador.templates) {
      if (t.espanol.trim().toUpperCase() == q) return t;
    }
    return null;
  }

  List<String> get _glosasDisponibles {
    final d = _diccionario;
    if (d == null) return const [];
    final vistas = <String>{};
    final out = <String>[];
    for (final t in d.clasificador.templates) {
      if (vistas.add(t.gloss)) out.add(t.gloss);
    }
    out.sort();
    return out;
  }

  Future<void> _senar(String texto) async {
    final t = _buscar(texto);
    if (t == null) {
      setState(() => _aviso = 'No tengo la seña de "$texto" todavía.');
      return;
    }
    setState(() {
      _aviso = null;
      _reproduciendo = true;
    });
    await _bridge.reproducir(t.seq);
  }

  Future<void> _cambiarManos(_Manos m) async {
    setState(() => _manos = m);
    await _bridge.configurarManos(
      izquierda: m != _Manos.derecha,
      derecha: m != _Manos.izquierda,
    );
  }

  Future<void> _alternarMicrofono() async {
    if (_escuchando) {
      await _voz.stop();
      setState(() => _escuchando = false);
      return;
    }
    if (!_vozLista) {
      setState(() => _aviso = 'El reconocimiento de voz no está disponible.');
      return;
    }
    final permiso = await Permission.microphone.request();
    if (!permiso.isGranted) {
      setState(() => _aviso = 'Sin permiso de micrófono no puedo escuchar.');
      return;
    }
    setState(() {
      _escuchando = true;
      _aviso = null;
    });
    await _voz.listen(
      localeId: 'es_MX',
      onResult: (r) {
        _controladorTexto.text = r.recognizedWords;
        if (r.finalResult && r.recognizedWords.trim().isNotEmpty) {
          _senar(r.recognizedWords);
        }
      },
    );
  }

  @override
  void dispose() {
    _voz.stop();
    _bridge.dispose();
    _controladorTexto.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Avatar 3D')),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: Stack(
              children: [
                Positioned.fill(
                  child: WebViewWidget(controller: _bridge.controller),
                ),
                if (_reproduciendo)
                  const Positioned(
                    top: 8,
                    left: 8,
                    child: Chip(
                      avatar: Icon(Icons.front_hand, size: 18),
                      label: Text('Señando...'),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            flex: 2,
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : _panelControles(),
          ),
        ],
      ),
    );
  }

  Widget _panelControles() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controladorTexto,
                  decoration: const InputDecoration(
                    labelText: 'Escribí una palabra',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: _senar,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: Icon(_escuchando ? Icons.mic : Icons.mic_none),
                tooltip: _escuchando ? 'Escuchando...' : 'Decir la palabra',
                onPressed: _alternarMicrofono,
              ),
              IconButton(
                icon: const Icon(Icons.front_hand),
                tooltip: 'Señar',
                onPressed: () => _senar(_controladorTexto.text),
              ),
            ],
          ),
          if (_aviso != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_aviso!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('Manos:', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentedButton<_Manos>(
                  segments: const [
                    ButtonSegment(value: _Manos.ambas, label: Text('Ambas')),
                    ButtonSegment(value: _Manos.izquierda, label: Text('Izq.')),
                    ButtonSegment(value: _Manos.derecha, label: Text('Der.')),
                  ],
                  selected: {_manos},
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onSelectionChanged: (s) => _cambiarManos(s.first),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('${_glosasDisponibles.length} señas disponibles',
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final g in _glosasDisponibles)
                    ActionChip(
                      label: Text(g),
                      onPressed: () => _senar(g),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
