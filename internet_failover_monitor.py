#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TSC Internet Failover Monitor
System tray icon + Web dashboard for monitoring internet failover status.

Reads state from internet_failover_state.json (written by internet_failover.ps1)
and provides a web dashboard at http://localhost:8766

Usage:
    python internet_failover_monitor.py              # run monitor
    python internet_failover_monitor.py --install    # install as scheduled task
    python internet_failover_monitor.py --uninstall  # remove scheduled task
"""

import os
import sys
import json
import time
import threading
import subprocess
import webbrowser
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from datetime import datetime
from pathlib import Path
from io import BytesIO

try:
    import pystray
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Dependencias faltando. Instale com:")
    print("  pip install pystray Pillow")
    sys.exit(1)

# ============================================================================
# CONFIGURAÇÃO
# ============================================================================

SCRIPT_DIR = Path(__file__).parent.resolve()
STATE_FILE = SCRIPT_DIR / "internet_failover_state.json"
LOG_FILE = SCRIPT_DIR / "internet_failover.log"
FAILOVER_SCRIPT = SCRIPT_DIR / "internet_failover.ps1"
DASHBOARD_FILE = SCRIPT_DIR / "internet_failover_dashboard.html"
HTTP_PORT = 8766
POLL_INTERVAL = 5  # seconds
STATE_STALE_SECONDS = 60  # if state file older than this, probe live
TASK_NAME = "TSC-FailoverMonitor"

# Network config (mirrors the PS1 script)
CABLE_ALIAS = "Ethernet 2"
CABLE_GW = "192.168.0.1"
MODEM_DESC_PATTERN = "Remote NDIS"
TEST_HOSTS = ["8.8.8.8", "1.1.1.1"]

ESSENTIAL_CONTAINERS = [
    "tsc_checklist_frontend", "tsc_checklist_backend", "tsc_checklist_postgres",
    "tsc-api", "tsc-celery", "tsc-celery-beat", "tsc-websocket",
    "tsc-redis", "tsc-postgres-central", "027b44a9e45f_tsc-keycloak", "oea_whatsapp",
]
HEAVY_CONTAINERS = [
    "8a7d3bea5f04_wazuh-indexer", "wazuh-dashboard", "wazuh-manager", "wazuh-scheduler",
    "postfix-relay", "oea_web_server", "oea_python_worker", "oea_traccar",
    "oea_n8n", "oea_watchtower", "oea_router", "oea_redis",
    "tsc_checklist_pgadmin", "tsc-pgadmin",
]

# WhatsApp config
WHATSAPP_URL = "http://localhost:3030"
WHATSAPP_ALERT_PHONE = "5516982108990"

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

_current_state = {
    "mode": "unknown",
    "internet": False,
    "cableStatus": "Unknown",
    "modemStatus": "Down",
    "modemAlias": "N/A",
    "cableAlias": "Ethernet 2",
    "essentialUp": 0, "essentialTotal": 0,
    "heavyUp": 0, "heavyTotal": 0,
    "failCount": 0, "recoverCount": 0,
    "lastUpdate": None, "modeChangedAt": None,
    "cableGateway": False,
}
_state_lock = threading.Lock()
_last_mode = "unknown"


def _run_cmd(args, timeout=5):
    """Run a subprocess and return stdout, or empty string on error."""
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                           creationflags=subprocess.CREATE_NO_WINDOW)
        return r.stdout.strip()
    except Exception:
        return ""


def _ping_ok(host, count=2, timeout_ms=2000):
    """Test if a host responds to ping."""
    out = _run_cmd(["ping", "-n", str(count), "-w", str(timeout_ms), host])
    return "bytes=" in out.lower() or "TTL=" in out


def probe_live_state():
    """Gather live system state when PS1 state file is unavailable."""
    # Cable adapter status
    cable_status = "Down"
    cable_gw = False
    ps_adapters = _run_cmd([
        "powershell.exe", "-NoProfile", "-Command",
        "Get-NetAdapter | Select-Object Name, Status, InterfaceDescription | ConvertTo-Json -Compress"
    ], timeout=10)
    adapters = []
    try:
        parsed = json.loads(ps_adapters)
        adapters = parsed if isinstance(parsed, list) else [parsed]
    except (json.JSONDecodeError, TypeError):
        pass

    for a in adapters:
        if a.get("Name") == CABLE_ALIAS:
            cable_status = a.get("Status", "Down")

    # Modem status
    modem_status = "Down"
    modem_alias = "N/A"
    for a in adapters:
        desc = a.get("InterfaceDescription", "")
        if MODEM_DESC_PATTERN.lower() in desc.lower():
            modem_alias = a.get("Name", "N/A")
            modem_status = a.get("Status", "Down")
            break

    # Gateway ping
    if cable_status == "Up":
        cable_gw = _ping_ok(CABLE_GW)

    # Internet test
    internet_ok = False
    for host in TEST_HOSTS:
        if _ping_ok(host):
            internet_ok = True
            break

    # Determine mode
    if cable_status == "Up" and cable_gw and internet_ok:
        mode = "cable"
    elif modem_status == "Up" and internet_ok:
        mode = "4g"
    elif cable_status == "Up" and cable_gw:
        mode = "cable"
    elif internet_ok:
        mode = "cable"
    else:
        mode = "unknown"

    # Docker containers
    ess_up = 0
    heavy_up = 0
    docker_out = _run_cmd(["docker", "ps", "--format", "{{.Names}}"], timeout=10)
    running = [n.strip() for n in docker_out.split("\n") if n.strip()] if docker_out else []
    for c in ESSENTIAL_CONTAINERS:
        if c in running:
            ess_up += 1
    for c in HEAVY_CONTAINERS:
        if c in running:
            heavy_up += 1

    return {
        "mode": mode,
        "internet": internet_ok,
        "cableStatus": cable_status,
        "cableGateway": cable_gw,
        "cableAlias": CABLE_ALIAS,
        "modemStatus": modem_status,
        "modemAlias": modem_alias,
        "essentialUp": ess_up,
        "essentialTotal": len(ESSENTIAL_CONTAINERS),
        "heavyUp": heavy_up,
        "heavyTotal": len(HEAVY_CONTAINERS),
        "failCount": 0,
        "recoverCount": 0,
        "lastUpdate": datetime.now().isoformat(),
        "modeChangedAt": None,
        "source": "live_probe",
    }


def _state_file_is_fresh():
    """Check if the state file exists and was written recently."""
    try:
        if STATE_FILE.exists():
            age = time.time() - STATE_FILE.stat().st_mtime
            return age < STATE_STALE_SECONDS
    except OSError:
        pass
    return False


def read_state():
    """Read state from JSON file or probe live system."""
    global _current_state, _last_mode
    try:
        if _state_file_is_fresh():
            data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            data["source"] = "ps1_script"
        else:
            data = probe_live_state()

        with _state_lock:
            _current_state.update(data)
            new_mode = data.get("mode", "unknown")
            old_mode = _last_mode
            _last_mode = new_mode
            return old_mode, new_mode
    except (json.JSONDecodeError, PermissionError):
        pass
    return _last_mode, _last_mode


def get_state():
    with _state_lock:
        return dict(_current_state)


# ============================================================================
# TRAY ICON
# ============================================================================

def create_icon_image(mode):
    """Create a 64x64 icon with color based on mode."""
    colors = {
        "cable": "#10b981",   # green
        "4g": "#f59e0b",      # yellow/amber
        "unknown": "#ef4444", # red
    }
    color = colors.get(mode, "#ef4444")

    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Circle background
    draw.ellipse([4, 4, 60, 60], fill=color)

    # Draw text
    label = {"cable": "C", "4g": "4G"}.get(mode, "?")
    try:
        font = ImageFont.truetype("arial.ttf", 24 if len(label) == 1 else 18)
    except OSError:
        font = ImageFont.load_default()

    bbox = draw.textbbox((0, 0), label, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text(((64 - tw) / 2, (64 - th) / 2 - 2), label, fill="white", font=font)

    return img


def get_tooltip(state):
    mode_labels = {"cable": "Cabo (normal)", "4g": "4G Ativo", "unknown": "Desconhecido"}
    mode_label = mode_labels.get(state.get("mode", "unknown"), "Desconhecido")
    inet = "OK" if state.get("internet") else "SEM INTERNET"
    ess = f"{state.get('essentialUp', 0)}/{state.get('essentialTotal', 0)}"
    return f"Internet: {mode_label} | {inet} | Containers: {ess}"


class TrayApp:
    def __init__(self):
        self.icon = None
        self._stop_event = threading.Event()

    def _on_force4g(self, icon, item):
        threading.Thread(target=self._run_ps, args=("-Force4G",), daemon=True).start()

    def _on_forcecable(self, icon, item):
        threading.Thread(target=self._run_ps, args=("-ForceCable",), daemon=True).start()

    def _on_dashboard(self, icon, item):
        webbrowser.open(f"http://localhost:{HTTP_PORT}")

    def _on_exit(self, icon, item):
        self._stop_event.set()
        icon.stop()

    def _run_ps(self, switch):
        try:
            subprocess.run(
                ["powershell.exe", "-ExecutionPolicy", "Bypass", "-File",
                 str(FAILOVER_SCRIPT), switch],
                capture_output=True, timeout=120
            )
        except Exception as e:
            print(f"Erro executando PS1 {switch}: {e}")

    def _get_menu(self):
        state = get_state()
        mode = state.get("mode", "unknown")
        mode_labels = {"cable": "Cabo (normal)", "4g": "4G Ativo", "unknown": "Desconhecido"}
        inet = "OK" if state.get("internet") else "SEM INTERNET"

        return pystray.Menu(
            pystray.MenuItem(f"Modo: {mode_labels.get(mode, mode)}", None, enabled=False),
            pystray.MenuItem(f"Internet: {inet}", None, enabled=False),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Forçar 4G", self._on_force4g),
            pystray.MenuItem("Forçar Cabo", self._on_forcecable),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Abrir Dashboard", self._on_dashboard),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Sair", self._on_exit),
        )

    def run(self):
        state = get_state()
        try:
            self.icon = pystray.Icon(
                "TSC-Failover",
                icon=create_icon_image(state.get("mode", "unknown")),
                title=get_tooltip(state),
                menu=self._get_menu(),
            )
            self.icon.run_detached()
            return True
        except Exception as e:
            print(f"[WARN] Tray icon nao disponivel: {e}")
            self.icon = None
            return False

    def update(self, mode):
        if self.icon:
            try:
                self.icon.icon = create_icon_image(mode)
                self.icon.title = get_tooltip(get_state())
                self.icon.menu = self._get_menu()
            except Exception:
                pass

    def stop(self):
        self._stop_event.set()
        if self.icon:
            self.icon.stop()

    @property
    def stopped(self):
        return self._stop_event.is_set()


# ============================================================================
# WINDOWS TOAST NOTIFICATION
# ============================================================================

def send_toast(title, body):
    """Send Windows toast notification via PowerShell."""
    ps_code = f'''
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>{title}</text><text>{body}</text></binding></visual></toast>')
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("TSC-InternetFailover").Show($toast)
    '''
    try:
        subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command", ps_code],
            capture_output=True, timeout=10
        )
    except Exception:
        pass


def send_whatsapp(message):
    """Send WhatsApp alert via oea_whatsapp container API."""
    try:
        import urllib.request
        data = json.dumps({"phone": WHATSAPP_ALERT_PHONE, "message": message}).encode("utf-8")
        req = urllib.request.Request(
            f"{WHATSAPP_URL}/send",
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
        print(f"[OK] WhatsApp enviado para {WHATSAPP_ALERT_PHONE}")
    except Exception as e:
        print(f"[WARN] WhatsApp falhou: {e}")


# ============================================================================
# HTTP API SERVER
# ============================================================================

class DashboardHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        pass  # suppress HTTP logs

    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json_response(self, data, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(json.dumps(data, default=str).encode("utf-8"))

    def _html_response(self, html):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(html.encode("utf-8"))

    def do_OPTIONS(self):
        self.send_response(200)
        self._cors_headers()
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/":
            if DASHBOARD_FILE.exists():
                self._html_response(DASHBOARD_FILE.read_text(encoding="utf-8"))
            else:
                self._html_response("<h1>Dashboard not found</h1>")

        elif path == "/api/status":
            state = get_state()
            state["serverTime"] = datetime.now().isoformat()
            self._json_response(state)

        elif path == "/api/logs":
            lines = []
            try:
                if LOG_FILE.exists():
                    text = LOG_FILE.read_text(encoding="utf-8", errors="replace")
                    lines = text.strip().split("\n")[-100:]
            except PermissionError:
                lines = ["[Erro lendo log - arquivo em uso]"]
            self._json_response({"lines": lines})

        elif path == "/api/containers":
            try:
                result = subprocess.run(
                    ["docker", "ps", "-a", "--format", "{{.Names}}|{{.Status}}|{{.Image}}"],
                    capture_output=True, text=True, timeout=10
                )
                containers = []
                for line in result.stdout.strip().split("\n"):
                    if "|" in line:
                        parts = line.split("|", 2)
                        containers.append({
                            "name": parts[0],
                            "status": parts[1] if len(parts) > 1 else "",
                            "image": parts[2] if len(parts) > 2 else "",
                        })
                self._json_response({"containers": containers})
            except Exception as e:
                self._json_response({"containers": [], "error": str(e)})

        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        path = urlparse(self.path).path

        if path == "/api/force4g":
            threading.Thread(target=self._run_failover, args=("-Force4G",), daemon=True).start()
            self._json_response({"success": True, "message": "Forçando 4G..."})

        elif path == "/api/forcecable":
            threading.Thread(target=self._run_failover, args=("-ForceCable",), daemon=True).start()
            self._json_response({"success": True, "message": "Restaurando cabo..."})

        else:
            self.send_response(404)
            self.end_headers()

    @staticmethod
    def _run_failover(switch):
        """Run failover script with admin elevation (UAC prompt)."""
        try:
            # Use Start-Process -Verb RunAs for admin elevation
            ps_cmd = (
                f'Start-Process powershell.exe '
                f'-ArgumentList "-ExecutionPolicy Bypass -File \"{FAILOVER_SCRIPT}\" {switch}" '
                f'-Verb RunAs -Wait'
            )
            subprocess.run(
                ["powershell.exe", "-NoProfile", "-Command", ps_cmd],
                capture_output=True, timeout=120
            )
        except Exception as e:
            print(f"Erro executando failover {switch}: {e}")


def start_http_server():
    server = HTTPServer(("127.0.0.1", HTTP_PORT), DashboardHandler)
    server.serve_forever()


# ============================================================================
# MONITOR THREAD
# ============================================================================

def monitor_loop(tray):
    """Main monitoring loop - reads state and updates tray icon."""
    while True:
        old_mode, new_mode = read_state()

        # Mode changed - send notifications (toast + WhatsApp)
        if old_mode != new_mode and old_mode != "unknown":
            ts = datetime.now().strftime("%H:%M:%S %d/%m")
            if new_mode == "4g":
                send_toast(
                    "Internet: Cabo CAIU",
                    "Trafego mudou para 4G. Containers pesados parados."
                )
                send_whatsapp(
                    f"[ALERTA] *INTERNET - CABO CAIU* ({ts})\n\n"
                    f"Trafego no 4G. Containers pesados parados."
                )
            elif new_mode == "cable":
                send_toast(
                    "Internet: Cabo VOLTOU",
                    "Trafego restaurado para cabo. Containers reiniciados."
                )
                send_whatsapp(
                    f"[OK] *INTERNET - CABO VOLTOU* ({ts})\n\n"
                    f"Trafego no cabo. Containers restaurados."
                )
            elif new_mode == "unknown":
                send_toast(
                    "SEM INTERNET",
                    "Sem internet no cabo e no 4G."
                )
                send_whatsapp(
                    f"[CRITICO] *SEM INTERNET* ({ts})\n\n"
                    f"Sem internet no cabo e no 4G."
                )

        tray.update(new_mode)
        time.sleep(POLL_INTERVAL)


# ============================================================================
# INSTALL / UNINSTALL
# ============================================================================

def install_task():
    python_exe = sys.executable
    script_path = str(Path(__file__).resolve())
    ps_cmd = f'''
    $action = New-ScheduledTaskAction -Execute '"{python_exe}"' -Argument '"{script_path}"'
    $trigger = New-ScheduledTaskTrigger -AtLogon
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable $true
    Register-ScheduledTask -TaskName "{TASK_NAME}" -Action $action -Trigger $trigger -Settings $settings -Description "Monitor de failover com tray icon e dashboard" -Force | Out-Null
    Start-ScheduledTask -TaskName "{TASK_NAME}"
    Write-Host "Tarefa '{TASK_NAME}' instalada e iniciada."
    '''
    subprocess.run(["powershell.exe", "-ExecutionPolicy", "Bypass", "-Command", ps_cmd])


def uninstall_task():
    ps_cmd = f'''
    Stop-ScheduledTask -TaskName "{TASK_NAME}" -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "{TASK_NAME}" -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Tarefa '{TASK_NAME}' removida."
    '''
    subprocess.run(["powershell.exe", "-ExecutionPolicy", "Bypass", "-Command", ps_cmd])


# ============================================================================
# MAIN
# ============================================================================

def main():
    if "--install" in sys.argv:
        install_task()
        return
    if "--uninstall" in sys.argv:
        uninstall_task()
        return

    print(f"TSC Internet Failover Monitor")
    print(f"Dashboard: http://localhost:{HTTP_PORT}")
    print(f"State file: {STATE_FILE}")
    print()

    # Start HTTP server
    http_thread = threading.Thread(target=start_http_server, daemon=True)
    http_thread.start()
    print(f"[OK] HTTP server em http://localhost:{HTTP_PORT}")

    # Read initial state
    read_state()

    # Start tray icon (optional — may fail in non-interactive sessions)
    tray = TrayApp()
    if tray.run():
        print("[OK] Tray icon ativo")
    else:
        print("[OK] Rodando sem tray icon (modo headless)")

    # Start monitor loop
    try:
        monitor_loop(tray)
    except KeyboardInterrupt:
        pass
    finally:
        tray.stop()
        print("Monitor encerrado.")


if __name__ == "__main__":
    main()
