/// Bugsee for Flutter: video, network traffic, console logs and other traces on every bug and
/// crash report. Android and iOS.
///
/// Start with [Bugsee.launch] and [BugseeOptions].
library;

export 'src/bugsee.dart' show Bugsee;
export 'src/launch.dart'
    show BugseeException, BugseeLaunchException, LaunchFailure, LaunchResult;
export 'src/options/bugsee_options.g.dart'
    show
        BugseeOptions,
        BugseeStyle,
        CrashHandlerType,
        DataEncryptionMode,
        FrameRate,
        LogLevel,
        VideoMode,
        VideoQuality;
export 'src/report/report_enums.dart' show ReportSeverity;
export 'src/status.dart' show BugseeStatus;
