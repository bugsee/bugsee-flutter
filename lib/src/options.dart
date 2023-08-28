import 'dart:io' show Platform;
import 'dart:math';

import 'constants.dart';
import 'enums.dart';
import 'utils.dart';
import 'version.dart';

/// Base launch options class
abstract class BugseeLaunchOptions {
  final Map<String, dynamic> _optionsMap = <String, dynamic>{};

  Map<String, dynamic> toMap() {
    return Map<String, dynamic>.from(_optionsMap);
  }

  dynamic operator [](String index) => _optionsMap[index];
  void operator []=(String index, dynamic value) {
    _optionsMap[index] = value;
  }

  void setDefaults() {
    // set wrapper info
    _optionsMap['wrapper_info'] = {
      'type': 'flutter',
      'version': bugseeVersion,
      'build': '0'
    };

    maxRecordingTime = constOptionMaxRecordingTime;
    shakeToReport = constOptionShakeToReport;
    crashReport = constOptionCrashReport;
    videoEnabled = constOptionVideoEnabled;
    videoScale = constOptionVideoScale;
    captureLogs = constOptionCaptureLogs;
    monitorNetwork = constOptionMonitorNetwork;
    screenshotEnabled = constOptionScreenshotEnabled;
    maxDataSize = constOptionMaxDataSize;
    reportPrioritySelector = constOptionReportPrioritySelector;
    defaultCrashPriority = constOptionDefaultCrashPriority;
    defaultBugPriority = constOptionDefaultBugPriority;
    frameRate = constOptionFrameRate;
    wifiOnlyUpload = constOptionWiFiOnlyUpload;
    maxNetworkBodySize = constOptionMaxNetworkBodySize;
    captureDeviceAndNetworkNames = constOptionCaptureDeviceAndNetworkNames;
    viewHierarchyEnabled = constOptionViewHierarchyEnabled;
    reportSummaryRequired = constOptionReportSummaryRequired;
    reportDescriptionRequired = constOptionReportDescriptionRequired;
    reportEmailRequired = constOptionReportEmailRequired;
    reportLabelsEnabled = constOptionReportLabelsEnabled;
    reportLabelsRequired = constOptionReportLabelRequired;
  }

  /// Adds specified custom launch option
  void setCustomOption(String key, dynamic value) {
    this[key] = value;
  }

  /// Video capturing frame rate
  BugseeFrameRate get frameRate => BugseeFrameRate
      .values[tryCast(this["FrameRate"], constOptionFrameRate.index + 1) - 1];
  set frameRate(BugseeFrameRate frameRate) {
    this["FrameRate"] = frameRate.index + 1;
  }

  /// Maximum recording duration
  int get maxRecordingTime =>
      tryCast(this["MaxRecordingTime"], constOptionMaxRecordingTime);
  set maxRecordingTime(int value) {
    this["MaxRecordingTime"] = value;
  }

  /// Shake gesture to trigger report
  bool get shakeToReport =>
      tryCast(this["ShakeToReport"], constOptionShakeToReport);
  set shakeToReport(bool value) {
    this["ShakeToReport"] = value;
  }

  /// Catch and report application crashes
  bool get crashReport => tryCast(this["CrashReport"], constOptionCrashReport);
  set crashReport(bool value) {
    this["CrashReport"] = value;
  }

  /// Enable video recording
  bool get videoEnabled =>
      tryCast(this["VideoEnabled"], constOptionVideoEnabled);
  set videoEnabled(bool value) {
    this["VideoEnabled"] = value;
  }

  /// Enable video recording
  double get videoScale => tryCast(this["VideoScale"], constOptionVideoScale);
  set videoScale(double value) {
    this["VideoScale"] = max(value, 0.0);
  }

  /// Automatically capture all console logs
  bool get captureLogs => tryCast(this["CaptureLogs"], constOptionCaptureLogs);
  set captureLogs(bool value) {
    this["CaptureLogs"] = value;
  }

  /// Capture network traffic
  bool get monitorNetwork =>
      tryCast(this["MonitorNetwork"], constOptionMonitorNetwork);
  set monitorNetwork(bool value) {
    this["MonitorNetwork"] = value;
  }

