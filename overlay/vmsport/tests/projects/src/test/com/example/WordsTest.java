package com.example;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;

import com.example.util.Words;
import org.junit.Test;

public class WordsTest {
    @Test
    public void splitsAtWhiteSpace() {
        assertArrayEquals(new String[] {"Mixed", "Case", "words"}, Words.split("  Mixed Case\twords "));
    }

    @Test
    public void capital() {
        assertEquals("Hello", Words.capital("hello"));
    }

    /** Fails on purpose when -Dfail.test=true is passed to the test JVM. */
    @Test
    public void failsWhenAsked() {
        assertEquals("false", System.getProperty("fail.test", "false"));
    }
}
