import 'dart:async';
import 'package:flutter/services.dart';

// ignore: unnecessary_import
import 'dart:ui';

import 'utils.dart';

class BugseeAppearanceBase {
  final MethodChannel _channel;

  const BugseeAppearanceBase(MethodChannel channel) : _channel = channel;

  Future<void> _setProperty(String propertyName, Color value) async {
    await _channel.invokeMethod('setAppearanceProperty', <String, dynamic>{
      'cP': propertyName,
      'cR': value.red,
      'cG': value.green,
      'cB': value.blue,
      'cA': value.alpha,
    });
  }

  Future<Color?> _getProperty(String propertyName) async {
    Map<String, int>? rawResult =
        await _channel.invokeMethod('getAppearanceProperty', <String, dynamic>{
      'cP': propertyName,
    });

    if (rawResult != null) {
      Map<String, int> value = Map<String, int>.from(rawResult);
      int a = tryCast(value['cA'], -1);
      int r = tryCast(value['cR'], -1);
      int g = tryCast(value['cG'], -1);
      int b = tryCast(value['cB'], -1);
      if (a > -1 && r > -1 && g > -1 && b > -1) {
        return Color.fromARGB(a, r, g, b);
      }
    }

    return null;
  }

  Future<void> _setPropertyStr(String propertyName, String? value) async {
    await _channel.invokeMethod('setAppearanceProperty',
        <String, dynamic>{'cP': propertyName, 'cStr': value});
  }

  Future<String?> _getPropertyStr(String propertyName) async {
    Map<String, String>? rawResult =
        await _channel.invokeMethod('getAppearanceProperty', <String, dynamic>{
      'cP': propertyName,
    });

    if (rawResult != null) {
      Map<String, String> value = Map<String, String>.from(rawResult);
      if (value.containsKey('cStr')) {
        return value['cStr'];
      }
    }

    return null;
  }
}

class BugseeAppearanceIOS extends BugseeAppearanceBase {
  const BugseeAppearanceIOS(super.channel);

  Future<Color?> get reportCellBackgroundColor =>
      _getProperty('reportCellBackgroundColor');
  Future<void> setReportCellBackgroundColor(Color value) async {
    await _setProperty('reportCellBackgroundColor', value);
  }

  Future<Color?> get reportVersionColor => _getProperty('reportVersionColor');
  Future<void> setReportVersionColor(Color value) async {
    await _setProperty('reportVersionColor', value);
  }

  Future<Color?> get reportTextColor => _getProperty('reportTextColor');
  Future<void> setReportTextColor(Color value) async {
    await _setProperty('reportTextColor', value);
  }

  Future<Color?> get reportSendButtonColor =>
      _getProperty('reportSendButtonColor');
  Future<void> setReportSendButtonColor(Color value) async {
    await _setProperty('reportSendButtonColor', value);
  }

  Future<Color?> get reportPlaceholderColor =>
      _getProperty('reportPlaceholderColor');
  Future<void> setReportPlaceholderColor(Color value) async {
    await _setProperty('reportPlaceholderColor', value);
  }

  Future<Color?> get reportNavigationBarColor =>
      _getProperty('reportNavigationBarColor');
  Future<void> setReportNavigationBarColor(Color value) async {
    await _setProperty('reportNavigationBarColor', value);
  }

  Future<Color?> get reportBackgroundColor =>
      _getProperty('reportBackgroundColor');
  Future<void> setReportBackgroundColor(Color value) async {
    await _setProperty('reportBackgroundColor', value);
  }

  Future<Color?> get reportCloseButtonColor =>
      _getProperty('reportCloseButtonColor');
  Future<void> setReportCloseButtonColor(Color value) async {
    await _setProperty('reportCloseButtonColor', value);
  }

  Future<Color?> get feedbackBarsColor => _getProperty('feedbackBarsColor');
  Future<void> setFeedbackBarsColor(Color value) async {
    await _setProperty('feedbackBarsColor', value);
  }

  Future<Color?> get feedbackBackgroundColor =>
      _getProperty('feedbackBackgroundColor');
  Future<void> setFeedbackBackgroundColor(Color value) async {
    await _setProperty('feedbackBackgroundColor', value);
  }

  Future<Color?> get feedbackIncomingBubbleColor =>
      _getProperty('feedbackIncomingBubbleColor');
  Future<void> setFeedbackIncomingBubbleColor(Color value) async {
    await _setProperty('feedbackIncomingBubbleColor', value);
  }

  Future<Color?> get feedbackOutgoingBubbleColor =>
      _getProperty('feedbackOutgoingBubbleColor');
  Future<void> setFeedbackOutgoingBubbleColor(Color value) async {
    await _setProperty('feedbackOutgoingBubbleColor', value);
  }

