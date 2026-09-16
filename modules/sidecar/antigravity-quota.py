#!/usr/bin/env python3
"""Read the Antigravity CLI's plan quota, which it shows only in its interactive /usage panel.

    antigravity-quota.py            # drives `agy` under a pseudo-terminal, prints one line:
                                    #   weekly=97.71 weekly_reset=167h21m five_hour=94.34 five_hour_reset=4h21m
    antigravity-quota.py --parse F  # parses a saved screen dump instead (tests)

The numbers are the GEMINI MODELS group (Flash and Pro share it). Exit codes: 0 read; 2 no usage
panel in what the CLI printed; 3 the CLI's first-run wizard is up (theme, data-use consent) — that
is the user's to answer, never this script's; 4 not signed in.
"""
import fcntl, os, pty, re, select, signal, struct, sys, termios, time

QUOTA_DIR = os.path.join(os.path.expanduser("~"), ".claude", "sidecar-run", "agy-quota")   # an empty folder of ours to trust
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[()=>][A-Z0-9]?")


def clean(s):
    s = ANSI.sub("", s).replace("\r", "\n")
    return re.sub(r"[ \t]{2,}", "  ", s)


def parse(screen):
    """The Gemini group's two bars. Returns the one-line reading, or None."""
    text = clean(screen)
    m = re.search(r"GEMINI MODELS(.*?)(?:CLAUDE AND GPT MODELS|Within each group|$)", text, re.S)
    if not m:
        return None
    sect = m.group(1)
    out = {}
    for key, label in (("weekly", "Weekly Limit Remaining"), ("five_hour", "Five Hour Limit Remaining")):
        mm = re.search(re.escape(label) + r".*?(\d+(?:\.\d+)?)%(.*?)(?=Weekly Limit|Five Hour Limit|$)", sect, re.S)
        if not mm:
            return None
        out[key] = mm.group(1)
        r = re.search(r"Refreshes in ([0-9]+h(?: [0-9]+m)?|[0-9]+m)", mm.group(2))
        out[key + "_reset"] = r.group(1).replace(" ", "") if r else "-"
    return f"weekly={out['weekly']} weekly_reset={out['weekly_reset']} five_hour={out['five_hour']} five_hour_reset={out['five_hour_reset']}"


def drive():
    os.makedirs(QUOTA_DIR, exist_ok=True)
    env = {**os.environ, "TERM": "xterm-256color", "COLUMNS": "150", "LINES": "45"}
    local_bin = os.path.join(os.path.expanduser("~"), ".local", "bin")     # where the installer puts agy; a session's shell may lack it
    if local_bin not in env.get("PATH", "").split(":"):
        env["PATH"] = local_bin + ":" + env.get("PATH", "")
    for k in ("GEMINI_API_KEY", "GOOGLE_API_KEY", "SSH_CONNECTION", "SSH_TTY"):
        env.pop(k, None)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(QUOTA_DIR)
        os.execvpe("agy", ["agy"], env)
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 150, 0, 0))
    except OSError:
        pass
    buf = ""

    def read_for(secs):
        nonlocal buf
        end = time.time() + secs
        chunk = ""
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.3)
            if r:
                try:
                    c = os.read(fd, 65536).decode("utf-8", "replace")
                except OSError:
                    break
                if not c:
                    break
                buf += c; chunk += c
        return chunk

    def finish(code, msg=None):
        try:
            os.write(fd, b"\x1b/exit\r"); time.sleep(0.5)
        except OSError:
            pass
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        if msg:
            print(msg, file=sys.stderr)
        return code

    deadline = time.time() + 30
    while time.time() < deadline:
        read_for(1)
        text = clean(buf)
        if "Terms of Service" in text or "Choose your color scheme" in text:
            return finish(3, "agy's first-run wizard is up (theme, data-use consent): finish it yourself by running `agy` once, then try again")
        if "Do you trust the contents" in text:
            os.write(fd, b"\r"); buf = ""; continue          # our own empty folder
        # Only the real login prompt means not signed in. The banner says "You are currently not
        # signed in. Signing in..." for a second while a stored token is refreshed (seen 2026-09-16
        # from another session, after the token had expired overnight), and bailing on that killed
        # a CLI that was about to authenticate.
        if "Authentication required" in text or "Please visit the URL" in text:
            return finish(4, "not signed in to Antigravity CLI: run `agy` once and sign in with Google")
        if "? for shortcuts" in text:
            break
    else:
        return finish(2, "no prompt from agy within 30 s")
    os.write(fd, b"/usage"); time.sleep(1.2); os.write(fd, b"\r")
    panel = read_for(8)
    line = parse(panel) or parse(buf)
    if not line:
        return finish(2, "no usage panel in what agy printed")
    print(line)
    return finish(0)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--parse":
        line = parse(open(sys.argv[2], encoding="utf-8", errors="replace").read())
        print(line or "", end="\n" if line else "")
        sys.exit(0 if line else 2)
    sys.exit(drive())
