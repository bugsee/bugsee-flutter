package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import com.bugsee.library.BugseeExtensionInitProviderBase;
import com.bugsee.library.contracts.internal.BugseeWrapper;

import org.junit.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;

/**
 * The provider runs before Application.onCreate in every host app: anything it
 * throws kills the process before the app runs a line, so it swallows errors
 * (a missing SDK class is a LinkageError, not an Exception).
 */
public class FlutterWrapperInitProviderTest {

    /** The pattern the Bugsee Gradle plugin strips from the merged manifest. */
    private static final Pattern STRIPPED_BY_GRADLE_PLUGIN =
            Pattern.compile("^.*\\.Bugsee[A-Za-z0-9_]+InitProvider$");

    @Test
    public void nameIsNotOneTheGradlePluginStrips() {
        assertFalse(STRIPPED_BY_GRADLE_PLUGIN.matcher(
                FlutterWrapperInitProvider.class.getName()).matches());
        // Sanity: the pattern really does catch the trap name.
        assertTrue(STRIPPED_BY_GRADLE_PLUGIN.matcher(
                "com.bugsee.flutter.BugseeWrapperInitProvider").matches());
    }

    @Test
    public void extendsTheSdkExtensionBase() {
        assertEquals(BugseeExtensionInitProviderBase.class,
                FlutterWrapperInitProvider.class.getSuperclass());
    }

    @Test
    public void registersTheWrapper() {
        final List<BugseeWrapper> registered = new ArrayList<>();
        FlutterWrapperInitProvider.registerEarly(registered::add);
        assertEquals(1, registered.size());
        assertNotNull(registered.get(0));
        assertEquals("flutter", registered.get(0).getWrapperType());
    }

    @Test
    public void swallowsAnExceptionFromRegistration() {
        FlutterWrapperInitProvider.registerEarly(w -> {
            throw new IllegalStateException("registration failed");
        });
    }

    @Test
    public void swallowsAnErrorFromRegistration() {
        FlutterWrapperInitProvider.registerEarly(w -> {
            throw new NoClassDefFoundError("com/bugsee/library/Bugsee");
        });
    }
}
