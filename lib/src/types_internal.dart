import 'dart:ffi';
import 'dart:math';
import 'dart:convert';

import 'types.dart';
import 'utils.dart';

class BugseeNetworkEventImpl extends BugseeNetworkEvent {
  String _internalMethod = '';
  String _internalEventType = "";

  @override
  String get method => _internalMethod;
  @override
  String get type => _internalEventType;

  /// Convert raw event data received from the native layer
  /// into the class instance with proper fields
  static BugseeNetworkEvent? fromRawEvent(dynamic event) {
    if (event == null) {
      return null;
    }

    BugseeNetworkEventImpl wrappedEvent = BugseeNetworkEventImpl();
    wrappedEvent._internalMethod = tryCast(event['method'], '');
    wrappedEvent._internalEventType = tryCast(event['type'], '');
    wrappedEvent.url = tryCast(event['url'], '');
    wrappedEvent.redirectUrl = tryCast(event['redirectUrl'], null);
    // set <body> and <headers> to <null> by default
    wrappedEvent.headers = null;
    wrappedEvent.body = null;

    dynamic rawHeaders = event['headers'];
    if (rawHeaders != null) {
      if (rawHeaders is Map) {
        try {
          Map<String, dynamic> castMap = rawHeaders.cast<String, dynamic>();
          // cast operation above creates a wrapper around
          // original Map (aka <CastMap>), hence to get
          // the pristine map, we just copy the contents
          // of the casted map below
          wrappedEvent.headers = {...castMap};
          // ignore: unused_catch_clause
        } catch (e) {
          wrappedEvent.headers = null;
        }
      } else {
        wrappedEvent.headers = null;
      }
    }

    dynamic rawBody = event['body'];
    if (rawBody != null) {
      // body may be represented as Uint#List (where #
      // is either 8, 16, 32 or 64). In this case, try
      // decoding it as UTF-8 string
      if (rawBody is List<int>) {
        try {
          wrappedEvent.body = utf8.decode(rawBody);
          // ignore: unused_catch_clause
        } catch (e) {
          wrappedEvent.body = null;
        }
      } else {
        wrappedEvent.body = tryCast(rawBody, null);
      }
    }

    return wrappedEvent;
  }

  /// Convert class instance denoting the network event into
  /// the raw event data to pass it back to the native layer
  static dynamic augmentAndExtendOriginalEvent(
      dynamic originalEvent, BugseeNetworkEvent? e) {
    if (e == null) {
      return null;
    }

    originalEvent['url'] = e.url;
    originalEvent['body'] = e.body;
    originalEvent['redirectUrl'] = e.redirectUrl;
    originalEvent['headers'] = e.headers;

    return originalEvent;
  }
}

typedef BugseeAdditionalDataCaptureCallback = String? Function(String kind);

class ViewHierarchyItem {
  String id = "";
  Rectangle bounds = Rectangle(0, 0, 0, 0);
  String className = "";
  String? baseClassName;
  Map<String, dynamic>? options;
  List<ViewHierarchyItem>? subitems;

  ViewHierarchyItem(this.id, this.bounds, this.className);

  Map<String, dynamic> toMap() {
    Map<String, dynamic> map = {
      "id": id,
      "bounds": [bounds.left, bounds.top, bounds.width, bounds.height],
      "class_name": className
    };
    if (baseClassName != null) {
      map["base_class_name"] = baseClassName;
    }
    if (options != null) {
      map["options"] = options;
    }
    if (subitems != null) {
      map["subitems"] = subitems!.map((item) => item.toMap()).toList();
    }
    return map;
  }
}
