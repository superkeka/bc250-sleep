# SPDX-License-Identifier: GPL-2.0-only
# The backend of the BC-250 Sleep plugin: installs the bc250-sleep package that ships inside the plugin
# (package/), hands its settings to the panel, and updates the plugin from GitHub releases. Decky runs it as
# root ("flags": ["root"]).
import asyncio
import json
import os
import shutil
import ssl
import subprocess
import tempfile
import urllib.error
import urllib.request
import zipfile

import decky

REPO = "superkeka/bc250-sleep"
PACKAGE = os.path.join(decky.DECKY_PLUGIN_DIR, "package")
DIR = "/etc/bc250-sleep"
TOOL = os.path.join(DIR, "bc250-sleep")
UPDATE = os.path.join(DIR, "bc250-update")
# The uninstall leaves the folder (with the config) behind: installed means the boot check is in place.
UNIT = "/etc/systemd/system/bc250-sleep-boot.service"
LOG = "/var/lib/bc250-sleep/sleep.log"
SLEEPS = ("hibernate", "s3")
SHUTDOWNS = ("default", "wake")


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def _env():
    # Decky is a PyInstaller bundle: its LD_LIBRARY_PATH points at its own copies of libzstd, libz and others,
    # which break the system's tools (zstd: "undefined symbol: POOL_free"). The tools get the system's own.
    env = dict(os.environ)
    orig = env.pop("LD_LIBRARY_PATH_ORIG", None)
    if orig:
        env["LD_LIBRARY_PATH"] = orig
    else:
        env.pop("LD_LIBRARY_PATH", None)
    return env


def _run(*cmd, timeout=600):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=_env())
    except (OSError, subprocess.TimeoutExpired) as e:
        decky.logger.error("%s: %s", " ".join(cmd), e)
        return 1, str(e)
    out = (p.stdout + p.stderr).strip()
    decky.logger.info("%s -> %d %s", " ".join(cmd), p.returncode, out[-800:])
    return p.returncode, out


def _ssl_context():
    # Decky's bundled Python has no CA certificates of its own: the system's bundle.
    for ca in ("/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/cert.pem"):
        if os.path.exists(ca):
            return ssl.create_default_context(cafile=ca)
    return ssl.create_default_context()


def _get(url, path=None):
    req = urllib.request.Request(url, headers={"User-Agent": "bc250-sleep-Decky"})
    with urllib.request.urlopen(req, timeout=60, context=_ssl_context()) as r:
        if path is None:
            return r.read()
        with open(path, "wb") as f:
            shutil.copyfileobj(r, f)
    return None


def _cpus():
    """Threads the board has, online or not ("0-15": 16, the 8-core unlock; the firmware starts 12)."""
    n = 0
    for part in _read("/sys/devices/system/cpu/present").split(","):
        a, _, b = part.partition("-")
        if a.isdigit():
            n += int(b or a) - int(a) + 1
    return n


def _status():
    """bc250-sleep status, one "key: value" per line."""
    code, out = _run(TOOL, "status", timeout=30)
    lines = {}
    if code == 0:
        for line in out.splitlines():
            key, sep, value = line.partition(": ")
            if sep:
                lines[key.strip()] = value.strip()
    return lines


