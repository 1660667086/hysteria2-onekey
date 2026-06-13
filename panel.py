#!/usr/bin/env python3
import base64
import grp
import hmac
import html
import json
import os
import re
import secrets
import shlex
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
try:
    from http.server import ThreadingHTTPServer
except ImportError:
    from socketserver import ThreadingMixIn

    class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
        daemon_threads = True
from urllib.parse import parse_qs, quote, urlencode, urlparse


CONFIG_DIR = os.environ.get("CONFIG_DIR", "/etc/hysteria")
CONFIG_FILE = os.environ.get("CONFIG_FILE", os.path.join(CONFIG_DIR, "config.yaml"))
USERS_FILE = os.environ.get("USERS_FILE", os.path.join(CONFIG_DIR, "users.json"))
SERVER_META_FILE = os.environ.get("SERVER_META_FILE", os.path.join(CONFIG_DIR, "server.json"))
CERT_FILE = os.environ.get("CERT_FILE", os.path.join(CONFIG_DIR, "server.crt"))
KEY_FILE = os.environ.get("KEY_FILE", os.path.join(CONFIG_DIR, "server.key"))
PANEL_BIND = os.environ.get("PANEL_BIND", "0.0.0.0")
PANEL_PORT = int(os.environ.get("PANEL_PORT", "8080"))
PANEL_ADMIN_USER = os.environ.get("PANEL_ADMIN_USER", "admin")
PANEL_ADMIN_PASS = os.environ.get("PANEL_ADMIN_PASS", "")
RESTART_CMD = os.environ.get("HYSTERIA_RESTART_CMD", "systemctl restart hysteria-server.service")
CSRF_TOKEN = secrets.token_urlsafe(32)
TZ_OFFSET_RE = re.compile(r"([+-])(\d{2}):?(\d{2})$")


def atomic_write(path, data, mode=0o600):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(data)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def read_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return default


def load_users():
    data = read_json(USERS_FILE, {"users": []})
    users = data.get("users", [])
    clean = []
    for user in users:
        name = str(user.get("name", "")).strip()
        password = str(user.get("password", ""))
        if not name or not password:
            continue
        clean.append(
            {
                "name": name,
                "password": password,
                "enabled": bool(user.get("enabled", True)),
                "created_at": user.get("created_at", ""),
                "expires_at": str(user.get("expires_at", "") or ""),
                "disabled_reason": str(user.get("disabled_reason", "") or ""),
                "expired_at": str(user.get("expired_at", "") or ""),
            }
        )
    return clean


def save_users(users):
    atomic_write(
        USERS_FILE,
        json.dumps({"users": users}, indent=2, ensure_ascii=False) + "\n",
        0o600,
    )


def load_meta():
    meta = read_json(SERVER_META_FILE, {})
    return {
        "host": str(meta.get("host", "")),
        "port": int(meta.get("port", 443)),
        "sni": str(meta.get("sni", "www.bing.com")),
        "masquerade_url": str(meta.get("masquerade_url", "https://www.bing.com/")),
        "enable_obfs": bool(meta.get("enable_obfs", True)),
        "obfs_pass": str(meta.get("obfs_pass", "")),
        "tag": str(meta.get("tag", "hysteria2")),
        "cert_file": str(meta.get("cert_file", CERT_FILE)),
        "key_file": str(meta.get("key_file", KEY_FILE)),
    }


def yaml_string(value):
    return json.dumps(str(value), ensure_ascii=False)


def render_config():
    meta = load_meta()
    users = active_users(load_users())
    if not users:
        users = [
            {
                "name": "__expired_lock__",
                "password": secrets.token_hex(32),
            }
        ]

    lines = [
        f"listen: :{meta['port']}",
        "",
        "tls:",
        f"  cert: {yaml_string(meta['cert_file'])}",
        f"  key: {yaml_string(meta['key_file'])}",
        "  sniGuard: disable",
        "",
        "auth:",
        "  type: userpass",
        "  userpass:",
    ]

    for user in users:
        lines.append(f"    {yaml_string(user['name'])}: {yaml_string(user['password'])}")

    if meta["enable_obfs"]:
        lines.extend(
            [
                "",
                "obfs:",
                "  type: salamander",
                "  salamander:",
                f"    password: {yaml_string(meta['obfs_pass'])}",
            ]
        )

    lines.extend(
        [
            "",
            "masquerade:",
            "  type: proxy",
            "  proxy:",
            f"    url: {yaml_string(meta['masquerade_url'])}",
            "    rewriteHost: true",
            "",
        ]
    )

    atomic_write(CONFIG_FILE, "\n".join(lines), 0o640)
    try:
        os.chown(CONFIG_FILE, 0, grp.getgrnam("hysteria").gr_gid)
    except Exception:
        pass
    return CONFIG_FILE


