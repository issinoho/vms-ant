package hello;

/** Prints each argument on its own line, bracketed, so splitting and case show. */
public class Hello {
    public static void main(String[] args) {
        System.out.println("Hello from Ant on " + System.getProperty("os.name"));
        for (String a : args) {
            System.out.println("[" + a + "]");
        }
        if (args.length > 0 && args[0].startsWith("exit")) {
            System.exit(Integer.parseInt(args[0].substring(4)));
        }
    }
}
