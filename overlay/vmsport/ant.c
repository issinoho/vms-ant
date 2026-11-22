/* ant.c - the Ant launcher for OpenVMS: what bin/ant does, as an image.

   ANT has to be an image, not a DCL procedure: DCL upper-cases the parameters
   of a procedure (P1-P8, at most eight of them), and Ant's targets, options
   and properties are case-sensitive.  An image run as a foreign command gets
   its arguments as typed when the process has SET PROCESS/PARSE_STYLE=EXTENDED
   (vms_crtl_init.c turns on DECC$ARGV_PARSE_STYLE).

   Like bin/ant, it
     - finds the Ant home (the directory above the one holding ANT.EXE, or
       ANT_HOME),
     - finds Java (JAVA_HOME, or the JAVA symbol OPENJDK$SETUP.COM defines),
     - gives Java small-footprint defaults (DEFAULT_JVM_OPTS), then the JVM
       options from ANT_OPTS, and extra Ant arguments from ANT_ARGS,
     - passes CLASSPATH on to Ant (as -cp) unless --noclasspath is given,
   and runs Java on Ant's own launcher (lib/ant-launcher.jar), which finds
   lib/, ~/.ant/lib and -lib itself.  Java is started with vfork and execv,
   so the arguments reach it without passing through DCL again.  The exit
   status is Java's.

   For the programs Ant starts: the bare names java, javac, javadoc and jar
   are mapped to the JDK's images (VSI Java's JAVA$EXEC_MAPPING_nn) unless
   the site maps them, and -Dant.openvms.dclrunner names ANTDCL.EXE next to
   this image, which runs the DCL procedures of <exec vmlauncher="false">
   (patch 0004, NOTES N8).

   It also sets VSI Java's JAVA$DELETE_ALL_VERSIONS, JAVA$RENAME_ALL_VERSIONS
   and JAVA$CREATE_DIR_WITH_OWNER_DELETE (unless defined), so <delete> removes
   every version of a file and directories can be deleted (NOTES N2).

   From a terminal, CTRL/C reaches Java, which runs its shutdown hooks and
   exits 130.  DCL's CTRL/Y would interrupt the launcher and kill Java
   outright, so while Java runs the launcher takes CTRL/Y itself and passes
   it on to Java as SIGINT: CTRL/Y stops a build as CTRL/C does.  Exit codes
   of 128 and up (a signal) give an error status (vms-maven NOTES N24).

   When its standard output is a PIPE or a batch log (not a terminal, nor
   DEFINE/USER SYS$OUTPUT), the launcher passes Java's output on a line at a
   time: Java writes one record for each write() to an output it inherits,
   which put an empty record after every line logged (vms-maven NOTES N25).

   Environment variables are read with getenv(), so each may be a DCL symbol
   or a logical name.  ANT_VMS_TRACE (any value) prints the Java command.

   Adapted from vms-maven's mvn.c.  Part of vms-ant
   (github.com/issinoho/vms-ant); Apache License 2.0.  */

#define _POSIX_EXIT 1           /* exit(n) gives the status Java's exit(n) does */

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <signal.h>
#include <unistd.h>
#include <wait.h>
#include <unixlib.h>

#include <dcdef.h>
#include <descrip.h>
#include <dvidef.h>
#include <iodef.h>
#include <jpidef.h>
#include <lib$routines.h>
#include <libclidef.h>
#include <lnmdef.h>
#include <psldef.h>
#include <starlet.h>
#include <ssdef.h>

#define MAXARGS 1024

/* As MVN.EXE's: a forked JVM (<java fork>, <junit fork>) shares the job's
   page file quota with this one.  ANT_OPTS overrides them.  */
#define DEFAULT_JVM_OPTS \
  "-Xms16m -Xmx256m -XX:+UseSerialGC -XX:ReservedCodeCacheSize=32m"

static const char *prog = "ant";
static char *jargv[MAXARGS];
static int jargc;

static void
die (const char *msg, const char *what)
{
  fprintf (stderr, "%s: %s%s%s\n", prog, msg, what ? ": " : "", what ? what : "");
  exit (1);
}

