/// The app's version, from the build (CI passes --dart-define WINNOW_VERSION=x.y.z).
const version = String.fromEnvironment('WINNOW_VERSION', defaultValue: '0.0.0-dev');
