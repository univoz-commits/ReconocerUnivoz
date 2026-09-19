/// Configuración opcional del AI Engine.
///
/// Se entrega en build/run con:
/// --dart-define=UNIVOZ_BACKEND_URL=http://192.168.1.10:8000
const String kBackendUrl = String.fromEnvironment('UNIVOZ_BACKEND_URL');

bool get hayBackendConfigurado => kBackendUrl.trim().isNotEmpty;