static char *
xstrdup (const char *s)
{
  char *d = strdup (s);
  if (d == NULL)
    die ("out of memory", NULL);
  return d;
}

static char *
concat (const char *a, const char *b)
{
  char *d = malloc (strlen (a) + strlen (b) + 1);
  if (d == NULL)
    die ("out of memory", NULL);
  strcpy (d, a);
  strcat (d, b);
  return d;
}

static void
add (const char *arg)
{
  if (jargc >= MAXARGS - 1)
    die ("too many arguments", NULL);
  jargv[jargc++] = (char *) arg;
}

/* Add each whitespace-separated word of S, as bin/ant's unquoted
   $ANT_OPTS does.  */
static void
add_words (const char *s)
{
  char *copy, *w;
  if (s == NULL)
    return;
  copy = xstrdup (s);
  for (w = strtok (copy, " \t\r\n"); w != NULL; w = strtok (NULL, " \t\r\n"))
    add (w);
}

/* A file specification in VMS form (DEV:[DIR]NAME) becomes a Unix path;
   anything else is returned as it is.  */
static char *
unix_path (const char *spec)
{
  char *u;
  if (strchr (spec, ':') == NULL && strchr (spec, '[') == NULL
      && strchr (spec, '<') == NULL)
    return xstrdup (spec);
  u = decc$translate_vms (spec);
  if (u == NULL || u == (char *) -1)
    die ("cannot translate to a Unix path", spec);
  return xstrdup (u);
}

static void
strip_trailing_slash (char *p)
{
  size_t n = strlen (p);
  while (n > 1 && p[n - 1] == '/')
    p[--n] = '\0';
}

/* "/a/b/c" -> "/a/b"; "/a" -> "/".  Returns 0 at the root.  */
static int
parent (char *p)
{
  char *s;
  strip_trailing_slash (p);
  if (strcmp (p, "/") == 0)
    return 0;
  s = strrchr (p, '/');
  if (s == NULL)
    return 0;
  if (s == p)
    s[1] = '\0';
  else
    *s = '\0';
  return 1;
}

static int
is_dir (const char *p)
{
  struct stat st;
  return stat (p, &st) == 0 && S_ISDIR (st.st_mode);
}

static int
is_file (const char *p)
{
  struct stat st;
  return stat (p, &st) == 0 && !S_ISDIR (st.st_mode);
}

static char *
join (const char *dir, const char *name)
{
  size_t n = strlen (dir);
  char *d = malloc (n + strlen (name) + 2);
  if (d == NULL)
    die ("out of memory", NULL);
  strcpy (d, dir);
  if (n == 0 || dir[n - 1] != '/')
    strcat (d, "/");
  strcat (d, name);
  return d;
}

/* Ant home: ANT_HOME, else the parent of the directory holding this image.  */
static char *
ant_home (void)
{
  const char *env = getenv ("ANT_HOME");
  char image[256];
  unsigned short len = 0;
  int code = JPI$_IMAGNAME, status;
  char *u, *semi;
  struct dsc$descriptor_s d;

  if (env != NULL && *env != '\0')
    {
      u = unix_path (env);
      strip_trailing_slash (u);
      return u;
    }
  d.dsc$w_length = sizeof image - 1;
  d.dsc$b_dtype = DSC$K_DTYPE_T;
  d.dsc$b_class = DSC$K_CLASS_S;
  d.dsc$a_pointer = image;
  status = lib$getjpi (&code, 0, 0, 0, &d, &len);
  if (!(status & 1))
    die ("cannot find this image's name (LIB$GETJPI)", NULL);
  image[len] = '\0';
  semi = strchr (image, ';');
  if (semi != NULL)
    *semi = '\0';
  u = unix_path (image);
  /* .../bin/ANT.EXE -> .../bin -> ... */
  if (!parent (u) || !parent (u))
    die ("cannot find the Ant home from", image);
  return u;
}

