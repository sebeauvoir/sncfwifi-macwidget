#!/usr/bin/env python3
import json
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
from urllib.parse import urlparse

HOST = "127.0.0.1"
PORT = 8787

STATE_LOCK = Lock()
STATE = {
    "trainId": "9812",
    "trainNumber": "6201",
    "speed": 285,
    "wifiQuality": 4,
    "devices": 246,
    "consumedData": 12000,
    "remainingData": 28000,
    "nextResetMinutes": 95,
    "barAttendance": 3,
    "delayMins": 0,
    "delayCause": "",
    "stationStatus": "moving",  # moving | station
    "currentStationIndex": 1,
    "minutesToNextStop": 6,
    "minutesToFinalStop": 22,
    "stops": [
        {"id": "paris", "label": "Paris Gare de Lyon"},
        {"id": "lyon", "label": "Lyon Part Dieu"},
        {"id": "marseille", "label": "Marseille St-Charles"},
    ],
    # ── Eurostar / plateforme Icomora (ombord.info) ────────────────────────────
    "esSystemName": "eurostar-blue-main",
    "esOnline": 1,
    "esUsersTotal": 170,
    "esUsersOnline": 119,
    # Volumes en octets, comme l'API réelle.
    "esDataUsed": 16894222,
    "esDataLimit": 1000000000,
    # Débit en octets/s (12 500 000 → 100 Mbit/s).
    "esBandwidth": 12500000,
    "esTechnology": "endc",
    "esRssi": -19,
    "esModems": 3,
    # Vitesse saisie en km/h côté panneau, convertie en m/s à l'émission (comme l'API réelle).
    "esSpeed": 224,
}

# Modems de la rame : opérateurs français (Orange, SFR, Bouygues) tels que vus sur LGV Nord.
EUROSTAR_MODEM_OPERATORS = ["20820", "20801", "20810"]


def iso_in(minutes):
    ts = datetime.now(timezone.utc) + timedelta(minutes=minutes)
    return ts.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def build_stops(state):
    current_idx = max(0, min(int(state.get("currentStationIndex", 1)), len(state["stops"]) - 1))
    next_minutes = max(0, int(state.get("minutesToNextStop", 6)))
    final_minutes = max(next_minutes, int(state.get("minutesToFinalStop", 22)))

    out = []
    for idx, stop in enumerate(state["stops"]):
        if idx < current_idx:
            progress_pct = 100.0
            stop_minutes = -5
        elif idx == current_idx:
            # stop[i].progress décrit le segment PARTANT de i : à l'arrêt en gare, il n'a pas
            # commencé (0 %), sinon il est entamé. C'est ce que lit SNCFDataSource pour situer
            # le train ; à 100 % la détection « en gare » viserait le segment suivant.
            if state.get("stationStatus") == "station":
                progress_pct = 0.0
                stop_minutes = 0
            else:
                progress_pct = 35.0
                stop_minutes = next_minutes
        else:
            # Spread future times between next and final stop.
            segment_count = max(1, len(state["stops"]) - current_idx - 1)
            segment_pos = idx - current_idx
            ratio = segment_pos / segment_count
            stop_minutes = int(next_minutes + (final_minutes - next_minutes) * ratio)
            progress_pct = 0.0

        stop_iso = iso_in(stop_minutes)
        out.append({
            "id": stop["id"],
            "label": stop["label"],
            "theoricDate": stop_iso,
            "realDate": stop_iso,
            "delay": 0,
            "progress": {
                "progressPercentage": progress_pct,
                "traveledDistance": 1000.0 * idx,
                "remainingDistance": 1000.0 * max(0, len(state["stops"]) - idx - 1),
            },
            "coordinates": {
                "latitude": 48.0 - idx,
                "longitude": 2.0 + idx,
            },
        })
    return out