  Future<Color?> get feedbackIncomingTextColor =>
      _getProperty('feedbackIncomingTextColor');
  Future<void> setFeedbackIncomingTextColor(Color value) async {
    await _setProperty('feedbackIncomingTextColor', value);
  }

  Future<Color?> get feedbackOutgoingTextColor =>
      _getProperty('feedbackOutgoingTextColor');
  Future<void> setFeedbackOutgoingTextColor(Color value) async {
    await _setProperty('feedbackOutgoingTextColor', value);
  }

  Future<Color?> get feedbackTitleTextColor =>
      _getProperty('feedbackTitleTextColor');
  Future<void> setFeedbackTitleTextColor(Color value) async {
    await _setProperty('feedbackTitleTextColor', value);
  }

  Future<Color?> get feedbackEmailSkipColor =>
      _getProperty('feedbackEmailSkipColor');
  Future<void> setFeedbackEmailSkipColor(Color value) async {
    await _setProperty('feedbackEmailSkipColor', value);
  }

  Future<Color?> get feedbackEmailBackgroundColor =>
      _getProperty('feedbackEmailBackgroundColor');
  Future<void> setFeedbackEmailBackgroundColor(Color value) async {
    await _setProperty('feedbackEmailBackgroundColor', value);
  }

  Future<Color?> get feedbackEmailContinueNotActiveColor =>
      _getProperty('feedbackEmailContinueNotActiveColor');
  Future<void> setFeedbackEmailContinueNotActiveColor(Color value) async {
    await _setProperty('feedbackEmailContinueNotActiveColor', value);
  }

  Future<Color?> get feedbackEmailContinueActiveColor =>
      _getProperty('feedbackEmailContinueActiveColor');
  Future<void> setFeedbackEmailContinueActiveColor(Color value) async {
    await _setProperty('feedbackEmailContinueActiveColor', value);
  }

  Future<Color?> get feedbackInputTextColor =>
      _getProperty('feedbackInputTextColor');
  Future<void> setFeedbackInputTextColor(Color value) async {
    await _setProperty('feedbackInputTextColor', value);
  }

  Future<Color?> get feedbackInputBackgroundColor =>
      _getProperty('feedbackInputBackgroundColor');
  Future<void> setFeedbackInputBackgroundColor(Color value) async {
    await _setProperty('feedbackInputBackgroundColor', value);
  }

  Future<Color?> get feedbackCloseButtonColor =>
      _getProperty('feedbackCloseButtonColor');
  Future<void> setFeedbackCloseButtonColor(Color value) async {
    await _setProperty('feedbackCloseButtonColor', value);
  }

  Future<Color?> get feedbackNavigationBarColor =>
      _getProperty('feedbackNavigationBarColor');
  Future<void> setFeedbackNavigationBarColor(Color value) async {
    await _setProperty('feedbackNavigationBarColor', value);
  }

  Future<String?> get reportSummaryPlaceholder =>
      _getPropertyStr('ReportSummaryPlaceholder');
  Future<void> setReportSummaryPlaceholder(String value) async {
    await _setPropertyStr('ReportSummaryPlaceholder', value);
  }

  Future<String?> get reportDescriptionPlaceholder =>
      _getPropertyStr('ReportDescriptionPlaceholder');
  Future<void> setReportDescriptionPlaceholder(String value) async {
    await _setPropertyStr('ReportDescriptionPlaceholder', value);
  }

  Future<String?> get reportEmailPlaceholder =>
      _getPropertyStr('ReportEmailPlaceholder');
  Future<void> setReportEmailPlaceholder(String value) async {
    await _setPropertyStr('ReportEmailPlaceholder', value);
  }

  Future<String?> get reportLabelsPlaceholder =>
      _getPropertyStr('ReportLabelsPlaceholder');
  Future<void> setReportLabelsPlaceholder(String value) async {
    await _setPropertyStr('ReportLabelsPlaceholder', value);
  }
}

class BugseeAppearanceAndroid extends BugseeAppearanceBase {
  const BugseeAppearanceAndroid(super.channel);

  Future<Color?> get reportActionBarColor =>
      _getProperty('ReportActionBarColor');
  Future<void> setReportActionBarColor(Color value) async {
    await _setProperty('ReportActionBarColor', value);
  }

  Future<Color?> get reportEditTextBackgroundColor =>
      _getProperty('ReportEditTextBackgroundColor');
  Future<void> setReportEditTextBackgroundColor(Color value) async {
    await _setProperty('ReportEditTextBackgroundColor', value);
  }

  Future<Color?> get reportVersionColor => _getProperty('ReportVersionColor');
  Future<void> setReportVersionColor(Color value) async {
    await _setProperty('ReportVersionColor', value);
  }

