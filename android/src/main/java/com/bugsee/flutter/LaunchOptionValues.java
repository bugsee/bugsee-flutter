package com.bugsee.flutter;

import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.options.FrameRate;
import com.bugsee.library.contracts.options.IssueSeverity;
import com.bugsee.library.contracts.options.LogLevel;
import com.bugsee.library.contracts.options.VideoMode;
import com.bugsee.library.contracts.options.VideoQuality;

import java.io.Serializable;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

/**
 * The launch options between Dart and the Android SDK (workbook Part 8).
 *
 * <p>Android and iOS share the {@code com.bugsee.option.*} namespace, so Dart sends ONE flat map
 * and nothing here renames a key. The single thing that differs is the enum: the Android SDK takes
 * an enum option as the constant itself or its NAME, and drops a number ("an int is not accepted
 * in place of an enum constant on the map path": the internal values differ from the ordinals, so
 * an int has no single meaning to it). Dart sends the SDK's INTERNAL value, and this class turns it
 * into the constant through the enum's own factory, never through {@code values()[n]} (an
 * ordinal). The reverse is done for the read-back, so Dart sees the same integers on both
 * platforms.
 *
 * <p>The table below is the set of enum options of the modules this plugin bundles. It is repeated
 * from the SDK's manifest and compared with it, and with the real enums of the pinned SDK, by
 * {@code LaunchOptionValuesTest} (by value, key by key): a new enum option fails that test until it
 * has an entry here, rather than being sent to the SDK as a number it would drop.
 */
final class LaunchOptionValues {

    private static final String TAG = FlutterWrapperInitProvider.TAG;

    /** An SDK enum: its internal value to the constant, and back. */
    interface EnumCodec {
        /** @return the constant for the internal value, or {@code null} when there is none */
        @Nullable
        Object fromValue(int value);

        /** @return the internal value of a constant of this enum, or {@code null} for another type */
        @Nullable
        Integer toValue(@NonNull Object constant);
    }

    private static final EnumCodec LOG_LEVEL = new EnumCodec() {
        @Nullable
        @Override
        public Object fromValue(final int value) {
            return value < Byte.MIN_VALUE || value > Byte.MAX_VALUE
                    ? null : LogLevel.fromRawValue((byte) value);
        }

        @Nullable
        @Override
        public Integer toValue(@NonNull final Object constant) {
            return constant instanceof LogLevel ? Integer.valueOf(((LogLevel) constant).getValue()) : null;
        }
    };

    private static final EnumCodec FRAME_RATE = new EnumCodec() {
        @Nullable
        @Override
        public Object fromValue(final int value) {
            return FrameRate.fromIntValue(value);
        }

        @Nullable
        @Override
        public Integer toValue(@NonNull final Object constant) {
            return constant instanceof FrameRate ? Integer.valueOf(((FrameRate) constant).getIntValue()) : null;
        }
    };

    private static final EnumCodec VIDEO_MODE = new EnumCodec() {
        @Nullable
        @Override
        public Object fromValue(final int value) {
            return VideoMode.fromIntValue(value);
        }

        @Nullable
        @Override
        public Integer toValue(@NonNull final Object constant) {
            return constant instanceof VideoMode ? Integer.valueOf(((VideoMode) constant).getValue()) : null;
        }
    };

    private static final EnumCodec VIDEO_QUALITY = new EnumCodec() {
        @Nullable
        @Override
        public Object fromValue(final int value) {
            return VideoQuality.fromIntValue(value);
        }

        @Nullable
        @Override
        public Integer toValue(@NonNull final Object constant) {
            return constant instanceof VideoQuality ? Integer.valueOf(((VideoQuality) constant).getValue()) : null;
        }
    };

    private static final EnumCodec SEVERITY = new EnumCodec() {
        @Nullable
        @Override
        public Object fromValue(final int value) {
            // fromIntValue never answers null: an unknown value becomes VeryLow, which would be
            // a silently different severity. Only 1..5 are the SDK's values.
            return value >= 1 && value <= 5 ? IssueSeverity.fromIntValue(value) : null;
        }

        @Nullable
        @Override
        public Integer toValue(@NonNull final Object constant) {
            return constant instanceof IssueSeverity ? Integer.valueOf(((IssueSeverity) constant).getValue()) : null;
        }
    };

