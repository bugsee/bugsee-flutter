// Argument validation for the facade, in Dart, before anything crosses the bridge. Internal.
//
// The rules are what both SDKs can carry, read from their source (see doc/api-surface.md); the
// native sides defend again, and `test/facade_drift_test.dart` compares the numbers repeated
// there. A rule that only ONE platform needs is still applied to both: a call that works on one
// platform and is silently dropped on the other is the failure this exists to prevent.
import '../errors.dart';

/// Android's longest attribute string, in UTF-16 units (`BugseeAttributes`:
/// `CUSTOM_ATTRIBUTE_MAX_LENGTH_LIMIT`, inclusive). Dart's `String.length` counts the same units.
/// iOS's own limit is on the archived size (1124 bytes, about 800 ASCII characters); the native
/// read-back detects what it dropped ([AttributeFailure.rejected]).
const int attributeStringMaxLength = 1024;

/// Android stores a non-integer attribute as a 32-bit float and refuses a double at or above
/// `Float.MAX_VALUE` without a word; one bound for both platforms.
const double attributeNumberLimit = 3.4028234663852886e38;

/// The bound for a number that reaches a report bundle (event parameters, trace values): finite and
/// below 2^63 in magnitude. Android's JSON writer turns a double at or beyond `Long.MAX_VALUE` into
/// `9223372036854775807`, so it must be refused before that point.
const double bundleNumberLimit = 9223372036854775808.0;

/// Nesting deeper than this in event parameters is almost certainly a cycle.
const int eventParamsMaxDepth = 16;

String _typeOf(Object? v) => v == null ? 'null' : v.runtimeType.toString();

/// A non-empty attribute name.
String checkAttributeName(String name) {
  if (name.isEmpty) {
    throw const BugseeAttributeException(
      AttributeFailure.invalidName,
      'name',
      'an attribute name must not be empty',
    );
  }
  return name;
}

/// An attribute value both SDKs store: a [String] of at most [attributeStringMaxLength] UTF-16
/// units, a [bool], an [int], or a finite [double] below [attributeNumberLimit] in magnitude.
Object checkAttributeValue(Object? value) {
  if (value is String) {
    if (value.length > attributeStringMaxLength) {
      throw const BugseeAttributeException(
        AttributeFailure.invalidValue,
        'value',
        'an attribute string must be at most $attributeStringMaxLength UTF-16 units '
            '(use an attachment for large data)',
      );
    }
    return value;
  }
  if (value is bool || value is int) return value!;
  if (value is double) {
    if (!value.isFinite || value.abs() >= attributeNumberLimit) {
      throw const BugseeAttributeException(
        AttributeFailure.invalidValue,
        'value',
        'an attribute number must be finite and smaller than the largest 32-bit float in '
            'magnitude (Android stores it as one)',
      );
    }
    return value;
  }
  throw BugseeAttributeException(
    AttributeFailure.invalidValue,
    'value',
    'an attribute value must be a String, bool, int or double, not ${_typeOf(value)}',
  );
}

/// A non-empty event or trace name.
String checkDataName(String kind, String name) {
  if (name.isEmpty) {
    throw BugseeArgumentException('name', 'a $kind name must not be empty');
  }
  return name;
}

void _checkNumber(num value, String path) {
  if (value is double && !value.isFinite) {
    throw BugseeArgumentException(path, '$path must be a finite number');
  }
  if (value is double && value.abs() >= bundleNumberLimit) {
    throw BugseeArgumentException(
      path,
      '$path must be smaller than 2^63 in magnitude',
    );
  }
}

/// A trace value: a [String], a [bool], an [int] or a finite [double] (below 2^63 in magnitude).
Object checkTraceValue(Object? value) {
  if (value is String || value is bool || value is int) return value!;
  if (value is double) {
    _checkNumber(value, 'value');
    return value;
  }
  throw BugseeArgumentException(
    'value',
    'a trace value must be a String, bool, int or double, not ${_typeOf(value)}',
  );
}

/// A fresh copy of [params] (so changing the original later cannot change what already crossed),
/// after checking every value is one both SDKs carry: `null`, [bool], [num] (finite, below 2^63),
/// [String], a [List] of those, a `Map<String, ...>` of those; at most [eventParamsMaxDepth]
/// levels deep, no cycles. [path] names the argument in an error.
Map<String, Object?> copyEventParams(
  Map<String, Object?> params, {
  String path = 'params',
}) => _copyMap(params, path, 1, Set<Object>.identity());

Map<String, Object?> _copyMap(
  Map<Object?, Object?> map,
  String path,
  int depth,
  Set<Object> ancestors,
) {
  _enter(map, path, depth, ancestors);
  try {
    final out = <String, Object?>{};
    for (final e in map.entries) {
      final key = e.key;
      if (key is! String) {
        throw BugseeArgumentException(
          path,
          '$path has a key that is not a String (${_typeOf(key)})',
        );
      }
      out[key] = _copyValue(e.value, '$path.$key', depth + 1, ancestors);
    }
    return out;
  } finally {
    ancestors.remove(map);
  }
}

List<Object?> _copyList(
  List<Object?> list,
  String path,
  int depth,
  Set<Object> ancestors,
) {
  _enter(list, path, depth, ancestors);
  try {
    return [
      for (var i = 0; i < list.length; i++)
        _copyValue(list[i], '$path[$i]', depth + 1, ancestors),
    ];
  } finally {
    ancestors.remove(list);
  }
}

void _enter(Object node, String path, int depth, Set<Object> ancestors) {
  if (depth > eventParamsMaxDepth) {
    throw BugseeArgumentException(
      path,
      '$path nests deeper than the maximum of $eventParamsMaxDepth',
    );
  }
  if (!ancestors.add(node)) {
    throw BugseeArgumentException(path, '$path contains itself');
  }
}

Object? _copyValue(
  Object? value,
  String path,
  int depth,
  Set<Object> ancestors,
) {
  if (value == null || value is String || value is bool) return value;
  if (value is num) {
    _checkNumber(value, path);
    return value;
  }
  if (value is Map<Object?, Object?>) {
    return _copyMap(value, path, depth, ancestors);
  }
  if (value is List<Object?>) return _copyList(value, path, depth, ancestors);
  throw BugseeArgumentException(
    path,
    '$path must be null, a bool, a number, a String, a List or a Map, not ${_typeOf(value)}',
  );
}

/// The labels of a report as the SDKs take them: strings, none empty.
List<String> checkLabels(List<String> labels) {
  for (final l in labels) {
    if (l.isEmpty) {
      throw const BugseeArgumentException(
        'labels',
        'a label must not be empty',
      );
    }
  }
  return List<String>.of(labels);
}
