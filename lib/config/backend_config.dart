/// Single source of truth for the cloud backend's address.
///
/// The backend is the FastAPI server in `backend/` (default port 8000; see
/// `backend/docs/API_CONTRACT.md`). It replaced the old Flask server on port
/// 5000, and still serves that server's legacy endpoints with the same
/// request/response shapes, so the older screens keep working unchanged.
///
/// The app must never depend on this backend to deliver an SOS -- BLE is
/// the primary channel and must keep working with no network at all. This
/// class only centralizes the *optional* secondary HTTP paths:
///   * legacy, unauthenticated: the AI-scored rescue request and the
///     rescue-team list (`/api/rescue-request`, `/api/rescue-requests`);
///   * `/api/v1` (Bearer token): login, the current user, rescue teams and
///     the offline-sync endpoints the Windows rescue console uses to upload
///     the SOS it received over BLE (CloudSyncService).
///
/// Override at build/run time for your network, e.g.:
///   flutter run --dart-define=BACKEND_BASE_URL=http://192.168.1.42:8000
class BackendConfig {
  BackendConfig._();

  static const String baseUrl = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'http://192.168.31.250:8000',
  );

  // -- Legacy (Flask-compatible) endpoints ----------------------------------

  static String get rescueRequestEndpoint => '$baseUrl/api/rescue-request';

  static String get rescueRequestsListEndpoint =>
      '$baseUrl/api/rescue-requests';

  // -- /api/v1 paths (relative; join with any base URL) ---------------------

  static const String apiV1Prefix = '/api/v1';
  static const String authLoginPath = '$apiV1Prefix/auth/login';
  static const String authMePath = '$apiV1Prefix/auth/me';
  static const String rescueTeamsPath = '$apiV1Prefix/rescue-teams';
  static const String syncEmergenciesPath = '$apiV1Prefix/sync/emergencies';
  static const String syncStatusPath = '$apiV1Prefix/sync/status';

  // -- /api/v1 endpoints on [baseUrl] ---------------------------------------

  static String get authLoginEndpoint => '$baseUrl$authLoginPath';

  static String get authMeEndpoint => '$baseUrl$authMePath';

  static String get rescueTeamsEndpoint => '$baseUrl$rescueTeamsPath';

  static String get syncEmergenciesEndpoint => '$baseUrl$syncEmergenciesPath';

  static String get syncStatusEndpoint => '$baseUrl$syncStatusPath';
}
