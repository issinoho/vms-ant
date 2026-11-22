package com.example;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.example.util.Words;
import org.junit.jupiter.api.Test;

class WordsJupiterTest {
    @Test
    void countsWords() {
        assertEquals(4, Words.split("Ant on Open VMS").length);
    }

    @Test
    void capital() {
        assertEquals("Jupiter", Words.capital("jupiter"));
    }
}