  Future<Color?> get reportTextColor => _getProperty('ReportTextColor');
  Future<void> setReportTextColor(Color value) async {
    await _setProperty('ReportTextColor', value);
  }

  Future<Color?> get reportHintColor => _getProperty('ReportHintColor');
  Future<void> setReportHintColor(Color value) async {
    await _setProperty('ReportHintColor', value);
  }

  Future<Color?> get reportActionBarTextColor =>
      _getProperty('ReportActionBarTextColor');
  Future<void> setReportActionBarTextColor(Color value) async {
    await _setProperty('ReportActionBarTextColor', value);
  }

  Future<Color?> get reportActionBarButtonBackgroundClickedColor =>
      _getProperty('ReportActionBarButtonBackgroundClickedColor');
  Future<void> setReportActionBarButtonBackgroundClickedColor(
      Color value) async {
    await _setProperty('ReportActionBarButtonBackgroundClickedColor', value);
  }

  Future<Color?> get reportBackgroundColor =>
      _getProperty('ReportBackgroundColor');
  Future<void> setReportBackgroundColor(Color value) async {
    await _setProperty('ReportBackgroundColor', value);
  }

  Future<Color?> get reportSeverityLabelActiveColor =>
      _getProperty('ReportSeverityLabelActiveColor');
  Future<void> setReportSeverityLabelActiveColor(Color value) async {
    await _setProperty('ReportSeverityLabelActiveColor', value);
  }

  Future<Color?> get feedbackActionBarColor =>
      _getProperty('FeedbackActionBarColor');
  Future<void> setFeedbackActionBarColor(Color value) async {
    await _setProperty('FeedbackActionBarColor', value);
  }

  Future<Color?> get feedbackBackgroundColor =>
      _getProperty('FeedbackBackgroundColor');
  Future<void> setFeedbackBackgroundColor(Color value) async {
    await _setProperty('FeedbackBackgroundColor', value);
  }

  Future<Color?> get feedbackActionBarButtonBackgroundClickedColor =>
      _getProperty('FeedbackActionBarButtonBackgroundClickedColor');
  Future<void> setFeedbackActionBarButtonBackgroundClickedColor(
      Color value) async {
    await _setProperty('FeedbackActionBarButtonBackgroundClickedColor', value);
  }

  Future<Color?> get feedbackIncomingBubbleColor =>
      _getProperty('FeedbackIncomingBubbleColor');
  Future<void> setFeedbackIncomingBubbleColor(Color value) async {
    await _setProperty('FeedbackIncomingBubbleColor', value);
  }

  Future<Color?> get feedbackOutgoingBubbleColor =>
      _getProperty('FeedbackOutgoingBubbleColor');
  Future<void> setFeedbackOutgoingBubbleColor(Color value) async {
    await _setProperty('FeedbackOutgoingBubbleColor', value);
  }

  Future<Color?> get feedbackIncomingTextColor =>
      _getProperty('FeedbackIncomingTextColor');
  Future<void> setFeedbackIncomingTextColor(Color value) async {
    await _setProperty('FeedbackIncomingTextColor', value);
  }

  Future<Color?> get feedbackOutgoingTextColor =>
      _getProperty('FeedbackOutgoingTextColor');
  Future<void> setFeedbackOutgoingTextColor(Color value) async {
    await _setProperty('FeedbackOutgoingTextColor', value);
  }

  Future<Color?> get feedbackDateTextColor =>
      _getProperty('FeedbackDateTextColor');
  Future<void> setFeedbackDateTextColor(Color value) async {
    await _setProperty('FeedbackDateTextColor', value);
  }

  Future<Color?> get feedbackTitleTextColor =>
      _getProperty('FeedbackTitleTextColor');
  Future<void> setFeedbackTitleTextColor(Color value) async {
    await _setProperty('FeedbackTitleTextColor', value);
  }

  Future<Color?> get feedbackEmailSkipTextColor =>
      _getProperty('FeedbackEmailSkipTextColor');
  Future<void> setFeedbackEmailSkipTextColor(Color value) async {
    await _setProperty('FeedbackEmailSkipTextColor', value);
  }

  Future<Color?> get feedbackEmailSkipBackgroundClickedColor =>
      _getProperty('FeedbackEmailSkipBackgroundClickedColor');
  Future<void> setFeedbackEmailSkipBackgroundClickedColor(Color value) async {
    await _setProperty('FeedbackEmailSkipBackgroundClickedColor', value);
  }

  Future<Color?> get feedbackEmailBackgroundColor =>
      _getProperty('FeedbackEmailBackgroundColor');
  Future<void> setFeedbackEmailBackgroundColor(Color value) async {
    await _setProperty('FeedbackEmailBackgroundColor', value);
  }