/* Java: $JAVA_HOME/bin/java, else the image the JAVA symbol runs.  */
static char *
java_image (void)
{
  const char *env = getenv ("JAVA_HOME");
  const char *sym;
  if (env != NULL && *env != '\0')
    {
      char *home = unix_path (env), *bin = join (home, "bin/java");
      if (!is_file (concat (bin, ".exe")) && !is_file (bin))
        die ("JAVA_HOME does not contain bin/java", env);
      return bin;
    }
  sym = getenv ("JAVA");
  if (sym != NULL && *sym == '$')
    return xstrdup (sym + 1);
  die ("Java not found: set JAVA_HOME, or run @SYS$STARTUP:OPENJDK$SETUP.COM", NULL);
  return NULL;
}

/* VSI Java's file behaviour that Ant needs (NOTES N2), unless the site has
   set these itself.  Without them delete removes only the newest version
   of a file, so <delete dir> fails on a directory where a file was
   rewritten.  */
static void
java_file_settings (void)
{
  static const char *names[] = {
    "JAVA$DELETE_ALL_VERSIONS",
    "JAVA$RENAME_ALL_VERSIONS",
    "JAVA$CREATE_DIR_WITH_OWNER_DELETE",
  };
  size_t i;
  for (i = 0; i < sizeof names / sizeof names[0]; i++)
    if (getenv (names[i]) == NULL)
      setenv (names[i], "TRUE", 1);
}

/* Map program NAME to IMAGE for the programs Java starts, through the
   first free JAVA$EXEC_MAPPING_nn, unless one already maps NAME (the
   site's own mapping wins).  */
static void
map_program (const char *name, const char *image)
{
  char var[32], *prefix = concat (name, "=");
  size_t plen = strlen (prefix);
  int i;
  for (i = 1; i <= 99; i++)
    {
      const char *v;
      sprintf (var, "JAVA$EXEC_MAPPING_%02d", i);
      v = getenv (var);
      if (v == NULL)
        break;
      if (strncmp (v, prefix, plen) == 0)
        return;
    }
  if (i <= 99)
    setenv (var, concat (prefix, image), 1);
}

/* Map the bare names of the JDK's tools to their images, for build files
   that run them by name (<exec executable="javac">); Ant's own forks find
   them itself (patch 0001).  */
static void
map_programs (const char *java)
{
  static const char *tools[] = { "javac", "javadoc", "jar" };
  char *jbin = unix_path (java), *jdkbin, *s;
  size_t i, n;
  map_program ("java", jbin);
  /* The JDK's bin: <jdk>/jre/bin/java -> <jdk>/bin (Java 8), else beside java.  */
  s = strrchr (jbin, '/');
  if (s == NULL)
    return;
  jdkbin = xstrdup (jbin);
  jdkbin[s - jbin] = '\0';
  n = strlen (jdkbin);
  if (n > 8 && strcasecmp (jdkbin + n - 8, "/jre/bin") == 0)
    strcpy (jdkbin + n - 8, "/bin");
  for (i = 0; i < sizeof tools / sizeof tools[0]; i++)
    {
      char *image = join (jdkbin, concat (tools[i], ".exe"));
      if (is_file (image))
        map_program (tools[i], image);
    }
}

/* Java on OpenVMS wants far larger quotas than a default account has (HP's
   Java user guide: FILLM 4096, PGFLQUOTA 2097152), and a forked JVM shares
   them with Ant's (vms-maven NOTES N12, N14).  Note low ones after a
   failure, when they may be why.  */
#define WANT_FILLM 4096
#define WANT_PGFLQUOTA 2097152

static void
note_quotas (void)
{
  int c1 = JPI$_FILLM, c2 = JPI$_PGFLQUOTA, fillm = 0, pgfl = 0;
  if (!(lib$getjpi (&c1, 0, 0, &fillm, 0, 0) & 1)
      || !(lib$getjpi (&c2, 0, 0, &pgfl, 0, 0) & 1))
    return;
  if (fillm >= WANT_FILLM && pgfl >= WANT_PGFLQUOTA)
    return;
  fprintf (stderr, "%s: note: this account's quotas are low for Java (FILLM %d, "
           "PGFLQUOTA %d; Java on OpenVMS wants FILLM %d and PGFLQUOTA %d): "
           "\"unable to create new native thread\", \"could not reserve enough "
           "space\" or a forked JVM that fails to start come from that\n",
           prog, fillm, pgfl, WANT_FILLM, WANT_PGFLQUOTA);
}

