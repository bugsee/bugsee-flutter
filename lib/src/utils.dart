import 'package:flutter/widgets.dart';

T tryCast<T>(dynamic x, T fallback) {
  try {
    return (x as T);
    // ignore: unused_catch_clause
  } on TypeError catch (e) {
    return fallback;
  }
}

String shortHash(Object o) {
  return o.hashCode.toUnsigned(20).toRadixString(16).padLeft(5, '0');
}

String generateUniqueID() {
  final uKeyPrefix = UniqueKey();
  final uKeySuffix = UniqueKey();
  final now = DateTime.now();
  final String uKeyPrefixString = shortHash(uKeyPrefix);
  final String uKeySuffixString = shortHash(uKeySuffix);
  return uKeyPrefixString +
      now.microsecondsSinceEpoch.toString() +
      uKeySuffixString;
}

int getEqualBeginningLength(String a, String b) {
  int i = 0;
  while (i < a.length && i < b.length && a[i] == b[i]) {
    i++;
  }
  return i;
}
