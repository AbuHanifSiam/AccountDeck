#!/usr/bin/env python3
"""Builds a demo home folder for README screenshots: made-up accounts, usage and chats.
Usage: make-demo-home.py <folder>   (the folder is wiped first)"""
import base64, json, os, shutil, sys, time, uuid

H = os.path.abspath(sys.argv[1])
if os.path.basename(H) != "demo-home": sys.exit("the folder must be named demo-home")
shutil.rmtree(H, ignore_errors=True)
now = time.time()

def w(path, data, mtime=None):
    p = os.path.join(H, path); os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f: f.write(data if isinstance(data, str) else json.dumps(data, indent=1))
    if mtime: os.utime(p, (mtime, mtime))

AD = H + "/.accountdeck"
UA, UB, UC, UD = (str(uuid.UUID(int=i)) for i in (0xA1, 0xB2, 0xC3, 0xD4))
ORGA, ORGB = str(uuid.UUID(int=0x0A)), str(uuid.UUID(int=0x0B))

accounts = [
  dict(id="desktop-default", service="desktop", name="Work", isDefault=True, dir=AD + "/desktop/desktop-default"),
  dict(id="desktop-personal", service="desktop", name="Personal", isDefault=False, dir=AD + "/desktop/desktop-personal"),
  dict(id="claude-default", service="claude", name="Main", isDefault=True, dir=H + "/.claude"),
  dict(id="claude-client", service="claude", name="Client", isDefault=False, dir=AD + "/claude/claude-client"),
  dict(id="codex-default", service="codex", name="Main", isDefault=True, dir=H + "/.codex"),
  dict(id="chatgpt-personal", service="chatgpt", name="Personal", isDefault=False, dir=AD + "/chatgpt/chatgpt-personal"),
]
w(".accountdeck/state.json", dict(accounts=accounts, active={"desktop": "desktop-default", "claude": "claude-default",
                                                              "codex": "codex-default", "chatgpt": "chatgpt-personal"}))
w(".accountdeck/chatgpt/chatgpt-personal/Default/Preferences", "{}")
w(".accountdeck/desktop/desktop-personal/Cookies", "demo")
w(".accountdeck/desktop/desktop-personal/config.json", {"lastKnownAccountUuid": UB})

# Claude Desktop (signed in as Work)
SUP = "Library/Application Support/Claude"
w(SUP + "/Cookies", "demo")
w(SUP + "/config.json", {"lastKnownAccountUuid": UA})
desk = {UA: (ORGA, ["Landing page redesign", "Fix checkout race condition", "Write release notes for 2.4",
                    "Refactor auth middleware", "Add dark mode to settings", "Plan Q1 roadmap"]),
        UB: (ORGB, ["Weekend game jam prototype", "Recipe app: offline sync", "Blog post draft"])}
for acc, (org, titles) in desk.items():
    for i, t in enumerate(titles):
        ts = (now - 3600 * (i * 5 + 1)) * 1000
        sid = str(uuid.uuid4())
        w(f"{SUP}/claude-code-sessions/{acc}/{org}/local_{sid}.json",
          dict(sessionId="local_" + sid, cliSessionId=str(uuid.uuid4()), cwd="/Users/alex/code/" + ["webapp", "api", "docs"][i % 3],
               title=t, createdAt=ts, lastActivityAt=ts, lastFocusedAt=ts, isArchived=False), mtime=ts / 1000)
samples = []
for k in range(36, -1, -1):                       # usage over the last 3 hours, every 5 min
    t = now - k * 300
    samples.append(dict(t=int(t * 1000), org=ORGA, u=dict(fh=round(4 + (36 - k) * 0.85, 1), sd=22)))
for k in range(12, 0, -1):
    samples.append(dict(t=int((now - 86400 - k * 600) * 1000), org=ORGB, u=dict(fh=0, sd=61)))
w(SUP + "/plan-usage-history.json", dict(samples=samples))

# Claude Code: Main
w(".claude.json", dict(oauthAccount=dict(emailAddress="alex@example.com", organizationName="Example Studio", accountUuid=UC),
                       mcpServers={k: {"command": "npx"} for k in ["github", "figma", "playwright", "linear"]}))
hook = {"type": "command", "command": 'sh "$HOME/.accountdeck/claude-status.sh"'}
w(".claude/settings.json", dict(model="opus", statusLine=hook, permissions=dict(allow=["Bash(npm test)"]),
                                enabledPlugins={"frontend-design": True, "code-review": True}, hooks={"PostToolUse": []}))
for s in ["pdf", "docx", "release-notes", "design-review", "deploy"]:
    w(f".claude/skills/{s}/SKILL.md", f"# {s}\n")
w(".claude/CLAUDE.md", "# Project notes\n")
chats = [("webapp", "Build the onboarding flow"), ("webapp", "Speed up the image pipeline"), ("api", "Add rate limiting to /v1/search"),
         ("api", "Migrate to Postgres 17"), ("docs", "Rewrite the getting-started guide"), ("webapp", "Fix flaky e2e tests"),
         ("api", "Stripe webhook retries"), ("docs", "API reference examples")]
for i, (proj, title) in enumerate(chats):
    sid = str(uuid.uuid4()); cwd = "/Users/alex/code/" + proj
    lines = [dict(type="user", cwd=cwd, sessionId=sid, message=dict(role="user", content=title)),
             dict(type="ai-title", aiTitle=title, sessionId=sid)]
    w(f".claude/projects/-Users-alex-code-{proj}/{sid}.jsonl", "\n".join(json.dumps(l) for l in lines) + "\n", mtime=now - 3600 * (i * 3 + 1))
def status(path, five, week, reset_min, sid="demo-session"):
    w(path + f"/.accountdeck-status/{sid}.json",
      dict(session_id=sid, rate_limits=dict(five_hour=dict(used_percentage=five, resets_at=int(now + reset_min * 60)),
                                            seven_day=dict(used_percentage=week, resets_at=int(now + 4 * 86400)))), mtime=now - 40)
status(".claude", 42, 18, 134)

# Claude Code: Client
CL = ".accountdeck/claude/claude-client"
w(CL + "/.claude.json", dict(oauthAccount=dict(emailAddress="alex@client.dev", organizationName="Client Co", accountUuid=UD),
                             mcpServers={"sentry": {"command": "npx"}}))
w(CL + "/settings.json", dict(statusLine=hook))
status(CL, 76, 49, 51)

# Codex
def b64(o): return base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip("=")
w(".codex/auth.json", dict(tokens=dict(id_token=b64({"alg": "none"}) + "." + b64({"email": "alex@example.com"}) + ".sig")))
rl = dict(rate_limits=dict(primary=dict(used_percent=23, window_minutes=300, resets_in_seconds=9000),
                           secondary=dict(used_percent=41, window_minutes=10080, resets_in_seconds=3 * 86400)))
w(".codex/sessions/2026/11/15/rollout-2026-11-15T09-00-00-demo.jsonl",
  json.dumps(dict(type="event_msg", payload=dict(type="token_count", **rl))) + "\n")
w(".zshrc", "# >>> AccountDeck >>>\n[ -f ~/.accountdeck/env.sh ] && source ~/.accountdeck/env.sh\n# <<< AccountDeck <<<\n")
print("demo home:", H)
