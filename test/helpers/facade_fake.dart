// A native end for the facade tests: records every call with its arguments and answers as
// scripted. Everything the lifecycle/launch side needs is a no-op.
import 'package:bugsee_flutter/src/bridge/messages.g.dart';
import 'package:flutter/services.dart' show PlatformException;

class FacadeFake extends BugseeBridgeHostApi {
  /// `name(arg, arg)` per call, in order.
  final List<String> calls = [];

  /// The structured arguments of the last call to each method.
  final Map<String, List<Object?>> last = {};

  /// When set, the next facade call throws it (once).
  PlatformException? failNext;

  /// Always thrown by calls to this method name.
  final Map<String, PlatformException> failing = {};

  Object? attributeValue;
  Map<String, Object> allAttributes = {};
  String? userIdentifier;
  bool breadcrumbAccepted = true;
  bool blackout = false;

  Phases? phases;

  /// How many times the plugin was attached (the lifecycle channel).
  int attachCount = 0;

  T _record<T>(String name, List<Object?> args, T result) {
    calls.add('$name(${args.join(', ')})');
    last[name] = args;
    final failure = failing[name] ?? failNext;
    if (failure != null) {
      if (identical(failure, failNext)) failNext = null;
      throw failure;
    }
    return result;
  }

  @override
  Future<void> attachLifecycle() async {
    attachCount++;
  }

  @override
  Future<void> resetReportHandlers() async {}

  @override
  Future<void> setWrapperIdentity(WrapperIdentityMessage identity) async {}

  @override
  Future<void> setReportHandlerPhases(bool before, bool after) async {
    phases = Phases(before, after);
    calls.add('phases($before, $after)');
  }

  @override
  Future<void> setAttribute(String name, Object value) async =>
      _record('setAttribute', [name, value], null);

  @override
  Future<Object?> getAttribute(String name) async =>
      _record('getAttribute', [name], attributeValue);

  @override
  Future<Map<String, Object>> getAllAttributes() async =>
      _record('getAllAttributes', [], allAttributes);

  @override
  Future<void> clearAttribute(String name) async =>
      _record('clearAttribute', [name], null);

  @override
  Future<void> clearAllAttributes() async =>
      _record('clearAllAttributes', [], null);

  @override
  Future<void> setUserIdentifier(String? identifier) async =>
      _record('setUserIdentifier', [identifier], null);

  @override
  Future<String?> getUserIdentifier() async =>
      _record('getUserIdentifier', [], userIdentifier);

  @override
  Future<void> trace(String name, Object value) async =>
      _record('trace', [name, value], null);

  @override
  Future<void> event(String name, Map<String, Object?>? params) async =>
      _record('event', [name, params], null);

  @override
  Future<bool> addBreadcrumb(BreadcrumbMessage breadcrumb) async =>
      _record('addBreadcrumb', [
        breadcrumb.category,
        breadcrumb.level,
        breadcrumb.message,
        breadcrumb.type,
        breadcrumb.data,
      ], breadcrumbAccepted);

  @override
  Future<void> relayNotification(
    String title,
    String? body,
    int? severity,
    List<String>? fields,
    bool urgent,
  ) async => _record('relayNotification', [
    title,
    body,
    severity,
    fields,
    urgent,
  ], null);

  @override
  Future<void> log(String message, int level) async =>
      _record('log', [message, level], null);

  @override
  Future<void> startBlackout() async {
    _record('startBlackout', [], null);
    blackout = true;
  }

  @override
  Future<void> endBlackout() async {
    _record('endBlackout', [], null);
    blackout = false;
  }

  @override
  Future<bool> isBlackout() async => _record('isBlackout', [], blackout);

  @override
  Future<void> showReportDialog(
    String? summary,
    String? description,
    int? severity,
    List<String>? labels,
  ) async => _record('showReportDialog', [
    summary,
    description,
    severity,
    labels,
  ], null);

  @override
  Future<void> upload(
    String summary,
    String description,
    int? severity,
    List<String>? labels,
  ) async => _record('upload', [summary, description, severity, labels], null);
}

class Phases {
  const Phases(this.before, this.after);
  final bool before;
  final bool after;
  @override
  String toString() => 'Phases($before, $after)';
}

PlatformException refusal(String code, [String message = 'refused']) =>
    PlatformException(code: code, message: message);