/* CTRL/Y while Java runs (vms-maven NOTES N24).  DCL's CTRL/Y interrupts this image,
   and the Java subprocess that vfork/execv made dies with it: no shutdown
   hooks, and waitpid() reports exit 0, so CONTINUE finds nothing to go on
   with and the build "succeeds".  (CTRL/C reaches Java itself.)  From a
   terminal, the launcher turns off DCL's CTRL/Y while Java runs and takes a
   CTRL/Y AST instead, which sends Java SIGINT, as CTRL/C would.  A process
   that has CTRL/Y turned off already (SET NOCONTROL=Y) is left as it is.  */
static pid_t java_pid;
static unsigned short ctrly_chan;
static int ctrly_taken;
static int ctrly_count;

static void ctrly_ast (int arg);
static void ctrly_give_back (void);

static int
ctrly_arm (void)
{
  return sys$qiow (0, ctrly_chan, IO$_SETMODE | IO$M_CTRLYAST, 0, 0, 0,
                   (void *) ctrly_ast, 0, 0, 0, 0, 0);
}

static void
ctrly_ast (int arg)
{
  ctrly_count++;
  if (java_pid > 0)
    kill (java_pid, SIGINT);
  ctrly_arm ();                 /* an AST is delivered once per enable */
}

static void
ctrly_take (void)
{
  $DESCRIPTOR (cmd, "SYS$COMMAND");
  unsigned int mask = LIB$M_CLI_CTRLY, old = 0;
  int code = DVI$_DEVCLASS, devclass = 0;

  if ((lib$getdvi (&code, 0, &cmd, &devclass, 0, 0) & 1)
      && devclass == DC$_TERM                         /* not batch or network */
      && (sys$assign (&cmd, &ctrly_chan, 0, 0) & 1))
    {
      if ((lib$disable_ctrl (&mask, &old) & 1) && (old & mask))
        {
          ctrly_taken = 1;
          if (!(ctrly_arm () & 1))
            ctrly_give_back ();
        }
      else
        sys$dassgn (ctrly_chan);
    }
  if (getenv ("ANT_VMS_TRACE") != NULL)
    fprintf (stderr, "%s: CTRL/Y %s\n", prog, ctrly_taken ? "taken" : "left to DCL");
}

/* Give CTRL/Y back to DCL; also an atexit() handler.  */
static void
ctrly_give_back (void)
{
  unsigned int mask = LIB$M_CLI_CTRLY;

  if (!ctrly_taken)
    return;
  ctrly_taken = 0;
  sys$dassgn (ctrly_chan);      /* cancels the AST */
  lib$enable_ctrl (&mask, 0);
}

/* Java's standard output when it is not a terminal (vms-maven NOTES N25).  A Java
   started with vfork/execv writes one record for each write() to the
   standard output it inherits (a PIPE mailbox, a batch log, a file):
   PrintStream.println() writes the text and then the line end, so every line
   Ant logs was followed by an empty record, and text written a byte at a
   time came out a character to a line.  (A JVM that DCL runs itself joins
   its writes up to each line end.)  So the launcher gives Java a pipe for its
   standard output and writes what comes through it to its own, one line to
   each write().  On a terminal Java writes straight to it: lines come out
   right there, and a prompt must not wait for its line end.  Nor under
   DEFINE/USER SYS$OUTPUT (below).  The standard error is left alone.  */
static int relay_in = -1;
static int relay_out_fd = -1;
static int relay_saved = -1;

/* DEFINE/USER SYS$OUTPUT: a user-mode SYS$OUTPUT in the process table.
   Java's records there were whole lines already, and with the relay the
   images run after the launcher lost their output.  */