def current_position(state, stops):
    """Position GPS cohérente avec l'état : sur la gare à l'arrêt, entre deux gares sinon.
    Avec une position figée, la détection « en gare » du widget (distance GPS < 1500 m) reste
    muette et la branche correspondante n'est jamais exercée."""
    idx = max(0, min(int(state.get("currentStationIndex", 1)), len(stops) - 1))
    here = stops[idx]["coordinates"]
    if state.get("stationStatus") == "station":
        return here["latitude"], here["longitude"]
    nxt = stops[min(idx + 1, len(stops) - 1)]["coordinates"]
    return (here["latitude"] + nxt["latitude"]) / 2, (here["longitude"] + nxt["longitude"]) / 2


def current_payloads():
    with STATE_LOCK:
        state = dict(STATE)
        stops = build_stops(state)

    # L'API SNCF renvoie la vitesse en m/s ; le panneau la saisit en km/h.
    speed_kmh = int(state.get("speed", 0)) if state.get("stationStatus") != "station" else 0
    latitude, longitude = current_position(state, stops)
    gps = {
        "speed": round(speed_kmh / 3.6, 3),
        "latitude": latitude,
        "longitude": longitude,
    }
    progress = {
        "trainId": str(state.get("trainId", "9812")),
        "number": str(state.get("trainNumber", "6201")),
        "delay": int(state.get("delayMins", 0)),
        "delayReason": state.get("delayCause", ""),
        "disruption": {"cause": state.get("delayCause", "")},
        "stops": stops,
    }
    bar = {
        "attendance": int(state.get("barAttendance", 0)),
    }
    stats = {
        "quality": int(state.get("wifiQuality", 3)),
        "devices": int(state.get("devices", 180)),
    }
    next_reset_minutes = max(0, int(state.get("nextResetMinutes", 95)))
    next_reset_ms = int((datetime.now(timezone.utc) + timedelta(minutes=next_reset_minutes)).timestamp() * 1000)
    status = {
        "consumed_data": max(0, int(state.get("consumedData", 12000))),
        "remaining_data": max(0, int(state.get("remainingData", 28000))),
        "next_reset": next_reset_ms,
    }
    return gps, progress, bar, stats, status


