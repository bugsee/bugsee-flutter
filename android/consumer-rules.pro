# Consumer rules: applied to every app that depends on bugsee_flutter.
#
# The backend routes a Dart error on this class name (worker crash/managed/__init__.py), so R8 must
# not rename it (doc/exceptions.md). The document it carries also names the type, so a build that
# lost this rule is still routed, but the name is the primary contract.
-keepnames class com.bugsee.flutter.FlutterManagedException