class Plugin:
    async def _main(self):
        decky.logger.info("BC-250 Sleep plugin %s", decky.DECKY_PLUGIN_VERSION)

    async def _unload(self):
        pass

    async def get_state(self):
        board = _read("/sys/class/dmi/id/board_name") == "AMD BC-250"
        installed = os.access(TOOL, os.X_OK) and os.path.exists(UNIT)
        state = {
            "board": board,
            "bios": _read("/sys/class/dmi/id/bios_version"),
            # With the 8-core unlock S3 brings back only the six cores the firmware starts.
            "unlocked": _cpus() > 12,
            "installed": installed,
            "version": _read(os.path.join(DIR, "VERSION")) if installed else "",
            "bundled": _read(os.path.join(PACKAGE, "VERSION")),
            "sleep": "",
            "shutdown": "",
            "hibernation": "",
            "s3": "",
            "modules": "",
            "log": "",
        }
        if installed:
            st = _status()
            state["sleep"] = st.get("the Sleep button", "")
            state["shutdown"] = st.get("power-off", "")
            state["hibernation"] = st.get("hibernation", "")
            state["s3"] = st.get("S3 sleep", "")
            state["modules"] = st.get("modules", "")
            state["log"] = "\n".join(_read(LOG).splitlines()[-6:])
        return state

    # The plugin carries the package, so a release's tag is v<VERSION> of both.
    async def latest_release(self):
        def fetch():
            rel = json.loads(_get(f"https://api.github.com/repos/{REPO}/releases/latest"))
            assets = {a["name"]: a["browser_download_url"] for a in rel.get("assets", [])}
            plugin = next((u for n, u in assets.items() if n.endswith("-Decky.zip")), "")
            return {"tag": rel.get("tag_name", ""), "version": rel.get("tag_name", "").lstrip("v"), "plugin_url": plugin}
        try:
            rel = await asyncio.to_thread(fetch)
        except urllib.error.HTTPError as e:
            if e.code == 404:  # no release out yet
                return {"tag": "", "version": ""}
            decky.logger.error("latest release: %s", e)
            return {"tag": "", "version": "", "error": str(e)}
        except Exception as e:
            decky.logger.error("latest release: %s", e)
            return {"tag": "", "version": "", "error": str(e)}
        return rel

    async def install_plugin(self, url, tag):
        def work():
            with tempfile.TemporaryDirectory() as tmp:
                z = os.path.join(tmp, "plugin.zip")
                _get(url, z)
                with zipfile.ZipFile(z) as f:
                    f.extractall(tmp)
                src = next(os.path.join(tmp, d) for d in os.listdir(tmp)
                           if os.path.exists(os.path.join(tmp, d, "plugin.json")))
                dst = decky.DECKY_PLUGIN_DIR
                old = dst + ".old"
                shutil.rmtree(old, ignore_errors=True)
                shutil.copytree(src, dst + ".new")
                os.rename(dst, old)
                os.rename(dst + ".new", dst)
                shutil.rmtree(old, ignore_errors=True)
            # Decky loads the new version on its restart; this process goes with it.
            subprocess.Popen(["sh", "-c", "sleep 2; systemctl restart plugin_loader"], start_new_session=True, env=_env())
            return {"ok": True}
        try:
            return await asyncio.to_thread(work)
        except Exception as e:
            decky.logger.exception("plugin update")
            return {"ok": False, "log": str(e)}

    async def set_sleep(self, mode):
        if mode not in SLEEPS:
            return {"ok": False, "log": "unknown sleep %r" % mode}
        code, out = await asyncio.to_thread(_run, TOOL, "mode", mode, timeout=30)
        return {"ok": code == 0, "log": out}

    async def set_shutdown(self, mode):
        if mode not in SHUTDOWNS:
            return {"ok": False, "log": "unknown power-off %r" % mode}
        code, out = await asyncio.to_thread(_run, TOOL, "shutdown", mode, timeout=60)
        return {"ok": code == 0, "log": out}

    async def install(self):
        script = os.path.join(PACKAGE, "install.sh")
        code, out = await asyncio.to_thread(_run, "bash", script, timeout=900)
        return {"ok": code == 0, "log": out[-1500:]}

    async def rebuild(self):
        """After a system update: the compiler and the kernel's build files, the modules for the running kernel."""
        code, out = await asyncio.to_thread(_run, UPDATE, timeout=900)
        return {"ok": code == 0, "log": out[-1500:]}

    async def uninstall(self):
        script = os.path.join(PACKAGE, "install.sh")
        code, out = await asyncio.to_thread(_run, "bash", script, "--uninstall", timeout=300)
        return {"ok": code == 0, "log": out[-1500:]}

    async def reboot(self):
        await asyncio.to_thread(_run, "systemctl", "reboot", timeout=30)