def eurostar_payloads():
    """Payloads de la plateforme Icomera (ombord.info), servis en JSONP.

    Tout est renvoyé en chaînes de caractères, comme l'API réelle — c'est justement ce que le
    code de conversion côté app doit encaisser.
    """
    with STATE_LOCK:
        state = dict(STATE)

    online = "1" if int(state.get("esOnline", 1)) else "0"
    modem_count = max(0, min(int(state.get("esModems", 3)), len(EUROSTAR_MODEM_OPERATORS)))
    best_rssi = int(state.get("esRssi", -19))
    technology = str(state.get("esTechnology", "endc"))

    system = {
        "version": "1.11",
        "system": "40153",
        "system_id": 40153,
        "system_name": str(state.get("esSystemName", "eurostar-blue-main")),
    }

    # Deux liens ethernet toujours présents, puis un modem par opérateur.
    links = [
        {
            "index": str(50 + i),
            "device_type": "ethernet",
            "device_state": "up",
            "link_state": "available",
            "ethernet_info": {"ip": f"192.168.{50 + i}.1", "netmask": "255.255.255.0", "mode": "dhcp"},
        }
        for i in range(2)
    ]
    for i, operator_id in enumerate(EUROSTAR_MODEM_OPERATORS):
        is_active = i < modem_count
        links.append({
            "index": str(101 + i),
            "device_type": "modem",
            "device_subtype": "fn990a40",
            "device_state": "up" if is_active else "down",
            "link_state": "available" if is_active else "disconnected",
            # Le meilleur RSSI est porté par le premier modem, les suivants sont dégradés.
            "rssi": str(best_rssi - 12 * i) if is_active else "-1",
            "technology": technology if is_active else "-1",
            "operator_id": operator_id if is_active else "-1",
            "apninfo": "-1,-1,-1",
            "umts_info": {"net_status": "-1", "lac": "-1", "cellid": f"{i + 1:08X}"},
        })
    # Un quatrième modem hors service, comme sur la rame observée.
    links.append({
        "index": "104",
        "device_type": "modem",
        "device_subtype": "fn990",
        "device_state": "down",
        "link_state": "disconnected",
        "rssi": "-1",
        "technology": "-1",
        "operator_id": "-1",
        "apninfo": "-1,-1,-1",
        "umts_info": {"net_status": "-1", "lac": "-1", "cellid": "-1"},
    })

    connectivity = {
        "version": "1.11",
        "online": online,
        "bundleid": "40153",
        "bundleip": "10.1.106.1",
        "links": links,
    }

    users = {
        "version": "1.11",
        "total": str(max(0, int(state.get("esUsersTotal", 170)))),
        "online": str(max(0, int(state.get("esUsersOnline", 119)))),
    }

    used = max(0, int(state.get("esDataUsed", 16894222)))
    limit = max(0, int(state.get("esDataLimit", 1000000000)))
    download = int(used * 0.87)
    user = {
        "version": "1.11",
        "ip": "192.168.9.92",
        "mac": "",
        "online": "",
        "timeleft": "",
        "authenticated": "1",
        "userclass": "2",
        "expires": "Never",
        "timeused": "260",
        "data_download_used": str(download),
        "data_upload_used": str(used - download),
        "data_total_used": str(used),
        "data_download_limit": "",
        "data_upload_limit": "",
        "data_total_limit": str(limit) if limit else "",
        "bandwidth_download_limit": str(max(0, int(state.get("esBandwidth", 12500000)))),
        "bandwidth_upload_limit": str(max(0, int(state.get("esBandwidth", 12500000)))),
        "cap_level": "0",
        "user_custom_state": "",
    }

    # `speed` est en m/s côté ombord ; le panneau la saisit en km/h.
    speed_ms = max(0, int(state.get("esSpeed", 224))) / 3.6
    position = {
        "version": "1.11",
        "time": str(int(datetime.now(timezone.utc).timestamp())),
        "age": "1",
        "latitude": "49.049033",
        "longitude": "2.545448",
        "altitude": "109.306",
        "speed": f"{speed_ms:.3f}",
        "cmg": "56.0765",
        "satellites": "48",
        "mode": "3",
    }

    return system, connectivity, users, user, position


