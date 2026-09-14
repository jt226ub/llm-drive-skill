#!/usr/bin/env python3
"""Antigravity CLI login relay: `agy -p` under a pty that looks like an SSH session prints a Google URL and waits
60 s for the sign-in to complete (or for a pasted code). DIR/url.txt gets the URL; DIR/code.txt, if it appears,
is typed in; DIR/status.txt ends `ok` (the call answered) or `failed: <why>`; DIR/transcript.txt has everything."""
import os, pty, re, select, signal, sys, time
from pathlib import Path

d = Path(sys.argv[1]); d.mkdir(parents=True, exist_ok=True)
for n in ("url.txt", "code.txt", "status.txt"):
    (d / n).unlink(missing_ok=True)
status = lambda s: (d / "status.txt").write_text(s + "\n")
env = {**os.environ, "SSH_CONNECTION": "10.0.0.1 1 10.0.0.2 22", "SSH_TTY": "/dev/ttys999", "BROWSER": "/usr/bin/false", "TERM": "dumb",
       "PATH": os.path.expanduser("~/.local/bin") + ":" + os.environ["PATH"]}
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("agy", ["agy", "-p", "Reply with the single word OK.", "--output-format", "json"], env)
buf, url_sent, code_sent = "", False, False
deadline = time.time() + 400
with open(d / "transcript.txt", "w", buffering=1) as tr:
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            try:
                c = os.read(fd, 4096).decode("utf-8", "replace")
            except OSError:
                break
            if not c:
                break
            tr.write(c); buf += c
            if not url_sent:
                m = re.search(r"https://accounts\.google\.com/\S+", buf)
                if m:
                    (d / "url.txt").write_text(m.group(0) + "\n"); url_sent = True
                    status("waiting: 60 s from " + time.strftime("%H:%M:%S"))
        if url_sent and not code_sent and (d / "code.txt").exists():
            code = (d / "code.txt").read_text().strip()
            if code:
                os.write(fd, (code + "\n").encode()); code_sent = True
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass
clean = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", buf)
if '"status":"SUCCESS"' in clean:
    status("ok")
elif "timed out" in clean:
    status("failed: timed out after 60 s (code_sent=%s)" % code_sent)
else:
    status("failed: see transcript.txt")
print((d / "status.txt").read_text().strip())
