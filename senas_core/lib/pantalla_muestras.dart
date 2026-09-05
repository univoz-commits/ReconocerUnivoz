/// Lista de las muestras grabadas en este telefono: cuantas hay de cada
/// palabra, borrar las que salieron mal, y exportar todo para subirlo a
/// Supabase desde la PC (tools/importar_muestras.py).
library pantalla_muestras;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'muestras_locales.dart';

/// Debajo de esto una sena tiende a no reconocerse bien. No es un numero
/// magico: es el minimo practico para que el DTW tenga con que comparar.
const int kMuestrasRecomendadas = 5;

class PantallaMuestras extends StatefulWidget {
  const PantallaMuestras({Key? key}) : super(key: key);

  @override
  State<PantallaMuestras> createState() => _PantallaMuestrasState();
}

class _PantallaMuestrasState extends State<PantallaMuestras> {
  final _almacen = AlmacenMuestras.instancia;
  bool _exportando = false;

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
    super.dispose();
  }

  Future<void> _exportar() async {
    setState(() => _exportando = true);
    try {
      final archivo = await _almacen.exportar();
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(archivo.path)],
        text: 'Muestras de señas UNIVOZ (${_almacen.total}) — '
            'importar con: python tools/importar_muestras.py --archivo <este archivo>',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo exportar: $e')),
      );
    } finally {
      if (mounted) setState(() => _exportando = false);
    }
  }

  Future<void> _confirmarBorrarGlosa(String gloss, int cuantas) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Borrar $gloss?'),
        content: Text('Se borran las $cuantas muestras de esta palabra '
            'guardadas en el teléfono. Lo que ya subiste a la base no se toca.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) await _almacen.borrarGlosa(gloss);
  }

  @override
  Widget build(BuildContext context) {
    final porCategoria = _almacen.porCategoriaYGlosa;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mis muestras'),
        actions: [
          IconButton(
            onPressed: _almacen.total == 0 || _exportando ? null : _exportar,
            icon: _exportando
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share),
            tooltip: 'Exportar para subir a la base',
          ),
        ],
      ),
      body: porCategoria.isEmpty ? _vacio() : _lista(porCategoria),
    );
  }

  /// Nombres de categoria ordenados alfabeticamente, con "Sin categoría"
  /// siempre al final (no es una categoria de verdad, es solo el resto).
  List<String> _categoriasOrdenadas(Map<String, List<MapEntry<String, int>>> porCategoria) {
    final claves = porCategoria.keys.toList()
      ..sort((a, b) {
        if (a == 'Sin categoría') return b == 'Sin categoría' ? 0 : 1;
        if (b == 'Sin categoría') return -1;
        return a.compareTo(b);
      });
    return claves;
  }

  Widget _vacio() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.videocam_off_outlined, size: 56, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              const Text(
                'Todavía no grabaste ninguna muestra en este teléfono.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Andá a "Agregar muestras", escribí la palabra y grabá la seña varias veces.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      );

  Widget _lista(Map<String, List<MapEntry<String, int>>> porCategoria) {
    final categorias = _categoriasOrdenadas(porCategoria);
    final totalPalabras = porCategoria.values.fold(0, (n, l) => n + l.length);

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            '${_almacen.total} muestras · $totalPalabras palabras en '
            '${categorias.length} categoría(s). Dentro de cada una, de menos a '
            'más muestras: las de arriba son las que conviene reforzar.',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
          ),
        ),
        for (final cat in categorias) ...[
          _encabezadoCategoria(cat, porCategoria[cat]!.length),
          for (final g in porCategoria[cat]!) _grupo(g.key, g.value),
        ],
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Para subirlas a la base usá "Sincronizar" en el menú — es directo, '
            'sin pasar por la PC. El ícono de compartir de acá arriba es la vía '
            'alternativa: exporta un archivo para importar con '
            'tools/importar_muestras.py, útil si no hay internet en el teléfono. '
            'Las muestras funcionan en el teléfono aunque no las subas.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _encabezadoCategoria(String categoria, int cuantasPalabras) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                categoria.toUpperCase(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.6,
                  color: categoria == 'Sin categoría'
                      ? Colors.grey.shade500
                      : Colors.deepPurple.shade400,
                ),
              ),
            ),
            Text('$cuantasPalabras',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ],
        ),
      );

  Widget _grupo(String gloss, int cuantas) {
    final pocas = cuantas < kMuestrasRecomendadas;
    final delGrupo = _almacen.muestras.where((m) => m.gloss == gloss).toList()
      ..sort((a, b) => b.creada.compareTo(a.creada));

    return ExpansionTile(
      leading: CircleAvatar(
        backgroundColor: pocas ? Colors.orange.shade100 : Colors.green.shade100,
        child: Text('$cuantas',
            style: TextStyle(
              color: pocas ? Colors.orange.shade900 : Colors.green.shade900,
              fontWeight: FontWeight.bold,
            )),
      ),
      title: Text(gloss),
      subtitle: Text(pocas
          ? 'faltan ${kMuestrasRecomendadas - cuantas} para llegar a $kMuestrasRecomendadas'
          : _almacen.espanolDe(gloss) ?? ''),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _confirmarBorrarGlosa(gloss, cuantas),
      ),
      children: [
        for (final m in delGrupo)
          ListTile(
            dense: true,
            leading: Icon(
              m.subida ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
              size: 18,
              color: m.subida ? Colors.green.shade600 : Colors.grey.shade400,
            ),
            title: Text(_fechaCorta(m.creada)),
            subtitle: Text('${m.nFramesOrig} frames'
                '${m.signer != null ? " · ${m.signer}" : ""}'
                '${m.subida ? " · en la base" : ""}'),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => _almacen.borrar(m.id),
            ),
          ),
      ],
    );
  }

  String _fechaCorta(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return iso;
    String dos(int n) => n.toString().padLeft(2, '0');
    return '${dos(t.day)}/${dos(t.month)} ${dos(t.hour)}:${dos(t.minute)}';
  }
}
