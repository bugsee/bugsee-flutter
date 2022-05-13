const String BUGSEE_VERSION = '99.99.99';

String _applicationVersion = '';

void setApplicationVersionInternal(String version) {
  _applicationVersion = version;
}

String getApplicationVersionInternal() {
  return _applicationVersion;
}

bool isApplicationVersionSet() {
  return (_applicationVersion != '');
}
