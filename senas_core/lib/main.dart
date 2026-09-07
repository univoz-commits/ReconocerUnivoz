import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'muestras_locales.dart';
import 'pantalla_ajustes.dart';
import 'pantalla_avatar.dart';
import 'pantalla_captura.dart';
import 'pantalla_espejo.dart';
import 'pantalla_muestras.dart';
import 'pantalla_sync.dart';
import 'skeleton_painter.dart';

void main() {
  runApp(const UnivozApp());
}

class UnivozApp extends StatelessWidget {
  const UnivozApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UNIVOZ',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const PantallaMenu(),
    );
  }
}

class PantallaMenu extends StatefulWidget {
  const PantallaMenu({Key? key}) : super(key: key);

  @override
  State<PantallaMenu> createState() => _PantallaMenuState();
}

class _PantallaMenuState extends State<PantallaMenu> {
  final _almacen = AlmacenMuestras.instancia;
  bool _permisoCamara = false;
  bool _pidiendo = true;

  @override
  void initState() {
    super.initState();
    _almacen.addListener(_alCambiar);
    _inicializar();
  }

  Future<void> _inicializar() async {
    await _almacen.cargar();
    await _pedirPermisos();
  }

  void _alCambiar() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _almacen.removeListener(_alCambiar);
    super.dispose();
  }

  Future<void> _pedirPermisos() async {
    setState(() => _pidiendo = true);
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() {
      _permisoCamara = status.isGranted;
      _pidiendo = false;
    });
  }

  /// Al volver de cualquier pantalla se refresca el menu: los contadores de
  /// muestras cambian al grabar.
  Future<void> _ir(Widget pantalla) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => pantalla),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_pidiendo) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_permisoCamara) {
      return Scaffold(
        appBar: AppBar(title: const Text('UNIVOZ')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.camera_alt_outlined, size: 64),
                const SizedBox(height: 16),
                const Text('Se necesita acceso a la cámara',
                    textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  'Sin cámara no se pueden ni reconocer ni grabar señas.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _pedirPermisos,
                  child: const Text('Permitir acceso'),
                ),
                TextButton(
                  onPressed: openAppSettings,
                  child: const Text('Abrir ajustes del sistema'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final total = _almacen.total;
    final palabras = _almacen.porGlosa.length;
    final sinSubir = _almacen.sinSubir.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('UNIVOZ'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _tarjeta(
            icono: Icons.record_voice_over,
            color: Colors.blue,
            titulo: 'Reconocer seña',
            detalle: 'Hacé una seña frente a la cámara y ver qué palabra es.',
            onTap: () => _ir(const PantallaDeTranslacion()),
          ),
          _tarjeta(
            icono: Icons.add_a_photo_outlined,
            color: Colors.green,
            titulo: 'Agregar muestras',
            detalle:
                'Grabá una seña y etiquetala con su palabra. Cuantas más muestras, mejor reconoce.',
            onTap: () => _ir(const PantallaCaptura()),
          ),
          _tarjeta(
            icono: Icons.folder_outlined,
            color: Colors.deepPurple,
            titulo: 'Mis muestras',
            detalle: total == 0
                ? 'Todavía no grabaste ninguna en este teléfono.'
                : '$total muestras · $palabras palabras. Revisar, borrar o exportar.',
            onTap: () => _ir(const PantallaMuestras()),
          ),
          _tarjeta(
            icono: Icons.sync,
            color: Colors.teal,
            titulo: 'Sincronizar',
            detalle: sinSubir > 0
                ? '$sinSubir muestra(s) sin subir. Subir a la base y bajar el diccionario del equipo.'
                : 'Subir tus muestras a la base y bajar el diccionario del equipo.',
            onTap: () => _ir(const PantallaSync()),
          ),
          _tarjeta(
            icono: Icons.view_in_ar,
            color: Colors.indigo,
            titulo: 'Avatar 3D',
            detalle:
                'Escribí, elegí de una lista o decí una palabra en voz alta y un avatar hace la seña.',
            onTap: () => _ir(const PantallaAvatar()),
          ),
          _tarjeta(
            icono: Icons.flip_camera_android_outlined,
            color: Colors.pink,
            titulo: 'Espejo',
            detalle:
                'Movéte frente a la cámara y el avatar te copia en vivo. Sirve para ver si el seguimiento te lee bien.',
            onTap: () => _ir(const PantallaEspejo()),
          ),
          _tarjeta(
            icono: Icons.tune,
            color: Colors.orange,
            titulo: 'Ajustes',
            detalle:
                'Calibrar los umbrales de reconocimiento, cámara frontal/trasera y espejo.',
            onTap: () => _ir(const PantallaAjustes()),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Las muestras que grabás acá cuentan para el reconocimiento al '
              'instante, sin internet. Desde "Sincronizar" las subís a la base '
              'del equipo (quedan pendientes de aprobación) y te bajás el '
              'diccionario aprobado para usarlo offline.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tarjeta({
    required IconData icono,
    required MaterialColor color,
    required String titulo,
    required String detalle,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: color.shade50,
                child: Icon(icono, color: color.shade700, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titulo,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(detalle,
                        style: TextStyle(
                            fontSize: 13, color: Colors.grey.shade700)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }
}
