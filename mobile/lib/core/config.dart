/// Backend base URL, e.g. `http://localhost:8080/api/v1`, passed with
/// `--dart-define-from-file=config/api.local.json`. Empty = demo mode.
const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

/// true when the app should talk to the backend.
bool get useApi => apiBaseUrl.isNotEmpty;