static int
user_mode_output (void)
{
  $DESCRIPTOR (table, "LNM$PROCESS_TABLE");
  $DESCRIPTOR (name, "SYS$OUTPUT");
  unsigned char mode = PSL$C_KERNEL, acmode = PSL$C_USER;
  unsigned short len = 0;
  struct { unsigned short len, code; void *addr; unsigned short *rlen; } items[2] = {
    { sizeof mode, LNM$_ACMODE, &mode, &len }, { 0, 0, 0, 0 } };
  if (!(sys$trnlnm (0, &table, &name, &acmode, items) & 1))
    return 0;
  return mode == PSL$C_USER;
}

/* Before the vfork: point this image's fd 1 at a new pipe, so that execv
   hands Java the pipe (the standard input and error are passed as before:
   decc$set_child_standard_streams would make Java open its standard error
   by name, which writes a new version of a `2> file`).  */
static void
relay_setup (void)
{
  int p[2];
  if (isatty (1) || user_mode_output () || pipe (p) != 0)
    return;
  fflush (stdout);
  relay_saved = dup (1);
  if (relay_saved < 0 || dup2 (p[1], 1) < 0)
    {
      if (relay_saved >= 0)
        close (relay_saved);
      relay_saved = -1;
      close (p[0]);
      close (p[1]);
      return;
    }
  relay_in = p[0];
  relay_out_fd = p[1];
}

/* After the vfork: fd 1 is this image's standard output again.  */
static void
relay_restore (void)
{
  if (relay_saved < 0)
    return;
  dup2 (relay_saved, 1);
  close (relay_saved);
  relay_saved = -1;
  close (relay_out_fd);
  relay_out_fd = -1;
}

static void
write_all (const char *s, size_t n)
{
  ssize_t w;
  while (n > 0)
    {
      w = write (1, s, n);
      if (w < 0 && errno == EINTR)
        continue;
      if (w <= 0)
        return;
      s += w;
      n -= w;
    }
}

/* Copy Java's output to this image's, a line at a time, until Java and
   whatever it started have closed the pipe (when Java exits: OpenVMS deletes
   a process's subprocesses with it).  */
static void
relay (void)
{
  static char line[32768];
  char buf[8192];
  size_t len = 0;
  ssize_t n, i;

  if (relay_in < 0)
    return;
  for (;;)
    {
      n = read (relay_in, buf, sizeof buf);
      if (n < 0 && errno == EINTR)
        continue;
      if (n <= 0)
        break;
      for (i = 0; i < n; i++)
        {
          line[len++] = buf[i];
          if (buf[i] == '\n' || len == sizeof line)
            {
              write_all (line, len);
              len = 0;
            }
        }
    }
  if (len > 0)
    write_all (line, len);
  close (relay_in);
  relay_in = -1;
}

/* The process's parse style: 1 if EXTENDED.  */
static int
parse_extended (void)
{
  int code = JPI$_PARSE_STYLE_PERM, value = 0;
  if (!(lib$getjpi (&code, 0, 0, &value, 0, 0) & 1))
    return 1;
  return value != 0;
}

/* The value of variable NAME if set and not empty, else NULL.  */
static const char *
env_value (const char *name)
{
  const char *v = getenv (name);
  return v != NULL && *v != '\0' ? v : NULL;
}

/* bin/ant's own options, taken out before Ant sees the rest.  */
static int
launcher_option (const char *a)
{
  return strcmp (a, "--noclasspath") == 0 || strcmp (a, "--execdebug") == 0
    || strcmp (a, "--noconfig") == 0;
}

