/// Bugsee for Flutter: video, network traffic, console logs and other traces on every bug and
/// crash report. Android and iOS.
///
/// Start with [Bugsee.launch] and [BugseeOptions]. Mark sensitive UI with [BugseeSecureView].
library;

export 'src/bugsee.dart' show Bugsee;
export 'src/errors.dart'
    show AttributeFailure, BugseeArgumentException, BugseeAttributeException;
export 'src/exceptions/error_capture.dart' show IsolateErrorListener;
export 'src/facade/breadcrumb.dart' show BreadcrumbLevel, BugseeBreadcrumb;
export 'src/launch.dart'
    show BugseeException, BugseeLaunchException, LaunchFailure, LaunchResult;
export 'src/lifecycle_event.dart' show LifecycleEvent;
export 'src/network/network_event.dart'
    show BugseeNetworkEvent, BugseeNetworkFilter, NetworkStage, NoBodyReason;
export 'src/network/network_pipeline.dart' show NetworkCaptureStats;
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
export 'src/report/attachments.dart'
    show
        ReportAttachment,
        ReportAttachmentException,
        ReportAttachmentFailure,
        ReportScreenshot,
        maxAttachmentBytes,
        maxAttachmentFileBytes,
        maxScreenshotPixels;
export 'src/report/created_report.dart'
    show
        CreateReportException,
        CreateReportFailure,
        CreatedReport,
        CreatedReportClosedError,
        CreatedReportSnapshot;
export 'src/report/report_enums.dart' show ReportSeverity, ReportType;
export 'src/report/report_handler.dart' show BugseeReportHandler, ReportHandler;
export 'src/report/report_proxy.dart'
    show ReportClosedError, ReportProxy, ReportSnapshot;
export 'src/secure/bugsee_secure_view.dart' show BugseeSecureView;
export 'src/status.dart' show BugseeStatus;
export 'src/wrapper_identity.dart' show bugseeFlutterVersion;