  /// Allow user to modify priority when reporting manually
  bool get reportPrioritySelector => tryCast(
      this["BugseeReportPrioritySelector"], constOptionReportPrioritySelector);
  set reportPrioritySelector(bool value) {
    this["BugseeReportPrioritySelector"] = value;
  }

  /// Default priority for crashes
  BugseeSeverityLevel get defaultCrashPriority =>
      BugseeSeverityLevel.values[tryCast(this["BugseeDefaultCrashPriority"],
              constOptionDefaultCrashPriority.index + 1) -
          1];
  set defaultCrashPriority(BugseeSeverityLevel value) {
    this["BugseeDefaultCrashPriority"] = value.index + 1;
  }

  /// Default priority for bugs
  BugseeSeverityLevel get defaultBugPriority =>
      BugseeSeverityLevel.values[tryCast(this["BugseeDefaultBugPriority"],
              constOptionDefaultBugPriority.index + 1) -
          1];
  set defaultBugPriority(BugseeSeverityLevel value) {
    this["BugseeDefaultBugPriority"] = value.index + 1;
  }

  /// Attach screenshot to a report.
  bool get screenshotEnabled =>
      tryCast(this["ScreenshotEnabled"], constOptionScreenshotEnabled);
  set screenshotEnabled(bool value) {
    this["ScreenshotEnabled"] = value;
  }

  /// Enable View hierarchy capturing
  bool get viewHierarchyEnabled =>
      tryCast(this["ViewHierarchyEnabled"], constOptionViewHierarchyEnabled);
  set viewHierarchyEnabled(bool value) {
    this["ViewHierarchyEnabled"] = value;
  }

  /// Upload reports only when a device is connected to a wifi network.
  bool get wifiOnlyUpload =>
      tryCast(this["WifiOnlyUpload"], constOptionWiFiOnlyUpload);
  set wifiOnlyUpload(bool value) {
    this["WifiOnlyUpload"] = value;
  }

  /// Bugsee will avoid using more disk space than specified (in MB). If total Bugsee data size exceeds
  /// specified value, oldest recordings (even not sent) will be removed. Value should not be smaller
  /// than 10.
  int get maxDataSize => tryCast(this["MaxDataSize"], constOptionMaxDataSize);
  set maxDataSize(int value) {
    this["MaxDataSize"] = value;
  }

  /// The maximal size of network request/response body.
  int get maxNetworkBodySize =>
      tryCast(this["bodySizeLimit"], constOptionMaxNetworkBodySize);
  set maxNetworkBodySize(int value) {
    this["bodySizeLimit"] = value;
  }

  bool get captureDeviceAndNetworkNames => tryCast(
      this["CaptureDeviceAndNetworkNames"],
      constOptionCaptureDeviceAndNetworkNames);
  set captureDeviceAndNetworkNames(bool value) {
    this["CaptureDeviceAndNetworkNames"] = value;
  }

  /// Controls whether Summary field is defined as mandatory in bug reporting UI
  bool get reportSummaryRequired =>
      tryCast(this["ReportSummaryRequired"], constOptionReportSummaryRequired);
  set reportSummaryRequired(bool value) {
    this["ReportSummaryRequired"] = value;
  }

  /// Controls whether Description field is defined as mandatory in bug reporting UI
  bool get reportDescriptionRequired => tryCast(
      this["ReportDescriptionRequired"], constOptionReportDescriptionRequired);
  set reportDescriptionRequired(bool value) {
    this["ReportDescriptionRequired"] = value;
  }

  /// Controls whether Email field is defined as mandatory in bug reporting UI
  bool get reportEmailRequired =>
      tryCast(this["ReportEmailRequired"], constOptionReportEmailRequired);
  set reportEmailRequired(bool value) {
    this["ReportEmailRequired"] = value;
  }

  /// Controls whether Labels field is enabled in bug reporting UI
  bool get reportLabelsEnabled =>
      tryCast(this["ReportLabelsEnabled"], constOptionReportLabelsEnabled);
  set reportLabelsEnabled(bool value) {
    this["ReportLabelsEnabled"] = value;
  }