    /**
     * The SDK's {@code LogLevel} for its internal value ({@code Bugsee.log}'s level uses the same
     * enum as the {@code capture.logs.level} option), or {@code null}.
     */
    @Nullable
    static LogLevel logLevel(final int value) {
        final Object constant = LOG_LEVEL.fromValue(value);
        return constant instanceof LogLevel ? (LogLevel) constant : null;
    }

    /** Option key to codec. Compared with the manifest by the test named above. */
    static final Map<String, EnumCodec> ENUM_OPTIONS;

    static {
        final Map<String, EnumCodec> table = new HashMap<>();
        table.put("com.bugsee.option.capture.logs.level", LOG_LEVEL);
        table.put("com.bugsee.option.capture.video.frame-rate", FRAME_RATE);
        table.put("com.bugsee.option.capture.video.mode", VIDEO_MODE);
        table.put("com.bugsee.option.capture.video.quality", VIDEO_QUALITY);
        table.put("com.bugsee.option.reporting.defaults.bug-priority", SEVERITY);
        table.put("com.bugsee.option.reporting.defaults.crash-priority", SEVERITY);
        table.put("com.bugsee.option.reporting.defaults.error-priority", SEVERITY);
        ENUM_OPTIONS = Collections.unmodifiableMap(table);
    }

    private LaunchOptionValues() {
    }

    /**
     * The flat map from Dart as the SDK's launch options. A number for an enum option becomes the
     * constant; everything else is passed as it is (the SDK coerces numbers, and takes a string
     * naming an enum constant itself). Never throws: an entry that cannot be used is left out and
     * logged without its value.
     */
    @NonNull
    static Map<String, Serializable> toSdk(@Nullable final Map<?, ?> flat) {
        final Map<String, Serializable> out = new HashMap<>();
        if (flat == null) {
            return out;
        }
        for (final Map.Entry<?, ?> entry : flat.entrySet()) {
            if (!(entry.getKey() instanceof String) || entry.getValue() == null) {
                continue;
            }
            final String key = (String) entry.getKey();
            final Object value = entry.getValue();
            final EnumCodec codec = ENUM_OPTIONS.get(key);
            if (codec != null && value instanceof Number) {
                final Number number = (Number) value;
                final int internal = number.intValue();
                final Object constant = number.doubleValue() == internal ? codec.fromValue(internal) : null;
                if (constant instanceof Serializable) {
                    out.put(key, (Serializable) constant);
                } else {
                    // Dart checks this against the manifest, so this is a version skew; the
                    // option keeps the SDK's default rather than receiving a number it would drop.
                    Log.w(TAG, "option " + key + ": not a value of the SDK's enum, left at the default");
                }
            } else if (value instanceof Boolean || value instanceof String || value instanceof Number) {
                out.put(key, (Serializable) value);
            } else {
                Log.w(TAG, "option " + key + ": a value of an unsupported type was left out");
            }
        }
        return out;
    }

    /**
     * Options the SDK reports, as values the channel can carry, the same on both platforms:
     * enums as their internal integer, floats as doubles, nothing null, nothing but primitives.
     */
    @NonNull
    static Map<String, Object> fromSdk(@Nullable final Map<String, ? extends Serializable> sdk) {
        final Map<String, Object> out = new HashMap<>();
        if (sdk == null) {
            return out;
        }
        for (final Map.Entry<String, ? extends Serializable> entry : sdk.entrySet()) {
            final Object value = entry.getValue();
            if (value == null) {
                continue;
            }
            final Object converted = fromSdkValue(entry.getKey(), value);
            if (converted != null) {
                out.put(entry.getKey(), converted);
            }
        }
        return out;
    }

    @Nullable
    private static Object fromSdkValue(@NonNull final String key, @NonNull final Object value) {
        if (value instanceof Enum) {
            final EnumCodec codec = ENUM_OPTIONS.get(key);
            final Integer internal = codec == null ? null : codec.toValue(value);
            // An enum of a module this table does not know (the leak module's string-valued one)
            // is reported as the string the SDK documents for it.
            return internal != null ? (Object) internal : value.toString();
        }
        if (value instanceof Float) {
            return Double.valueOf(((Float) value).doubleValue());
        }
        if (value instanceof Short || value instanceof Byte) {
            return Integer.valueOf(((Number) value).intValue());
        }
        if (value instanceof Boolean || value instanceof String || value instanceof Integer
                || value instanceof Long || value instanceof Double) {
            return value;
        }
        return null;
    }
}
