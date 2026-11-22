/* antdcl.c - run one DCL procedure for Ant, and return a Unix exit code.

   Usage: ANTDCL <procedure>    (a Unix path or an OpenVMS file spec)

   Ant's VmsCommandLauncher (<exec vmlauncher="false">, and Ant's own reading
   of the environment) writes a DCL procedure and runs it.  Started directly
   from VSI's JVM, a procedure fails at random before its first line:
   "%DCL-E-OPENIN, error opening _MBAnnnn:[...].; as input", 9 starts in 15
   (NOTES N8); images start reliably.  So the launcher's procedure is started
   through this image (patch 0004: the system property ant.openvms.dclrunner,
   which ANT.EXE sets), which runs it with LIB$SPAWN:

     - command @<procedure>, input from NL: (DCL reading the input mailbox is
       what fails; Ant's <exec> input does not reach a DCL procedure),
     - output to a mailbox of its own, whose records it copies to its
       standard output (the pipe Java reads) a line at a time, each with a
       line end: handed Java's pipe itself, DCL's records came through
       without line ends, and an empty one (SHOW LOGICAL starts with one)
       read as the end of the output (NOTES N9),
     - symbols and logical names copied from this process, as SPAWN does.

   The procedure's completion status becomes the exit code Java reports
   (Process.exitValue): 0 for a success status; n for the C run-time
   library's code of exit(n); else the status's low byte (as VSI's JVM
   reports other statuses), or 1 if that is 0.

   ANT_VMS_TRACE (any value) prints the command and the status.

   Part of vms-ant (github.com/issinoho/vms-ant); Apache License 2.0.  */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <unixlib.h>

#include <clidef.h>
#include <descrip.h>
#include <dvidef.h>
#include <iodef.h>
#include <lib$routines.h>
#include <starlet.h>
#include <ssdef.h>

#define MBX_MAXMSG 4096         /* the longest record DCL writes is shorter */
#define MBX_BUFQUO 16384

static const char *prog = "antdcl";
static char vms_name[4096];
static unsigned short mbx_chan;
static volatile int done;

/* decc$to_vms calls this with each OpenVMS name; keep the first.  */
static int
take_name (char *name, int type)
{
  strncpy (vms_name, name, sizeof vms_name - 1);
  vms_name[sizeof vms_name - 1] = '\0';
  return 0;                     /* stop after one */
}

static void
set_desc (struct dsc$descriptor_s *d, const char *s)
{
  d->dsc$w_length = (unsigned short) strlen (s);
  d->dsc$b_dtype = DSC$K_DTYPE_T;
  d->dsc$b_class = DSC$K_CLASS_S;
  d->dsc$a_pointer = (char *) s;
}

/* The status as a Unix exit code (see the top of this file).  */
static int
exit_code (unsigned int st)
{
  int n;
  if (st & 1)
    return 0;
  if ((st & 0x0FFFF000) == 0x0035A000)  /* C$_FACILITY, exit(n) */
    n = (st >> 3) & 0xFF;
  else
    n = st & 0xFF;
  return n != 0 ? n : 1;
}

/* Exit with Unix exit code CODE as VSI's JVM reads it (NOTES N8):
   %X10000001 is 0, %X1035A002 + 8n is n.  */
static void
unix_exit (int code)
{
  fflush (stdout);
  fflush (stderr);
  sys$exit (code == 0 ? (SS$_NORMAL | 0x10000000) : (0x1035A002 | (code << 3)));
}

/* The subprocess has ended: an end-of-file after its last record tells the
   reader to stop.  */
static void
spawn_done (int arg)
{
  done = 1;
  sys$qio (0, mbx_chan, IO$_WRITEOF | IO$M_NOW, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static void
write_all (const char *p, size_t n)
{
  ssize_t w;
  while (n > 0)
    {
      w = write (1, p, n);
      if (w < 0 && errno == EINTR)
        continue;
      if (w <= 0)
        return;
      p += w;
      n -= w;
    }
}

int
main (int argc, char **argv)
{
  struct dsc$descriptor_s cmd_d, in_d, out_d;
  struct { unsigned short status, count; unsigned int dev; } iosb;
  static char rec[MBX_MAXMSG + 1];
  char *cmd, mbx_name[64];
  const char *spec;
  unsigned int flags = CLI$M_NOWAIT, status = 0, pid = 0;
  unsigned short len = 0;
  int sts, code = DVI$_DEVNAM, trace = getenv ("ANT_VMS_TRACE") != NULL;

  if (argc != 2)
    {
      fprintf (stderr, "usage: %s <procedure>\n", prog);
      unix_exit (2);
    }
  spec = argv[1];
  if (strchr (spec, '/') != NULL)
    {
      vms_name[0] = '\0';
      if (decc$to_vms (spec, take_name, 0, 0) < 1 || vms_name[0] == '\0')
        {
          fprintf (stderr, "%s: cannot translate %s to an OpenVMS name\n", prog, spec);
          unix_exit (2);
        }
      spec = vms_name;
    }
  cmd = malloc (strlen (spec) + 2);
  if (cmd == NULL)
    unix_exit (2);
  strcpy (cmd, "@");
  strcat (cmd, spec);

  /* The subprocess's output: a temporary mailbox of this process's own.  */
  sts = sys$crembx (0, &mbx_chan, MBX_MAXMSG, MBX_BUFQUO, 0, 0, 0, 0, 0);
  if (sts & 1)
    {
      out_d.dsc$w_length = sizeof mbx_name - 1;
      out_d.dsc$b_dtype = DSC$K_DTYPE_T;
      out_d.dsc$b_class = DSC$K_CLASS_S;
      out_d.dsc$a_pointer = mbx_name;
      sts = lib$getdvi (&code, &mbx_chan, 0, 0, &out_d, &len);
    }
  if (!(sts & 1))
    {
      fprintf (stderr, "%s: cannot create a mailbox (%%X%08X)\n", prog, sts);
      unix_exit (2);
    }
  mbx_name[len] = '\0';
  set_desc (&out_d, mbx_name);
  if (trace)
    fprintf (stderr, "%s: SPAWN %s, output %s\n", prog, cmd, mbx_name);
  set_desc (&cmd_d, cmd);
  set_desc (&in_d, "NL:");
  sts = lib$spawn (&cmd_d, &in_d, &out_d, &flags, 0, &pid, &status, 0,
                   (void (*) ()) spawn_done, 0, 0, 0, 0);
  if (!(sts & 1))
    {
      fprintf (stderr, "%s: cannot run %s (LIB$SPAWN %%X%08X)\n", prog, cmd, sts);
      unix_exit (2);
    }

  /* Copy each record, with a line end.  DCL may write an end-of-file of its
     own; only one after the subprocess has ended (spawn_done's) is the end.  */
  for (;;)
    {
      sts = sys$qiow (0, mbx_chan, IO$_READVBLK, &iosb, 0, 0,
                      rec, MBX_MAXMSG, 0, 0, 0, 0);
      if (sts & 1)
        sts = iosb.status;
      if (sts == SS$_ENDOFFILE)
        {
          if (done)
            break;
          continue;
        }
      if (!(sts & 1))
        {
          fprintf (stderr, "%s: reading the output failed (%%X%08X)\n", prog, sts);
          break;
        }
      rec[iosb.count] = '\n';
      write_all (rec, iosb.count + 1);
    }
  while (!done)
    sys$hiber ();
  code = exit_code (status);
  if (trace)
    fprintf (stderr, "%s: status %%X%08X, exit code %d\n", prog, status, code);
  unix_exit (code);
  return 0;
}