  /// Controls whether Labels field is defined as mandatory in bug reporting UI
  bool get reportLabelsRequired =>
      tryCast(this["ReportLabelsRequired"], constOptionReportLabelRequired);
  set reportLabelsRequired(bool value) {
    this["ReportLabelsRequired"] = value;
  }
}

/// Bugsee launch options for iOS
class IOSLaunchOptions extends BugseeLaunchOptions {
  IOSLaunchOptions() : super() {
    setDefaults();
  }

  @override
  void setDefaults() {
    super.setDefaults();

    style = constOptionStyle;
    screenshotToReport = constOptionScreenshotToReport;
    killDetection = constOptionKillDetection;
    monitorBluetoothStatus = constOptionMonitorBluetoothStatus;
  }

  /// Defines the style which is used in Bugsee reporting UI
  BugseeIosVisualStyle get style => BugseeIosVisualStyle
      .values[tryCast(this["BugseeStyle"], constOptionStyle.index + 1) - 1];
  set style(BugseeIosVisualStyle value) {
    this["BugseeStyle"] = value.index + 1;
  }

  /// Screenshot key to trigger report
  bool get screenshotToReport =>
      tryCast(this["ScreenshotToReport"], constOptionScreenshotToReport);
  set screenshotToReport(bool value) {
    this["ScreenshotToReport"] = value;
  }

  /// Detect abnormal termination (experimental)
  bool get killDetection =>
      tryCast(this["BugseeKillDetectionKey"], constOptionKillDetection);
  set killDetection(bool value) {
    this["BugseeKillDetectionKey"] = value;
  }

  /// Constantly monitor Bluetooth status
  bool get monitorBluetoothStatus => tryCast(
      this["MonitorBluetoothStatus"], constOptionMonitorBluetoothStatus);
  set monitorBluetoothStatus(bool value) {
    this["MonitorBluetoothStatus"] = value;
  }

  /// Controls Video players capture. If set to true,
  /// Bugsee will capture video in both inline and
  /// standalone video players. May incur some performance
  /// penalty.
  bool get captureAVPlayer =>
      tryCast(this["CaptureAVPlayer"], constOptionCaptureAVPlayer);
  set captureAVPlayer(bool value) {
    this["CaptureAVPlayer"] = value;
  }
}

class AndroidLaunchOptions extends BugseeLaunchOptions {
  AndroidLaunchOptions() : super() {
    setDefaults();
  }

  @override
  void setDefaults() {
    super.setDefaults();

    notificationBarTrigger = constOptionNotificationBarTrigger;
    serviceMode = constOptionServiceMode;
    // default is set to V3 to make sure we capture
    // what Flutter is rendering onto the GL surface
    videoMode = constOptionVideoMode;
    // this is required as V3 is not allowed on
    // some devices (e.g. Samsung), but is
    // required for Flutter as it renders its
    // UI onto GL surface
    this["forceVideoModeV3"] = constOptionForceVideoModeV3;
    // Some widgets, such as InAppWebView, don't draw on FlutterSurfaceView, unlike other standard widgets.
    // So, to capture everything on screen, we need to do it from a window and from a surfaceView.
    this["forceDrawAllSurfaces"] = constOptionForceDrawAllSurfaces;
  }

  /// Video capture mode
  BugseeVideoMode get videoMode => BugseeVideoMode
      .values[tryCast(this["VideoMode"], constOptionVideoMode.index)];
  set videoMode(BugseeVideoMode value) {
    this["VideoMode"] = value.index;
  }

  /// Whether application Bugsee is contained within is running as service
  bool get serviceMode => tryCast(this["ServiceMode"], constOptionServiceMode);
  set serviceMode(bool value) {
    this["ServiceMode"] = value;
  }

  ///
  bool get notificationBarTrigger => tryCast(
      this["NotificationBarTrigger"], constOptionNotificationBarTrigger);
  set notificationBarTrigger(bool value) {
    this["NotificationBarTrigger"] = value;
  }
}

BugseeLaunchOptions? getDefaultLaunchOptions() {
  if (Platform.isIOS) {
    return IOSLaunchOptions();
  }

  if (Platform.isAndroid) {
    return AndroidLaunchOptions();
  }

  return null;
}