int
main (int argc, char **argv)
{
  char *home, *java, *dclrunner;
  const char *classpath;
  pid_t pid;
  int i, st = 0, rc, noclasspath = 0;

  home = ant_home ();
  java = java_image ();
  map_programs (java);
  java_file_settings ();

  /* --noclasspath: not CLASSPATH; --execdebug: as ANT_VMS_TRACE;
     --noconfig: there is no ~/.antrc to skip.  */
  for (i = 1; i < argc; i++)
    if (strcmp (argv[i], "--noclasspath") == 0)
      noclasspath = 1;
    else if (strcmp (argv[i], "--execdebug") == 0)
      setenv ("ANT_VMS_TRACE", "1", 1);

  add ("java");
  /* Small-footprint defaults first, so ANT_OPTS overrides them (the JVM
     takes the last of each option).  */
  add_words (DEFAULT_JVM_OPTS);
  add_words (getenv ("ANT_OPTS"));
  add ("-classpath");
  add (join (home, "lib/ant-launcher.jar"));
  add (concat ("-Dant.home=", home));
  add (concat ("-Dant.library.dir=", join (home, "lib")));
  dclrunner = join (home, "bin/antdcl.exe");
  if (is_file (dclrunner))
    add (concat ("-Dant.openvms.dclrunner=", dclrunner));
  add ("org.apache.tools.ant.launch.Launcher");
  add_words (getenv ("ANT_ARGS"));
  classpath = env_value ("CLASSPATH");
  if (classpath != NULL && !noclasspath)
    {
      add ("-cp");
      add (classpath);
    }
  for (i = 1; i < argc; i++)
    if (!launcher_option (argv[i]))
      add (argv[i]);
  jargv[jargc] = NULL;

  if (getenv ("ANT_VMS_TRACE") != NULL)
    {
      fprintf (stderr, "%s: %s", prog, java);
      for (i = 1; i < jargc; i++)
        fprintf (stderr, " \"%s\"", jargv[i]);
      fprintf (stderr, "\n");
    }

  /* CTRL/Y is taken before Java starts: taken once Java was running, the
     SIGINT the AST sent made Java exit 0 at once, without its shutdown
     hooks (vms-maven NOTES N24).  */
  atexit (ctrly_give_back);
  ctrly_take ();
  fflush (stdout);
  fflush (stderr);
  relay_setup ();
  if (getenv ("ANT_VMS_TRACE") != NULL)
    fprintf (stderr, "%s: output %s (isatty %d)\n", prog,
             relay_in >= 0 ? "relayed a line at a time" : "straight to Java",
             isatty (1));
  pid = vfork ();
  if (pid == 0)
    {
      execv (java, jargv);
      _exit (127);
    }
  relay_restore ();
  if (pid < 0)
    die ("cannot start Java (vfork)", strerror (errno));
  java_pid = pid;
  relay ();
  while ((i = waitpid (pid, &st, 0)) < 0 && errno == EINTR)
    ;
  java_pid = 0;
  ctrly_give_back ();
  if (getenv ("ANT_VMS_TRACE") != NULL)
    fprintf (stderr, "%s: Java ended, wait status %%X%08X, %d CTRL/Y\n",
             prog, st, ctrly_count);
  if (i < 0)
    die ("waiting for Java failed", strerror (errno));
  if (WIFEXITED (st))
    rc = WEXITSTATUS (st);
  else if (WIFSIGNALED (st))
    rc = 128 + WTERMSIG (st);
  else
    rc = 1;
  if (rc == 127)
    die ("cannot run Java", java);
  if (rc != 0 && rc < 128)
    note_quotas ();
  if (rc != 0 && rc < 128 && !parse_extended () && argc > 1)
    fprintf (stderr, "%s: note: this process has the TRADITIONAL parse style, so "
             "arguments not in quotes reached Ant in lower case "
             "(SET PROCESS/PARSE_STYLE=EXTENDED, or quote them)\n", prog);
  if (rc >= 128)
    {
      /* Stopped by a signal: 130 after CTRL/C or CTRL/Y.  exit(n) under
         _POSIX_EXIT gives n >= 128 the success severity (%X0035A411 for
         130), so a build stopped half-way would look as if it had worked.
         The same code with the error severity and the inhibit-message
         bit, as the C RTL gives n < 128 (%X1035A412).  */
      fflush (stdout);
      fflush (stderr);
      sys$exit (0x1035A002 | (rc << 3));
    }
  /* exit(), not return: only exit() maps the code to a VMS status under
     _POSIX_EXIT, and return 1 would be SS$_NORMAL.  */
  exit (rc);
}