def restart_hysteria():
    expire_users(restart=False)
    render_config()
    subprocess.run(shlex.split(RESTART_CMD), check=True)


def certificate_fingerprint(cert_file):
    try:
        out = subprocess.check_output(
            ["openssl", "x509", "-noout", "-fingerprint", "-sha256", "-in", cert_file],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return ""
    return out.strip().split("=", 1)[-1]


def build_uri(user):
    meta = load_meta()
    host = meta["host"]
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    auth = f"{quote(user['name'], safe='')}:{quote(user['password'], safe='')}"
    params = {
        "insecure": "1",
        "sni": meta["sni"],
    }
    if meta["enable_obfs"]:
        params["obfs"] = "salamander"
        params["obfs-password"] = meta["obfs_pass"]
    fingerprint = certificate_fingerprint(meta["cert_file"])
    if fingerprint:
        params["pinSHA256"] = fingerprint
    tag = quote(f"{meta['tag']}-{user['name']}", safe="")
    return f"hysteria2://{auth}@{host}:{meta['port']}/?{urlencode(params, safe=':')}#{tag}"


def valid_username(name):
    if not 1 <= len(name) <= 64:
        return False
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.@-")
    return all(ch in allowed for ch in name)


def utc_now():
    return datetime.now(timezone.utc)


def now_iso():
    return utc_now().strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_utc(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_datetime_compat(value):
    raw = str(value or "").strip()
    if not raw:
        return None

    tz = None
    match = TZ_OFFSET_RE.search(raw)
    if match:
        sign, hours, minutes = match.groups()
        offset = timedelta(hours=int(hours), minutes=int(minutes))
        if sign == "-":
            offset = -offset
        tz = timezone(offset)
        raw = raw[: match.start()]

    formats = (
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
    )
    for fmt in formats:
        try:
            dt = datetime.strptime(raw, fmt)
        except ValueError:
            continue
        if tz is not None:
            dt = dt.replace(tzinfo=tz)
        elif dt.tzinfo is None:
            dt = dt.astimezone()
        return dt.astimezone(timezone.utc)
    return None


def parse_datetime(value):
    value = str(value or "").strip()
    if not value:
        return None
    normalized = value
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(normalized)
    except AttributeError:
        return parse_datetime_compat(normalized)
    except ValueError:
        return parse_datetime_compat(normalized)
    if dt.tzinfo is None:
        dt = dt.astimezone()
    return dt.astimezone(timezone.utc)


def parse_expiry_form(form):
    valid_days = str(form.get("valid_days", "") or "").strip()
    expires_at = str(form.get("expires_at", "") or "").strip()
    if valid_days:
        try:
            days = int(valid_days)
        except ValueError as exc:
            raise ValueError("valid days must be a number") from exc
        if days < 1:
            raise ValueError("valid days must be at least 1")
        return iso_utc(utc_now() + timedelta(days=days))
    if not expires_at:
        return ""
    dt = parse_datetime(expires_at)
    if dt is None:
        raise ValueError("expiry time must be a valid date and time")
    return iso_utc(dt)


def is_expired(user, now=None):
    expires = parse_datetime(user.get("expires_at", ""))
    if expires is None:
        return False
    return expires <= (now or utc_now())


def active_users(users):
    now = utc_now()
    return [user for user in users if user.get("enabled") and not is_expired(user, now)]


def expiry_display(user):
    expires_at = user.get("expires_at", "")
    if not expires_at:
        return "Never"
    dt = parse_datetime(expires_at)
    if dt is None:
        return expires_at
    return dt.astimezone().strftime("%Y-%m-%d %H:%M:%S %z")


def expiry_input_value(user):
    dt = parse_datetime(user.get("expires_at", ""))
    if dt is None:
        return ""
    return dt.astimezone().strftime("%Y-%m-%dT%H:%M")


def user_status(user):
    if is_expired(user):
        return "expired"
    if user.get("enabled"):
        return "enabled"
    return "disabled"


def find_user(users, name):
    for user in users:
        if user["name"] == name:
            return user
    return None


def enabled_count(users):
    return len(active_users(users))


def expire_users(restart=False):
    users = load_users()
    now = utc_now()
    changed = False
    expired_names = []
    for user in users:
        if user.get("enabled") and is_expired(user, now):
            user["enabled"] = False
            user["disabled_reason"] = "expired"
            user["expired_at"] = now_iso()
            changed = True
            expired_names.append(user["name"])
    if changed:
        save_users(users)
        if restart:
            restart_hysteria()
    return expired_names


class PanelHandler(BaseHTTPRequestHandler):
    server_version = "HysteriaPanel/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def require_auth(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            raw = base64.b64decode(header[6:], validate=True).decode("utf-8")
        except Exception:
            return False
        username, sep, password = raw.partition(":")
        if not sep:
            return False
        return hmac.compare_digest(username, PANEL_ADMIN_USER) and hmac.compare_digest(
            password, PANEL_ADMIN_PASS
        )

    def send_auth_required(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Hysteria 2 Panel"')
        self.end_headers()

    def send_text(self, text, status=200, content_type="text/plain; charset=utf-8"):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Frame-Options", "DENY")
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, message=""):
        location = "/"
        if message:
            location += "?msg=" + quote(message)
        self.send_response(303)
        self.send_header("Location", location)
        self.end_headers()

    def parse_post(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 65536:
            raise ValueError("request body too large")
        body = self.rfile.read(length).decode("utf-8")
        form = {key: values[-1] for key, values in parse_qs(body).items()}
        if form.get("csrf") != CSRF_TOKEN:
            raise ValueError("invalid CSRF token")
        return form

    def do_GET(self):
        if not self.require_auth():
            self.send_auth_required()
            return
        path = urlparse(self.path)
        if path.path == "/uri":
            name = parse_qs(path.query).get("u", [""])[0]
            user = find_user(load_users(), name)
            if not user:
                self.send_text("user not found\n", 404)
                return
            self.send_text(build_uri(user) + "\n")
            return
        self.send_text(self.render_page(path), content_type="text/html; charset=utf-8")

    def do_POST(self):
        if not self.require_auth():
            self.send_auth_required()
            return
        try:
            form = self.parse_post()
            action = urlparse(self.path).path
            if action == "/users/add":
                self.add_user(form)
            elif action == "/users/delete":
                self.delete_user(form)
            elif action == "/users/toggle":
                self.toggle_user(form)
            elif action == "/users/password":
                self.change_password(form)
            elif action == "/users/expiry":
                self.change_expiry(form)
            elif action == "/service/restart":
                restart_hysteria()
                self.redirect("service restarted")
            else:
                self.send_text("not found\n", 404)
        except Exception as exc:
            self.redirect(f"error: {exc}")

    def add_user(self, form):
        name = form.get("name", "").strip()
        password = form.get("password", "").strip() or secrets.token_hex(16)
        if not valid_username(name):
            raise ValueError("username must be 1-64 chars: letters, numbers, _ . @ -")
        if len(password) < 6:
            raise ValueError("password must be at least 6 chars")
        users = load_users()
        if find_user(users, name):
            raise ValueError("user already exists")
        expires_at = parse_expiry_form(form)
        users.append(
            {
                "name": name,
                "password": password,
                "enabled": True,
                "created_at": now_iso(),
                "expires_at": expires_at,
            }
        )
        save_users(users)
        restart_hysteria()
        self.redirect(f"user {name} added")

    def delete_user(self, form):
        name = form.get("name", "").strip()
        users = load_users()
        user = find_user(users, name)
        if not user:
            raise ValueError("user not found")
        if user.get("enabled") and not is_expired(user) and enabled_count(users) <= 1:
            raise ValueError("cannot delete the last enabled user")
        users = [item for item in users if item["name"] != name]
        save_users(users)
        restart_hysteria()
        self.redirect(f"user {name} deleted")

    def toggle_user(self, form):
        name = form.get("name", "").strip()
        users = load_users()
        user = find_user(users, name)
        if not user:
            raise ValueError("user not found")
        if user.get("enabled") and not is_expired(user) and enabled_count(users) <= 1:
            raise ValueError("cannot disable the last enabled user")
        if not user.get("enabled") and is_expired(user):
            raise ValueError("user is expired; clear or extend expiry before enabling")
        user["enabled"] = not user.get("enabled")
        if user["enabled"]:
            user["disabled_reason"] = ""
        save_users(users)
        restart_hysteria()
        self.redirect(f"user {name} updated")

    def change_password(self, form):
        name = form.get("name", "").strip()
        password = form.get("password", "").strip() or secrets.token_hex(16)
        if len(password) < 6:
            raise ValueError("password must be at least 6 chars")
        users = load_users()
        user = find_user(users, name)
        if not user:
            raise ValueError("user not found")
        user["password"] = password
        save_users(users)
        restart_hysteria()
        self.redirect(f"password changed for {name}")

    def change_expiry(self, form):
        name = form.get("name", "").strip()
        users = load_users()
        user = find_user(users, name)
        if not user:
            raise ValueError("user not found")
        if form.get("clear") == "1":
            user["expires_at"] = ""
        else:
            user["expires_at"] = parse_expiry_form(form)
        if user.get("expires_at") and is_expired(user):
            user["enabled"] = False
            user["disabled_reason"] = "expired"
            user["expired_at"] = now_iso()
        elif user.get("disabled_reason") == "expired":
            user["disabled_reason"] = ""
            user["expired_at"] = ""
        save_users(users)
        restart_hysteria()
        self.redirect(f"expiry updated for {name}")

    def render_page(self, parsed):
        msg = parse_qs(parsed.query).get("msg", [""])[0]
        users = load_users()
        rows = []
        for user in users:
            name = html.escape(user["name"])
            status = user_status(user)
            expires = html.escape(expiry_display(user))
            expiry_value = html.escape(expiry_input_value(user))
            uri = html.escape(build_uri(user))
            toggle = "Disable" if user.get("enabled") else "Enable"
            rows.append(
                f"""
                <tr>
                  <td><strong>{name}</strong><br><span class="muted">{html.escape(user.get('created_at', ''))}</span></td>
                  <td><span class="badge {status}">{status}</span></td>
                  <td><strong>{expires}</strong></td>
                  <td><input readonly value="{uri}" onclick="this.select()"></td>
                  <td class="actions">
                    <form method="post" action="/users/toggle"><input type="hidden" name="csrf" value="{CSRF_TOKEN}"><input type="hidden" name="name" value="{name}"><button>{toggle}</button></form>
                    <form method="post" action="/users/password"><input type="hidden" name="csrf" value="{CSRF_TOKEN}"><input type="hidden" name="name" value="{name}"><input name="password" placeholder="new or blank random"><button>Set Pass</button></form>
                    <form method="post" action="/users/expiry"><input type="hidden" name="csrf" value="{CSRF_TOKEN}"><input type="hidden" name="name" value="{name}"><input name="valid_days" placeholder="days"><input type="datetime-local" name="expires_at" value="{expiry_value}"><button>Set Expiry</button></form>
                    <form method="post" action="/users/expiry"><input type="hidden" name="csrf" value="{CSRF_TOKEN}"><input type="hidden" name="name" value="{name}"><input type="hidden" name="clear" value="1"><button>Clear Expiry</button></form>
                    <form method="post" action="/users/delete"><input type="hidden" name="csrf" value="{CSRF_TOKEN}"><input type="hidden" name="name" value="{name}"><button class="danger">Delete</button></form>
                  </td>
                </tr>
                """
            )

        meta = load_meta()
        flash = f'<div class="flash">{html.escape(msg)}</div>' if msg else ""
        return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Hysteria 2 Panel</title>
  <style>
    body {{ margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f5f7fb; color: #202635; }}
    header {{ background: #172033; color: white; padding: 24px 32px; }}
    main {{ max-width: 1180px; margin: 24px auto; padding: 0 20px; }}
    section {{ background: white; border: 1px solid #e0e5ef; border-radius: 8px; margin-bottom: 18px; padding: 20px; }}
    h1, h2 {{ margin: 0 0 14px; }}
    table {{ width: 100%; border-collapse: collapse; }}
    th, td {{ text-align: left; border-bottom: 1px solid #edf0f5; padding: 12px; vertical-align: top; }}
    input {{ box-sizing: border-box; width: 100%; border: 1px solid #cfd7e6; border-radius: 6px; padding: 10px 12px; font-size: 14px; }}
    button {{ border: 0; border-radius: 6px; background: #2563eb; color: white; padding: 9px 13px; cursor: pointer; }}
    button.danger {{ background: #dc2626; }}
    .actions {{ min-width: 520px; }}
    .actions form {{ display: flex; gap: 8px; margin: 0 0 8px; }}
    .actions input[name=password] {{ width: 180px; }}
    .actions input[name=valid_days] {{ width: 78px; }}
    .actions input[type=datetime-local] {{ width: 190px; }}
    .grid {{ display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }}
    .muted {{ color: #697386; font-size: 13px; }}
    .badge {{ display: inline-block; padding: 4px 8px; border-radius: 999px; font-size: 13px; }}
    .badge.enabled {{ color: #166534; background: #dcfce7; }}
    .badge.disabled {{ color: #7f1d1d; background: #fee2e2; }}
    .badge.expired {{ color: #78350f; background: #fef3c7; }}
    .flash {{ background: #fff7ed; border: 1px solid #fed7aa; color: #9a3412; padding: 12px; border-radius: 6px; margin-bottom: 14px; }}
    @media (max-width: 880px) {{
      .grid {{ grid-template-columns: 1fr; }}
      table, thead, tbody, tr, th, td {{ display: block; }}
      .actions {{ min-width: 0; }}
    }}
  </style>
</head>
<body>
  <header>
    <h1>Hysteria 2 Panel</h1>
    <div>{html.escape(meta['host'])}:{meta['port']} / SNI {html.escape(meta['sni'])}</div>
  </header>
  <main>
    {flash}
    <section>
      <h2>Add User</h2>
      <form class="grid" method="post" action="/users/add">
        <input type="hidden" name="csrf" value="{CSRF_TOKEN}">
        <input name="name" placeholder="username" required>
        <input name="password" placeholder="password, blank = random">
        <input name="valid_days" placeholder="valid days">
        <input type="datetime-local" name="expires_at">
        <button>Add and Restart</button>
      </form>
    </section>
    <section>
      <h2>Users</h2>
      <table>
        <thead><tr><th>User</th><th>Status</th><th>Expires</th><th>Import Link</th><th>Actions</th></tr></thead>
        <tbody>{''.join(rows)}</tbody>
      </table>
    </section>
    <section>
      <h2>Service</h2>
      <form method="post" action="/service/restart">
        <input type="hidden" name="csrf" value="{CSRF_TOKEN}">
        <button>Rewrite Config and Restart Hysteria</button>
      </form>
    </section>
  </main>
</body>
</html>
"""


def main():
    if len(sys.argv) > 1:
        if sys.argv[1] == "--render":
            print(render_config())
            return
        if sys.argv[1] == "--print-uri":
            username = sys.argv[2]
            user = find_user(load_users(), username)
            if not user:
                raise SystemExit("user not found")
            print(build_uri(user))
            return
        if sys.argv[1] == "--expire-users":
            expired = expire_users(restart=True)
            if expired:
                print("expired users: " + ", ".join(expired))
            else:
                print("no expired users")
            return

    if not PANEL_ADMIN_PASS:
        raise SystemExit("PANEL_ADMIN_PASS is required")
    httpd = ThreadingHTTPServer((PANEL_BIND, PANEL_PORT), PanelHandler)
    print(f"Hysteria 2 panel listening on {PANEL_BIND}:{PANEL_PORT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
