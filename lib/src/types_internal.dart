import 'dart:math';

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
    wrappedEvent.body = tryCast(event['body'], null);
    wrappedEvent.redirectUrl = tryCast(event['redirectUrl'], null);
    wrappedEvent.headers = tryCast(event['headers'], null);

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
