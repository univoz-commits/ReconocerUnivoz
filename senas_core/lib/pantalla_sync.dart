/// Sincronizacion con Supabase: subir las muestras grabadas en el telefono
/// y bajarse el diccionario aprobado del equipo.
///
/// Las dos operaciones son independientes a proposito. Subir manda tus
/// muestras a la cola de pendientes; bajar trae lo que YA fue aprobado. Una
/// muestra recien subida no aparece en el diccionario hasta que alguien la
/// apruebe -- esa es la idea, no un olvido.
library pantalla_sync;

import 'package:flutter/material.dart';

import 'config_supabase.dart';
import 'muestras_locales.dart';
import 'supabase_api.dart';

class PantallaSync extends StatefulWidget {
  const PantallaSync({Key? key}) : super(key: key);

  @override
  State<PantallaSync> createState() => _PantallaSyncState();
}

class _PantallaSyncState extends State<PantallaSync> {
  final _almacen = AlmacenMuestras.instancia;
  final _api = SupabaseApi();

  bool _trabajando = false;
  String? _progreso;
  String? _resultado;
  bool _resultadoEsError = false;

  @override
  void initState() {
    super.initState();
    _almacen.addListener(_alCambiar);
    _almacen.cargar();
  }

  void _alCambiar() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _almacen.removeListener(_alCambiar);
    _api.cerrar();
    super.dispose();
  }

  void _mostrar(String texto, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _resultado = texto;
      _resultadoEsError = error;
      _progreso = null;
      _trabajando = false;
    });
  }

  Future<void> _probar() async {
    setState(() {
      _trabajando = true;
      _resultado = null;
      _progreso = 'Probando conexión...';
    });
    try {
      final msg = await _api.probar();
      _mostrar(msg);
    } catch (e) {
      _mostrar('$e', error: true);
    }
  }

  Future<void> _subir() async {
    final pendientes = _almacen.sinSubir;
    if (pendientes.isEmpty) {
      _mostrar('No hay muestras nuevas para subir.');
      return;
    }

    setState(() {
      _trabajando = true;
      _resultado = null;
      _progreso = 'Subiendo 0 de ${pendientes.length}...';
    });

    var ok = 0;
    final errores = <String>[];

    for (var i = 0; i < pendientes.length; i++) {
      final m = pendientes[i];
      if (mounted) {
        setState(() => _progreso =
            'Subiendo ${i + 1} de ${pendientes.length} (${m.gloss})...');
      }
      try {
        await _api.subirMuestra(
          gloss: m.gloss,
          espanol: m.espanol.isEmpty ? m.gloss.toLowerCase() : m.espanol,
          seq: m.seq,
          categoria: m.categoria,
          signer: m.signer,
          nFramesOrig: m.nFramesOrig,
          fps: m.fps,
          duracionMs: m.duracionMs,
          framesInvalidos: m.framesInvalidos,
          visibilidadMin: m.visibilidadMin,
          qualityScore: m.qualityScore,
          checksumSha256: m.checksumSha256,
        );
        // Se marca una por una: si se corta la red a mitad, lo que ya subio
        // no se vuelve a subir la proxima vez.
        await _almacen.marcarSubida(m.id);
        ok++;
      } catch (e) {
        errores.add('${m.gloss}: $e');
        // Un error de politica o de red se repite en todas: no tiene sentido
        // seguir intentando 40 veces.
        if (errores.length >= 3) break;
      }
    }

    if (errores.isEmpty) {
      _mostrar('$ok muestras subidas. Quedaron como "pendiente" — hay que '
          'aprobarlas en Supabase para que entren al diccionario.');
    } else {
      _mostrar(
        '$ok subidas, ${errores.length} con error.\n\n${errores.join("\n\n")}',
        error: true,
      );
    }
  }

  Future<void> _bajar() async {
    setState(() {
      _trabajando = true;
      _resultado = null;
      _progreso = 'Descargando diccionario...';
    });
    try {
      final plantillas = await _api.descargarPlantillas();
      if (plantillas.isEmpty) {
        _mostrar(
          'La base no tiene ninguna muestra aprobada todavía. En el SQL Editor '
          'de Supabase:\n\nUPDATE sign_samples SET estado=\'aprobada\' WHERE estado=\'pendiente\';',
          error: true,
        );
        return;
      }
      await _almacen.guardarSincronizadas(plantillas);
      final senas = plantillas.map((p) => p.gloss).toSet().length;
      _mostrar('$senas señas (${plantillas.length} plantillas) descargadas. '
          'Ya funcionan sin internet.');
    } catch (e) {
      _mostrar('$e', error: true);
    }
  }

  Future<void> _subirRaw() async {
    final pendientes = _almacen.muestras
        .where((m) => m.rawFramesPath != null && m.rawSubidaEn == null)
        .toList();
    if (pendientes.isEmpty) {
      _mostrar('No hay landmarks crudos pendientes.');
      return;
    }

    setState(() {
      _trabajando = true;
      _resultado = null;
      _progreso = 'Subiendo landmarks 0 de ${pendientes.length}...';
    });
    var ok = 0;
    final errores = <String>[];
    for (var i = 0; i < pendientes.length; i++) {
      final muestra = pendientes[i];
      if (mounted) {
        setState(() => _progreso =
            'Subiendo landmarks ${i + 1} de ${pendientes.length} (${muestra.gloss})...');
      }
      try {
        final bytes = await _almacen.cargarRawComprimido(muestra);
        if (bytes == null) throw StateError('no existe sidecar local');
        final uri = await _api.subirLandmarksCrudos(
          bucket: 'motion-raw',
          objectPath: 'raw/${muestra.id}.json.gz',
          gzipBytes: bytes,
        );
        await _almacen.marcarRawSubida(muestra.id, uri);
        ok++;
      } catch (e) {
        errores.add('${muestra.gloss}: $e');
        if (errores.length >= 3) break;
      }
    }
    if (errores.isEmpty) {
      _mostrar('$ok archivos de landmarks subidos. No contienen video.');
    } else {
      _mostrar(
          '$ok subidos, ${errores.length} con error.\n\n${errores.join("\n\n")}',
          error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sinSubir = _almacen.sinSubir.length;

    return Scaffold(
      appBar: AppBar(title: const Text('Sincronizar')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!haySupabaseConfigurado)
            _cinta(
              'Falta cargar la URL y la clave del proyecto en config_supabase.dart. '
              'Sin eso, la app funciona igual pero solo con las muestras de este teléfono.',
              Colors.orange.shade800,
            ),
          _seccion(
            icono: Icons.cloud_upload_outlined,
            titulo: 'Subir mis muestras',
            detalle: sinSubir == 0
                ? 'Todas las muestras de este teléfono ya están en la base.'
                : '$sinSubir muestra(s) sin subir. Van a quedar como "pendiente" '
                    'hasta que alguien las apruebe.',
            boton: 'Subir $sinSubir muestra(s)',
            habilitado: !_trabajando && sinSubir > 0,
            onPressed: _subir,
          ),
          _seccion(
            icono: Icons.data_object,
            titulo: 'Subir landmarks crudos (opcional)',
            detalle: _almacen.muestras
                        .where((m) =>
                            m.rawFramesPath != null && m.rawSubidaEn == null)
                        .length ==
                    0
                ? 'No hay archivos crudos pendientes.'
                : 'Solo sube coordenadas comprimidas para auditoría o re-normalización. '
                    'Nunca sube video.',
            boton: 'Subir landmarks',
            habilitado: !_trabajando &&
                _almacen.muestras.any(
                    (m) => m.rawFramesPath != null && m.rawSubidaEn == null),
            onPressed: _subirRaw,
          ),
          _seccion(
            icono: Icons.cloud_download_outlined,
            titulo: 'Bajar el diccionario',
            detalle: _almacen.sincronizadas.isEmpty
                ? 'Todavía no se descargó nada. Se está usando el paquete que vino '
                    'con la app más tus muestras locales.'
                : '${_almacen.sincronizadas.length} plantillas guardadas'
                    '${_almacen.sincronizadoEn != null ? " · ${_fecha(_almacen.sincronizadoEn!)}" : ""}. '
                    'Quedan en el teléfono: no hace falta internet para reconocer.',
            boton: 'Descargar ahora',
            habilitado: !_trabajando,
            onPressed: _bajar,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _trabajando ? null : _probar,
            icon: const Icon(Icons.wifi_tethering),
            label: const Text('Probar conexión'),
          ),
          const SizedBox(height: 16),
          if (_progreso != null)
            Row(
              children: [
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Expanded(child: Text(_progreso!)),
              ],
            ),
          if (_resultado != null)
            _cinta(
                _resultado!,
                _resultadoEsError
                    ? Colors.orange.shade800
                    : Colors.green.shade700),
          const SizedBox(height: 24),
          Text(
            'Por qué las muestras entran como "pendiente": la app usa la clave '
            'publishable, que es pública por diseño. Las reglas de la base '
            '(sql/002_app_acceso.sql) le permiten agregar, pero no aprobar, '
            'modificar ni borrar. Así, aunque alguien saque la clave del APK, '
            'no puede tocar el diccionario aprobado.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _cinta(String texto, Color color) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration:
            BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
        child: SelectableText(texto,
            style: const TextStyle(color: Colors.white, fontSize: 13)),
      );

  Widget _seccion({
    required IconData icono,
    required String titulo,
    required String detalle,
    required String boton,
    required bool habilitado,
    required VoidCallback onPressed,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icono),
                const SizedBox(width: 12),
                Text(titulo,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            Text(detalle,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: habilitado ? onPressed : null,
                child: Text(boton),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fecha(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return iso;
    String dos(int n) => n.toString().padLeft(2, '0');
    return '${dos(t.day)}/${dos(t.month)} ${dos(t.hour)}:${dos(t.minute)}';
  }
}
