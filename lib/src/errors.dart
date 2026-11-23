// Errors the facade methods other than `launch` raise. Public. `BugseeException` itself is in
// launch.dart (it is the base of `BugseeLaunchException` too).
import 'launch.dart';

/// An argument a facade method cannot honour, found before anything reached the SDK: an empty
/// event name, a trace value that is not a string, number or bool, event parameters with a value
/// the SDKs cannot carry, a severity or level the SDKs do not have.
///
/// Never carries the offending VALUE (it may be user data, and the SDK's own log ships in every
/// report): [argument] names the parameter and the message says what was wrong with it.
class BugseeArgumentException extends BugseeException {
  const BugseeArgumentException(this.argument, super.message, {super.cause});

  /// The parameter that was wrong, e.g. `name`, `value`, `params.address.zip`.
  final String argument;

  @override
  String toString() => 'BugseeArgumentException($argument): $message';
}

/// Why an attribute call failed.
enum AttributeFailure {
  /// The name is empty.
  invalidName,

  /// The value is not a string, `bool`, `int` or finite `double`, or is outside what the SDKs
  /// can store (a string over 1024 UTF-16 units, a number the SDKs cannot represent).
  invalidValue,

  /// The SDK took the call and did not keep the value: it is over the SDK's size limit (one value
  /// or all of them together; the limits differ between Android and iOS) or the SDK could not
  /// store it. Nothing changed: the previous value of that attribute, if any, is kept (iOS deletes
  /// it while refusing, so the plugin writes it back).
  rejected,
}

/// An attribute call failed. [reason] says why.
///
/// Deliberately NOT a [BugseeArgumentException]: `rejected` is the SDK's own refusal after the
/// call reached it (a size limit), and `on BugseeArgumentException` must keep meaning "found before
/// anything reached the SDK". `invalidName` and `invalidValue` are the Dart-side findings.
class BugseeAttributeException extends BugseeException {
  const BugseeAttributeException(
    this.reason,
    this.argument,
    super.message, {
    super.cause,
  });

  final AttributeFailure reason;

  /// The parameter at fault: `name` or `value`.
  final String argument;

  @override
  String toString() =>
      'BugseeAttributeException(${reason.name}, $argument): $message';
}

/// The strings the bridge carries for a facade failure (a PlatformException's `code`), in one
/// place on the Dart side. Repeated in `FacadeOps.java` and `BGSFlutterFacadeOps.m`;
/// `test/facade_drift_test.dart` compares the three.
abstract final class FacadeWire {
  /// The native side refused an argument (it defends again; Dart has validated already).
  static const invalidArgument = 'invalid-argument';

  /// An attribute the SDK did not keep.
  static const attributeRejected = 'attribute-rejected';

  /// The SDK threw.
  static const sdkError = 'sdk-error';

  /// The plugin is not attached to an engine.
  static const notAttached = 'not-attached';
}
