/// Datos del proyecto de Supabase que usa la app.
///
/// IMPORTANTE -- que va aca y que NO:
///
///   SI  va la clave PUBLISHABLE (sb_publishable_...), antes llamada "anon".
///       Esta hecha para vivir en el cliente: no da ningun permiso por si
///       misma, todo lo que se puede hacer con ella lo decide row level
///       security del lado del servidor (ver sql/002_app_acceso.sql).
///
///   NO  va NUNCA la clave secreta (sb_secret_... / service_role). Esa
///       ignora row level security y da acceso total: quien la extraiga del
///       APK puede borrar el diccionario entero. Vive solo en el .env de la
///       PC, para los scripts de tools/.
///
/// Si estos valores no coinciden con tu panel (Settings -> API), corregilos
/// aca: son los unicos dos que la app necesita.
library config_supabase;

const String kSupabaseUrl = 'https://soqqttribtsfypmgpayj.supabase.co';

/// Settings -> API -> Publishable key.
const String kSupabasePublishableKey =
    'sb_publishable_NiMvQHg-z6-zRSA4IVRwaA_pH8i8Gpc';

/// True si hay algo cargado. Con esto en false la app sigue funcionando
/// entera, solo que sin sincronizar (muestras locales y paquete del APK).
bool get haySupabaseConfigurado =>
    kSupabaseUrl.isNotEmpty && kSupabasePublishableKey.isNotEmpty;