  Future<Color?> get feedbackEmailContinueNotActiveColor =>
      _getProperty('FeedbackEmailContinueNotActiveColor');
  Future<void> setFeedbackEmailContinueNotActiveColor(Color value) async {
    await _setProperty('FeedbackEmailContinueNotActiveColor', value);
  }

  Future<Color?> get feedbackEmailContinueActiveColor =>
      _getProperty('FeedbackEmailContinueActiveColor');
  Future<void> setFeedbackEmailContinueActiveColor(Color value) async {
    await _setProperty('FeedbackEmailContinueActiveColor', value);
  }

  Future<Color?> get feedbackEmailContinueClickedColor =>
      _getProperty('FeedbackEmailContinueClickedColor');
  Future<void> setFeedbackEmailContinueClickedColor(Color value) async {
    await _setProperty('FeedbackEmailContinueClickedColor', value);
  }

  Future<Color?> get feedbackInputTextColor =>
      _getProperty('FeedbackInputTextColor');
  Future<void> setFeedbackInputTextColor(Color value) async {
    await _setProperty('FeedbackInputTextColor', value);
  }

  Future<Color?> get feedbackInputTextHintColor =>
      _getProperty('FeedbackInputTextHintColor');
  Future<void> setFeedbackInputTextHintColor(Color value) async {
    await _setProperty('FeedbackInputTextHintColor', value);
  }

  Future<Color?> get feedbackBottomDelimiterColor =>
      _getProperty('FeedbackBottomDelimiterColor');
  Future<void> setFeedbackBottomDelimiterColor(Color value) async {
    await _setProperty('FeedbackBottomDelimiterColor', value);
  }

  Future<Color?> get feedbackLoadingBarBackgroundColor =>
      _getProperty('FeedbackLoadingBarBackgroundColor');
  Future<void> setFeedbackLoadingBarBackgroundColor(Color value) async {
    await _setProperty('FeedbackLoadingBarBackgroundColor', value);
  }

  Future<Color?> get feedbackLoadingTextColor =>
      _getProperty('FeedbackLoadingTextColor');
  Future<void> setFeedbackLoadingTextColor(Color value) async {
    await _setProperty('FeedbackLoadingTextColor', value);
  }

  Future<Color?> get feedbackErrorTextColor =>
      _getProperty('FeedbackErrorTextColor');
  Future<void> setFeedbackErrorTextColor(Color value) async {
    await _setProperty('FeedbackErrorTextColor', value);
  }

  Future<Color?> get feedbackVersionChangedBackgroundColor =>
      _getProperty('FeedbackVersionChangedBackgroundColor');
  Future<void> setFeedbackVersionChangedBackgroundColor(Color value) async {
    await _setProperty('FeedbackVersionChangedBackgroundColor', value);
  }

  Future<Color?> get feedbackVersionChangedTextColor =>
      _getProperty('FeedbackVersionChangedTextColor');
  Future<void> setFeedbackVersionChangedTextColor(Color value) async {
    await _setProperty('FeedbackVersionChangedTextColor', value);
  }

  Future<String?> get reportSummaryPlaceholder =>
      _getPropertyStr('ReportSummaryPlaceholder');
  Future<void> setReportSummaryPlaceholder(String value) async {
    await _setPropertyStr('ReportSummaryPlaceholder', value);
  }

  Future<String?> get reportDescriptionPlaceholder =>
      _getPropertyStr('ReportDescriptionPlaceholder');
  Future<void> setReportDescriptionPlaceholder(String value) async {
    await _setPropertyStr('ReportDescriptionPlaceholder', value);
  }

  Future<String?> get reportEmailPlaceholder =>
      _getPropertyStr('ReportEmailPlaceholder');
  Future<void> setReportEmailPlaceholder(String value) async {
    await _setPropertyStr('ReportEmailPlaceholder', value);
  }

  Future<String?> get reportLabelsPlaceholder =>
      _getPropertyStr('ReportLabelsPlaceholder');
  Future<void> setReportLabelsPlaceholder(String value) async {
    await _setPropertyStr('ReportLabelsPlaceholder', value);
  }
}

class BugseeAppearance {
  final BugseeAppearanceAndroid _androidAppearance;
  final BugseeAppearanceIOS _iosAppearance;

  BugseeAppearance._(this._androidAppearance, this._iosAppearance);

  factory BugseeAppearance(MethodChannel channel) {
    return BugseeAppearance._(
        BugseeAppearanceAndroid(channel), BugseeAppearanceIOS(channel));
  }

  BugseeAppearanceAndroid get android => _androidAppearance;
  BugseeAppearanceIOS get iOS => _iosAppearance;
}
