package com.example.util;

/** Small helpers the app and its tests use. */
public final class Words {
    private Words() {
    }

    /** The words of S, at runs of white space. */
    public static String[] split(String s) {
        String t = s.trim();
        return t.isEmpty() ? new String[0] : t.split("\\s+");
    }

    /** S with its first letter in upper case. */
    public static String capital(String s) {
        return s.isEmpty() ? s : Character.toUpperCase(s.charAt(0)) + s.substring(1);
    }
}