HTML = """<!doctype html>
<html lang=\"fr\">
<head>
  <meta charset=\"utf-8\" />
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
  <title>SNCF Demo Server</title>
  <style>
    body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; margin: 24px; background: #f5f5f2; color: #1a1a1a; }
    .card { background: #fff; border: 1px solid #dcdad3; border-radius: 10px; padding: 16px; max-width: 760px; }
    h1 { margin-top: 0; }
    .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
    label { display: block; font-size: 12px; margin-bottom: 4px; color: #444; }
    input, select { width: 100%; padding: 8px; border: 1px solid #c8c5bc; border-radius: 6px; box-sizing: border-box; }
    button { margin-top: 14px; padding: 10px 12px; border: 0; border-radius: 6px; background: #0f766e; color: white; cursor: pointer; }
    code { background: #eceae3; padding: 2px 4px; border-radius: 4px; }
    h2 { font-size: 15px; margin: 24px 0 10px; padding-top: 16px; border-top: 1px solid #dcdad3; }
  </style>
</head>
<body>
  <div class=\"card\">
    <h1>Train WiFi Demo Server</h1>
    <p>API SNCF: <code>http://127.0.0.1:8787/router/api/...</code></p>
    <p>API Eurostar (JSONP): <code>http://127.0.0.1:8787/api/jsonp/...</code></p>
    <p>Les deux plateformes sont servies en permanence : c'est le réglage
       <em>Debug &gt; Opérateur simulé</em> de l'app qui décide laquelle est interrogée.</p>

    <h2>TGV INOUI (wifi.sncf)</h2>
    <div class=\"grid\">
      <div><label>Train ID (rame)</label><input id="trainId" /></div>
      <div><label>Numéro train</label><input id="trainNumber" /></div>
      <div><label>Statut</label><select id=\"stationStatus\"><option value=\"moving\">En mouvement</option><option value=\"station\">En gare</option></select></div>
      <div><label>Vitesse (km/h)</label><input id=\"speed\" type=\"number\" min=\"0\" max=\"360\" /></div>
      <div><label>Index gare courante (0..2)</label><input id=\"currentStationIndex\" type=\"number\" min=\"0\" max=\"2\" /></div>
      <div><label>Minutes prochaine gare</label><input id=\"minutesToNextStop\" type=\"number\" min=\"0\" max=\"120\" /></div>
      <div><label>Minutes gare finale</label><input id=\"minutesToFinalStop\" type=\"number\" min=\"0\" max=\"240\" /></div>
            <div><label>Qualite WiFi (1..5)</label><input id=\"wifiQuality\" type=\"number\" min=\"1\" max=\"5\" /></div>
            <div><label>Appareils connectes</label><input id=\"devices\" type=\"number\" min=\"0\" /></div>
            <div><label>Data consommee</label><input id=\"consumedData\" type=\"number\" min=\"0\" /></div>
            <div><label>Data restante</label><input id=\"remainingData\" type=\"number\" min=\"0\" /></div>
            <div><label>Reset dans (minutes)</label><input id=\"nextResetMinutes\" type=\"number\" min=\"0\" max=\"1440\" /></div>
      <div><label>File Bar (personnes, 0 = pas d'attente)</label><input id="barAttendance" type="number" min="0" /></div>
      <div><label>Retard (min)</label><input id="delayMins" type="number" min="0" /></div>
      <div><label>Cause du retard</label><input id="delayCause" /></div>
    </div>

    <h2>Eurostar (ombord.info)</h2>
    <div class=\"grid\">
      <div><label>Nom de la rame</label><input id=\"esSystemName\" /></div>
      <div><label>Liaison sol</label><select id=\"esOnline\"><option value=\"1\">En ligne</option><option value=\"0\">Interrompue</option></select></div>
      <div><label>Vitesse (km/h)</label><input id=\"esSpeed\" type=\"number\" min=\"0\" max=\"360\" /></div>
      <div><label>Technologie</label><select id=\"esTechnology\"><option value=\"endc\">endc (5G NSA)</option><option value=\"nr\">nr (5G)</option><option value=\"lte\">lte (4G)</option><option value=\"umts\">umts (3G)</option><option value=\"gsm\">gsm (2G)</option></select></div>
      <div><label>Meilleur RSSI (dBm, négatif)</label><input id=\"esRssi\" type=\"number\" min=\"-120\" max=\"-1\" /></div>
      <div><label>Modems actifs (0..3)</label><input id=\"esModems\" type=\"number\" min=\"0\" max=\"3\" /></div>
      <div><label>Utilisateurs en ligne</label><input id=\"esUsersOnline\" type=\"number\" min=\"0\" /></div>
      <div><label>Utilisateurs total</label><input id=\"esUsersTotal\" type=\"number\" min=\"0\" /></div>
      <div><label>Data consommée (octets)</label><input id=\"esDataUsed\" type=\"number\" min=\"0\" /></div>
      <div><label>Quota data (octets, 0 = illimité)</label><input id=\"esDataLimit\" type=\"number\" min=\"0\" /></div>
      <div><label>Débit max (octets/s)</label><input id=\"esBandwidth\" type=\"number\" min=\"0\" /></div>
    </div>

    <button onclick=\"save()\">Appliquer</button>
    <p id=\"status\"></p>
  </div>
  <script>
    async function load() {
      const res = await fetch('/api/state');
      const s = await res.json();
      Object.keys(s).forEach((k) => {
        const el = document.getElementById(k);
        if (!el) return;
        el.value = String(s[k]);
      });
    }
    async function save() {
      const payload = {
        trainId: document.getElementById('trainId').value,
        trainNumber: document.getElementById('trainNumber').value,
        stationStatus: document.getElementById('stationStatus').value,
        speed: Number(document.getElementById('speed').value),
        currentStationIndex: Number(document.getElementById('currentStationIndex').value),
        minutesToNextStop: Number(document.getElementById('minutesToNextStop').value),
        minutesToFinalStop: Number(document.getElementById('minutesToFinalStop').value),
        wifiQuality: Number(document.getElementById('wifiQuality').value),
        devices: Number(document.getElementById('devices').value),
        consumedData: Number(document.getElementById('consumedData').value),
        remainingData: Number(document.getElementById('remainingData').value),
        nextResetMinutes: Number(document.getElementById('nextResetMinutes').value),
        barAttendance: Number(document.getElementById('barAttendance').value),
        delayMins: Number(document.getElementById('delayMins').value),
        delayCause: document.getElementById('delayCause').value,
        esSystemName: document.getElementById('esSystemName').value,
        esOnline: Number(document.getElementById('esOnline').value),
        esSpeed: Number(document.getElementById('esSpeed').value),
        esTechnology: document.getElementById('esTechnology').value,
        esRssi: Number(document.getElementById('esRssi').value),
        esModems: Number(document.getElementById('esModems').value),
        esUsersOnline: Number(document.getElementById('esUsersOnline').value),
        esUsersTotal: Number(document.getElementById('esUsersTotal').value),
        esDataUsed: Number(document.getElementById('esDataUsed').value),
        esDataLimit: Number(document.getElementById('esDataLimit').value),
        esBandwidth: Number(document.getElementById('esBandwidth').value),
      };
      const res = await fetch('/api/state', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(payload) });
      document.getElementById('status').textContent = res.ok ? 'Etat mis a jour.' : 'Erreur de mise a jour.';
    }
    load();
  </script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def _json(self, status_code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _jsonp(self, payload):
        """Réponse au format de la plateforme Icomera : l'objet JSON enveloppé dans `( … );`."""
        body = f"({json.dumps(payload, indent=4)});".encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/javascript; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, payload):
        body = payload.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/":
            self._html(HTML)
            return
        if path == "/api/state":
            with STATE_LOCK:
                self._json(200, STATE)
            return

        # ── Plateforme Icomera / Eurostar (JSONP) ──────────────────────────────
        if path.startswith("/api/jsonp/"):
            system, connectivity, users, user, position = eurostar_payloads()
            endpoint = path[len("/api/jsonp/"):].strip("/")
            payloads = {
                "system": system,
                "connectivity": connectivity,
                "users": users,
                "user": user,
                "position": position,
            }
            if endpoint in payloads:
                self._jsonp(payloads[endpoint])
                return
            self._json(404, {"error": "not_found"})
            return

        # ── API SNCF (JSON nu) ────────────────────────────────────────────────
        gps, progress, bar, stats, status = current_payloads()

        if path == "/router/api/train/gps":
            self._json(200, gps)
            return
        if path in ("/router/api/train/progress", "/router/api/train/details"):
            self._json(200, progress)
            return
        if path == "/router/api/bar/attendance":
            self._json(200, bar)
            return
        if path == "/router/api/connection/statistics":
            self._json(200, stats)
            return
        if path == "/router/api/connection/status":
            self._json(200, status)
            return

        self._json(404, {"error": "not_found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/api/state":
            self._json(404, {"error": "not_found"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8")) if raw else {}
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid_json"})
            return

        with STATE_LOCK:
            for key in (
                "trainId", "trainNumber", "speed", "wifiQuality", "devices", "consumedData", "remainingData",
                "nextResetMinutes", "barAttendance", "barQueueEmpty", "delayMins", "delayCause",
                "stationStatus", "currentStationIndex", "minutesToNextStop", "minutesToFinalStop",
                "esSystemName", "esOnline", "esUsersTotal", "esUsersOnline", "esDataUsed", "esDataLimit",
                "esBandwidth", "esTechnology", "esRssi", "esModems", "esSpeed",
            ):
                if key in payload:
                    STATE[key] = payload[key]

            if STATE.get("stationStatus") not in ("moving", "station"):
                STATE["stationStatus"] = "moving"

        self._json(200, {"ok": True})


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Demo server listening on http://{HOST}:{PORT}")
    server.serve_forever()
