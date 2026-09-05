/// Lee en voz alta la seña reconocida.
///
/// Un solo FlutterTts compartido para toda la app (singleton, como
/// AlmacenMuestras): crear una instancia por pantalla duplicaria la
/// inicializacion del motor nativo de texto a voz sin ninguna ventaja.
library voz;

import 'package:flutter_tts/flutter_tts.dart';

class LectorVoz {
  static final LectorVoz instancia = LectorVoz._();
  LectorVoz._();

  final FlutterTts _tts = FlutterTts();
  bool _listo = false;

  /// Configura el motor la primera vez que hace falta, no en el arranque de
  /// la app: en un telefono sin ningun paquete de voz en español instalado
  /// esto puede tardar o fallar, y no vale la pena pagar ese costo si la
  /// persona nunca llega a usar el reconocedor.
  Future<void> _preparar() async {
    if (_listo) return;

    // OJO: en Android, FlutterTts.isLanguageAvailable() solo devuelve true
    // cuando TextToSpeech.isLanguageAvailable() da EXACTAMENTE
    // LANG_AVAILABLE -- y trata como "no disponible" tanto
    // LANG_COUNTRY_AVAILABLE como LANG_COUNTRY_VAR_AVAILABLE, que en
    // realidad son coincidencias MEJORES (idioma+pais, o idioma+pais+
    // variante). Un telefono con la voz instalada especificamente como
    // "es-MX" hace que isLanguageAvailable('es-MX') devuelva false por
    // este motivo -- y terminabamos sin llamar NUNCA a setLanguage(), sea
    // cual sea el idioma del telefono. Por eso ahora se usa getLanguages()
    // (la lista real de idiomas instalados) en vez de preguntar idioma por
    // idioma con isLanguageAvailable().
    String elegido = 'es';
    try {
      final crudos = await _tts.getLanguages as List?;
      final disponibles =
          (crudos ?? const []).map((e) => e.toString()).toList();
      String normalizar(String s) => s.replaceAll('_', '-').toLowerCase();
      final normalizados = disponibles.map(normalizar).toList();

      // es-MX antes que es-ES: en Android el motor de Google casi siempre
      // trae español latinoamericano instalado por defecto, y el de España
      // a veces no. "es" a secas al final matchea cualquier otra variante
      // instalada (es-AR, es-CO, etc.) que no hayamos previsto.
      for (final candidato in const ['es-MX', 'es-US', 'es-ES', 'es']) {
        final base = normalizar(candidato);
        final idx = normalizados.indexWhere(
          (d) => d == base || d.startsWith('$base-'),
        );
        if (idx != -1) {
          elegido = disponibles[idx];
          break;
        }
      }
    } catch (_) {
      // getLanguages no esta implementado en esta plataforma/version del
      // motor; seguimos con "es" a secas como mejor intento.
    }

    try {
      await _tts.setLanguage(elegido);
    } catch (_) {
      // Si ni "es" anda, seguimos igual -- setSpeechRate/volumen no
      // dependen del idioma, y el motor puede terminar hablando con la voz
      // que tenga puesta por defecto en vez de fallar del todo.
    }

    await _tts.setSpeechRate(0.45); // mas lento que el default: son palabras
    // sueltas fuera de contexto, no una oracion, y asi se entienden mejor.
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    try {
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {}
    _listo = true;
  }

  /// Corta lo que estuviera diciendo y dice el texto nuevo.
  ///
  /// Cortar primero importa: sin el stop(), reconocer una seña mientras
  /// todavia esta hablando la anterior encola las dos frases y se escuchan
  /// pisadas entre si en vez de la ultima seña reconocida.
  ///
  /// Devuelve null si se pudo pedir que hable, o el mensaje de error si el
  /// motor nativo tiro una excepcion -- para poder avisar en pantalla en vez
  /// de fallar en silencio sin ninguna pista de por que (lo que paso la
  /// primera vez que se probo esta funcion).
  Future<String?> decir(String texto) async {
    final t = texto.trim();
    if (t.isEmpty) return null;
    try {
      await _preparar();
      await _tts.stop();
      final res = await _tts.speak(t);
      if (res == 0) {
        return 'El motor TTS de Android devolvió error. Verifica el volumen multimedia y los servicios de voz de Google.';
      }
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> detener() => _tts.stop();
}
