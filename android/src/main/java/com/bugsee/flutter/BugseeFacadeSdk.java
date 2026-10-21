package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.Bugsee;
import com.bugsee.library.contracts.exchange.Breadcrumb;
import com.bugsee.library.contracts.lifecycle.BugseeStatus;
import com.bugsee.library.contracts.exchange.BugseeExchangeFactory;
import com.bugsee.library.contracts.options.IssueSeverity;
import com.bugsee.library.contracts.options.LogLevel;
import com.bugsee.library.contracts.options.OptionsContainer;
import com.bugsee.library.contracts.options.Options;

import java.io.Serializable;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The real Android SDK behind {@link FacadeOps.Sdk}. Nothing is decided here (see
 * {@link FacadeOps}): each method is one SDK call, made on the platform (main) thread, which is
 * the thread the SDK's public API expects.
 */
final class BugseeFacadeSdk implements FacadeOps.Sdk {

    @Override
    public void setAttribute(@NonNull final String name, @NonNull final Serializable value) {
        Bugsee.setAttribute(name, value);
    }

    @Nullable
    @Override
    public Object getAttribute(@NonNull final String name) {
        return Bugsee.getAttribute(name);
    }

    @Nullable
    @Override
    public Map<String, ? extends Serializable> getAllAttributes() {
        return Bugsee.getAllAttributes();
    }

    @Override
    public void clearAttribute(@NonNull final String name) {
        Bugsee.clearAttribute(name);
    }

    @Override
    public void clearAllAttributes() {
        Bugsee.clearAllAttributes();
    }

    @Override
    public void setUserIdentifier(@Nullable final String identifier) {
        Bugsee.setUserIdentifier(identifier);
    }

    @Nullable
    @Override
    public String getUserIdentifier() {
        return Bugsee.getUserIdentifier();
    }

    @Override
    public void clearUserIdentifier() {
        Bugsee.clearUserIdentifier();
    }

    @Override
    public void trace(@NonNull final String name, @NonNull final Object value) {
        Bugsee.trace(name, value);
    }

    @Override
    public void event(@NonNull final String name, @Nullable final LinkedHashMap<String, Object> params) {
        if (params == null) {
            Bugsee.event(name);
        } else {
            Bugsee.event(name, params);
        }
    }

    @Override
    public void log(@NonNull final String message, @NonNull final LogLevel level) {
        Bugsee.log(message, level);
    }

    @Override
    public void notifyRelay(
            @NonNull final String title,
            @Nullable final String body,
            @Nullable final IssueSeverity severity,
            @Nullable final LinkedHashMap<String, String> fields,
            final boolean urgent
    ) {
        Bugsee.notify(title, body, severity, fields, urgent);
    }

    @Override
    public boolean isLaunchedOrLaunching() {
        final BugseeStatus status = Bugsee.getStatus();
        return status == BugseeStatus.Launching || status == BugseeStatus.Launched;
    }

    @Override
    public boolean addBreadcrumb(
            @NonNull final String category,
            @NonNull final Breadcrumb.Level level,
            @NonNull final String message,
            @NonNull final String type,
            @Nullable final Map<String, Object> data
    ) {
        // The SDK's factory hands back no crumb when capture is off (and none before launch);
        // iOS hands one back and records nothing, so the option is the common signal.
        final OptionsContainer options = Bugsee.getLaunchOptions();
        final Object capture = options == null
                ? Boolean.FALSE
                : options.getOption(Options.CaptureBreadcrumbs, Boolean.FALSE);
        if (!Boolean.TRUE.equals(capture)) {
            return false;
        }
        final BugseeExchangeFactory factory = Bugsee.getExchangeFactory();
        final Breadcrumb crumb = factory == null ? null : factory.createBreadcrumb();
        if (crumb == null) {
            return false;
        }
        crumb.setCategory(category);
        crumb.setLevel(level);
        crumb.setMessage(message);
        crumb.setType(type);
        if (data != null) {
            crumb.setData(data);
        }
        Bugsee.addBreadcrumb(crumb);
        return true;
    }

    @Override
    public void startBlackout() {
        Bugsee.startBlackout();
    }

    @Override
    public void endBlackout() {
        Bugsee.endBlackout();
    }

    @Override
    public boolean isBlackout() {
        return Bugsee.isBlackout();
    }

    @Override
    public void showReportDialog(
            @Nullable final String summary,
            @Nullable final String description,
            @Nullable final IssueSeverity severity,
            @Nullable final ArrayList<String> labels
    ) {
        Bugsee.showReportDialog(summary, description, severity, labels);
    }

    @Override
    public void upload(
            @NonNull final String summary,
            @NonNull final String description,
            @Nullable final IssueSeverity severity,
            @Nullable final List<String> labels
    ) {
        Bugsee.upload(summary, description, severity, labels);
    }
}
