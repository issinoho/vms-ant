package com.example;

import com.example.util.Words;

/** Counts the words of each argument; prints the classpath's length if asked. */
public class App {
    public static void main(String[] args) {
        for (String a : args) {
            if (a.equals("--cplen")) {
                System.out.println("classpath length " + System.getProperty("java.class.path").length());
                continue;
            }
            System.out.println(Words.capital(a) + ": " + Words.split(a).length + " word(s)");
        }
    }
}
