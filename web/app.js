/*
 * SNCF Wifi — version web du widget.
 *
 * Un seul fichier, sans dépendance, qui tourne de deux façons :
 *  - dans `index.html` (GitHub Pages, ou le serveur démo) : rendu dans `#sncfwifi-app` ;
 *  - lancé par le favori sur la page du portail du train (wifi.sncf…) : rendu en surimpression.
 *    C'est le cas utile à bord : le serveur du train n'envoie pas d'en-têtes CORS, seule une page
 *    de même origine peut lire son API.
 *
 * Mêmes réseaux et même logique que l'app macOS (Sources/*DataSource.swift) : vitesse relue
 * chaque seconde, cycle complet toutes les 5 s.
 */
(() => {
  'use strict';

  // Favori relancé : il bascule la surimpression au lieu d'en ouvrir une seconde.
  if (window.__sncfwifi) {
    window.__sncfwifi.toggle();
    return;
  }

  const FULL_INTERVAL = 5000;
  const LIVE_INTERVAL = 1000;
  const REDETECT_INTERVAL = 10000;
  const TIMEOUT = 5000;
  const LIVE_TIMEOUT = 2000;

  const params = new URLSearchParams(location.search);
  /// Serveur démo (`scripts/demo_server.py`) : il sert la page et les API SNCF / Icomera.
  const DEMO = params.has('demo');

  // MARK: - Utilitaires

  const num = (v) => {
    if (typeof v === 'number') return Number.isFinite(v) ? v : null;
    if (typeof v === 'string' && v.trim() !== '') {
      const n = Number(v.trim());
      return Number.isFinite(n) ? n : null;
    }
    if (typeof v === 'boolean') return v ? 1 : 0;
    return null;
  };
  const int = (v) => Math.trunc(num(v) ?? 0);
  const str = (v) => (typeof v === 'string' && v.trim() !== '' ? v : null);
  const clamp = (v, lo = 0, hi = 1) => Math.max(lo, Math.min(hi, v));
  const isoDate = (v) => {
    if (typeof v !== 'string' || !v) return null;
    const d = new Date(v);
    return Number.isNaN(d.getTime()) ? null : d;
  };
  const epochDate = (v) => {
    const ms = num(v);
    return ms && ms > 0 ? new Date(ms) : null;
  };
  /// Coordonnées nulles ou absentes : le GPS n'a pas de point, pas le golfe de Guinée.
  const coord = (lat, lon) => {
    const a = num(lat);
    const b = num(lon);
    return a === null || b === null || (a === 0 && b === 0) ? null : [a, b];
  };
  /// Distance en mètres.
  const distance = (p, q) => {
    const r = Math.PI / 180;
    const dLat = (q[0] - p[0]) * r;
    const dLon = (q[1] - p[1]) * r;
    const h = Math.sin(dLat / 2) ** 2 + Math.cos(p[0] * r) * Math.cos(q[0] * r) * Math.sin(dLon / 2) ** 2;
    return 2 * 6371000 * Math.asin(Math.sqrt(h));
  };
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
  const time = (d) => (d ? d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' }) : '');
  /// « 47 min », « 1h02 ».
  const duration = (ms) => {
    const minutes = Math.max(0, Math.floor(ms / 60000));
    if (minutes < 60) return `${minutes} min`;
    const rest = minutes % 60;
    return rest ? `${Math.floor(minutes / 60)}h${String(rest).padStart(2, '0')}` : `${Math.floor(minutes / 60)}h`;
  };
  /// « 142 », « 8,4 » : une décimale sous 10 km.
  const km = (v) => (v < 10 ? v.toFixed(1).replace('.', ',') : String(Math.round(v)));
  const volume = (mb) => (mb >= 1000
    ? `${(mb / 1000).toFixed(1).replace('.', ',')} Go`
    : `${mb.toFixed(1).replace('.', ',')} Mo`);
  const cardinal = (deg) => {
    const names = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE',
      'S', 'SSO', 'SO', 'OSO', 'O', 'ONO', 'NO', 'NNO'];
    return names[Math.round((((deg % 360) + 360) % 360) / 22.5) % 16];
  };

  /// Corps de réponse : JSON, chaîne JSON nue (Lyria), ou JSONP `({ … });` (Icomera).
  const parseBody = (text) => {
    try {
      return JSON.parse(text);
    } catch {
      const start = text.indexOf('{');
      const end = text.lastIndexOf('}');
      if (start < 0 || end <= start) return null;
      try { return JSON.parse(text.slice(start, end + 1)); } catch { return null; }
    }
  };

  const getJSON = async (url, timeout = TIMEOUT) => {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeout);
    try {
      const res = await fetch(url, { signal: ctrl.signal, cache: 'no-store', credentials: 'omit' });
      return parseBody(await res.text());
    } catch {
      return null;
    } finally {
      clearTimeout(timer);
    }
  };

  /// JSONP par balise script : la plateforme Icomera est faite pour être lue d'une autre origine.
  let jsonpSeq = 0;
  const jsonp = (url, timeout = TIMEOUT) => new Promise((resolve) => {
    const name = `__sncfwifiJsonp${++jsonpSeq}`;
    const script = document.createElement('script');
    let done = false;
    const finish = (value) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      delete window[name];
      script.remove();
      resolve(value ?? null);
    };
    const timer = setTimeout(() => finish(null), timeout);
    window[name] = (data) => finish(data);
    script.onerror = () => finish(null);
    // Chargé sans appel du callback : le portail a ignoré le paramètre.
    script.onload = () => setTimeout(() => finish(null), 0);
    script.src = `${url}${url.includes('?') ? '&' : '?'}callback=${name}&_=${Date.now()}`;
    document.head.appendChild(script);
  });

  /// Origine de l'API d'un réseau : la page elle-même quand elle est servie par le portail
  /// (favori) ou par le serveur démo, sinon l'hôte du train.
  const base = (host) => {
    if (DEMO || location.hostname === host) return location.origin;
    return `https://${host}`;
  };

  // MARK: - Réseaux
  //
  // Chaque réseau rend un « trajet » normalisé :
  //   { trainNumber, subtitle, speedKmh, position, altitude, stops[], nextIndex, stopped,
  //     delayMin, delayCause, axis, wifiQuality, devices, data, metrics[], note }
  // `axis` situe gares et train sur une même échelle (km, ou durée pondérée chez Lyria) pour la
  // jauge de progression entre les gares choisies.

  const SNCF_SHORT = {
    'Paris - Gare de Lyon - Hall 1 & 2': 'Paris Lyon',
    'Paris Montparnasse 1 Et 2': 'Montparnasse',
    'Marseille-Saint-Charles': 'Marseille',
    'Marseille Saint-Charles': 'Marseille',
    'Aéroport Charles De Gaulle 2 Tgv': 'CDG TGV',
    'Charles De Gaulle 2 Tgv': 'CDG TGV',
  };

  const sncf = {
    id: 'sncf',
    name: 'TGV INOUI',
    accent: '#7D206F',
    host: 'wifi.sncf',
    portal: 'https://wifi.sncf/fr/',
    url(path) { return `${base(this.host)}/router/api${path}`; },

    async probe() {
      const gps = await getJSON(this.url('/train/gps'));
      return num(gps?.speed) !== null || gps?.latitude !== undefined;
    },

    async live() {
      const gps = await getJSON(this.url('/train/gps'), LIVE_TIMEOUT);
      const speed = num(gps?.speed);
      if (speed === null) return null;
      return { speedKmh: Math.trunc(speed * 3.6), position: sncfPosition(gps) };
    },

    async full() {
      const [gps, progress, details, bar, stats, status] = await Promise.all(
        ['/train/gps', '/train/progress', '/train/details', '/bar/attendance',
          '/connection/statistics', '/connection/status'].map((p) => getJSON(this.url(p))),
      );
      const det = progress ?? details;
      if (!gps && !det) return null;

      const speedKmh = Math.trunc((num(gps?.speed) ?? 0) * 3.6);
      const position = sncfPosition(gps);
      const raw = Array.isArray(det?.stops) ? det.stops : [];

      // Chaque arrêt porte la progression du tronçon qui le relie au suivant.
      const seg = (s) => s?.progress ?? {};
      let current = 0;
      for (let i = 0; i < raw.length; i += 1) {
        current = i;
        if ((num(seg(raw[i]).progressPercentage) ?? 0) < 100) break;
      }
      const depIndex = current;
      const arrIndex = Math.min(depIndex + 1, Math.max(0, raw.length - 1));
      const stopCoord = (s) => coord(s?.coordinates?.latitude, s?.coordinates?.longitude);
      const away = (s) => {
        const c = stopCoord(s);
        return position && c ? distance(position, c) : Infinity;
      };

      let stopped = false;
      let stoppedAt = arrIndex;
      if (raw.length && speedKmh < 36) {
        if (away(raw[depIndex]) < 1500) {
          stopped = true; stoppedAt = depIndex;
        } else if (away(raw[arrIndex]) < 1500) {
          stopped = true; stoppedAt = arrIndex;
        } else if (!position) {
          const p = seg(raw[depIndex]);
          const pct = num(p.progressPercentage) ?? 0;
          if (pct < 2 || (num(p.traveledDistance) ?? Infinity) < 1500) {
            stopped = true; stoppedAt = depIndex;
          } else if (pct > 98 || (num(p.remainingDistance) ?? Infinity) < 1500) {
            stopped = true; stoppedAt = arrIndex;
          }
        }
      }

      // Distance depuis l'origine : longueur d'un tronçon = parcouru + restant.
      let cumulative = 0;
      const axisStops = raw.map((s) => {
        const here = cumulative;
        const t = num(seg(s).traveledDistance);
        const r = num(seg(s).remainingDistance);
        cumulative = cumulative !== null && t !== null && r !== null ? cumulative + (t + r) / 1000 : null;
        return here;
      });
      const travelledM = raw.slice(0, -1).reduce((sum, s) => sum + (num(seg(s).traveledDistance) ?? 0), 0);

      const stops = raw.map((s, i) => {
        const real = isoDate(s.realDate);
        const sched = isoDate(s.theoricDate);
        return {
          id: str(s.id) ?? str(s.code) ?? `${s.label ?? 'Gare'}-${i}`,
          label: str(s.label) ?? '?',
          sched,
          arrival: real ?? sched,
          departure: real ?? sched,
          delay: int(s.delay),
          coord: stopCoord(s),
          // Gares intermédiaires seulement : l'origine et le terminus annoncent 0.
          dwell: i > 0 && i < raw.length - 1 ? int(s.duration) || null : null,
        };
      });

      let delayMin = int(det?.delay) || int(raw[raw.length - 1]?.delay);
      let delayCause = '';
      if (Array.isArray(det?.events)) {
        delayCause = det.events.find((e) => e?.type === 'RETARD')?.text ?? '';
      }
      if (!delayCause) {
        delayCause = str(det?.delayReason) ?? raw.map((s) => str(s.delayReason)).find(Boolean) ?? '';
      }

      const metrics = [];
      const altitude = num(gps?.altitude);
      if (altitude !== null) metrics.push(['Altitude', `${Math.round(altitude)} m`]);
      const heading = num(gps?.heading);
      if (heading !== null && speedKmh > 0) metrics.push(['Cap', `${cardinal(heading)} · ${Math.round(heading)}°`]);
      if (travelledM > 0) metrics.push(['Parcouru', `${km(travelledM / 1000)} km`]);
      const start = stops[0]?.departure;
      if (start) {
        const elapsed = (Date.now() - start.getTime()) / 1000;
        if (elapsed > 180 && travelledM > 1000) {
          metrics.push(['Vitesse moyenne', `${Math.round((travelledM / elapsed) * 3.6)} km/h`]);
        }
      }
      // Unité non documentée : 100 000 relevé à bord, lu comme des kbit/s.
      const bandwidth = num(status?.granted_bandwidth);
      if (bandwidth > 0) metrics.push(['Débit accordé', `${Math.round(bandwidth / 1000)} Mbit/s`]);
      if (typeof bar?.isBarQueueEmpty === 'boolean') {
        metrics.push(['Attente au bar', bar.isBarQueueEmpty ? 'Non' : 'Oui']);
      }
      const rame = details?.trainId ?? progress?.trainId;
      if (rame !== undefined && rame !== null && String(rame)) metrics.push(['Rame', String(rame)]);

      let data = null;
      if (status) {
        const remaining = int(status.remaining_data);
        const consumed = int(status.consumed_data);
        if (remaining + consumed > 0) {
          const reset = epochDate(status.next_reset);
          data = { usedMB: consumed / 1000, totalMB: (consumed + remaining) / 1000, reset };
        }
      }

      const number = det?.number;
      return {
        trainNumber: str(number) ?? (num(number) !== null ? String(Math.trunc(num(number))) : null),
        subtitle: null,
        speedKmh,
        position,
        altitude,
        stops,
        nextIndex: stopped ? stoppedAt : arrIndex,
        stopped,
        delayMin,
        delayCause,
        axis: { unit: 'km', stops: axisStops, train: travelledM / 1000 },
        wifiQuality: num(stats?.quality),
        devices: num(stats?.devices),
        data,
        metrics,
        shortName: (n) => SNCF_SHORT[n] ?? n,
      };
    },
  };

  function sncfPosition(gps) {
    return coord(gps?.latitude ?? gps?.lat, gps?.longitude ?? gps?.lon ?? gps?.lng);
  }

  const OPERATORS = {
    20801: 'Orange', 20802: 'Orange', 20810: 'SFR', 20811: 'SFR', 20813: 'SFR',
    20815: 'Free', 20816: 'Free', 20820: 'Bouygues', 20821: 'Bouygues',
    20601: 'Proximus', 20605: 'Telenet', 20610: 'Orange BE', 20620: 'BASE',
    20404: 'Vodafone NL', 20408: 'KPN', 20412: 'KPN', 20416: 'Odido', 20420: 'Odido',
    26201: 'Telekom', 26202: 'Vodafone DE', 26209: 'Vodafone DE', 26203: 'O2 DE', 26207: 'O2 DE',
    23410: 'O2 UK', 23502: 'O2 UK', 23415: 'Vodafone UK', 23420: 'Three', 23430: 'EE', 23433: 'EE',
  };
  const TECHNOLOGIES = {
    nr: '5G', '5g': '5G', '5gnr': '5G', endc: '5G', 'lte-nr': '5G', nsa: '5G',
    lte: '4G', 'lte-a': '4G', '4g': '4G',
    hsdpa: '3G+', hsupa: '3G+', hspa: '3G+', 'hspa+': '3G+', umts: '3G', '3g': '3G', wcdma: '3G',
    edge: '2G', gprs: '2G', gsm: '2G', '2g': '2G', satellite: 'Satellite', sat: 'Satellite',
  };

  const eurostar = {
    id: 'eurostar',
    name: 'Eurostar',
    accent: '#173D85',
    host: 'www.ombord.info',
    portal: 'https://www.ombord.info/',
    /// Réponses JSONP même sans `callback` : lisibles en direct (même origine, serveur démo),
    /// sinon par balise script.
    async get(endpoint, timeout = TIMEOUT) {
      const url = `${base(this.host)}/api/jsonp/${endpoint}/`;
      return (await getJSON(url, timeout)) ?? (DEMO ? null : jsonp(url, timeout));
    },

    async probe() {
      const p = await this.get('position');
      return num(p?.latitude) !== null;
    },

    async live() {
      const p = await this.get('position', LIVE_TIMEOUT);
      const speed = num(p?.speed);
      if (speed === null) return null;
      return { speedKmh: Math.round(speed * 3.6), position: coord(p.latitude, p.longitude) };
    },

    async full() {
      const [p, user, users, conn, system] = await Promise.all(
        ['position', 'user', 'users', 'connectivity', 'system'].map((e) => this.get(e)),
      );
      const position = coord(p?.latitude, p?.longitude);
      if (!position) return null;

      const speedKmh = Math.round((num(p.speed) ?? 0) * 3.6);
      const altitude = num(p.altitude);
      const heading = num(p.cmg);
      const metrics = [];
      metrics.push(['Position', `${Math.abs(position[0]).toFixed(4)}° ${position[0] >= 0 ? 'N' : 'S'} · ${Math.abs(position[1]).toFixed(4)}° ${position[1] >= 0 ? 'E' : 'O'}`]);
      if (altitude !== null) metrics.push(['Altitude', `${Math.round(altitude)} m`]);
      if (heading !== null && speedKmh > 0) metrics.push(['Cap', `${cardinal(heading)} · ${Math.round(heading)}°`]);

      // Liens montants : le routeur agrège plusieurs SIM, on retient le meilleur lien disponible.
      const links = Array.isArray(conn?.links) ? conn.links : [];
      const up = links.filter((l) => l?.link_state === 'available');
      const candidates = up.length ? up : links;
      let best = null;
      for (const l of candidates) {
        const rssi = num(l.rssi);
        if (rssi !== null && rssi !== -1 && (!best || rssi > best.rssi)) best = { rssi, tech: str(l.technology) };
      }
      const techRaw = best?.tech ?? candidates.map((l) => str(l.technology)).find((t) => t && t !== '-1');
      const tech = techRaw ? (TECHNOLOGIES[techRaw.toLowerCase()] ?? techRaw.toUpperCase()) : null;
      if (conn && num(conn.online) === 0 && up.length === 0) {
        metrics.push(['Lien montant', 'Hors ligne']);
      } else {
        const parts = [tech, links.length ? `${up.length}/${links.length} liens` : null, best ? `${best.rssi} dBm` : null].filter(Boolean);
        if (parts.length) metrics.push(['Lien montant', parts.join(' · ')]);
      }
      const perOperator = new Map();
      for (const l of candidates) {
        const plmn = l.operator_id === undefined || l.operator_id === null ? '' : String(l.operator_id);
        if (!plmn || plmn === '-1') continue;
        const name = OPERATORS[plmn] ?? (plmn.length > 3 ? `${plmn.slice(0, 3)}-${plmn.slice(3)}` : plmn);
        perOperator.set(name, (perOperator.get(name) ?? 0) + 1);
      }
      if (perOperator.size) {
        const text = [...perOperator].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
          .map(([n, c]) => (c > 1 ? `${n} ×${c}` : n)).join(' · ');
        metrics.push(['Opérateurs', text]);
      }
      const online = num(users?.online);
      if (online !== null) {
        const total = num(users?.total);
        metrics.push(['Appareils', total > online ? `${online} en ligne sur ${total}` : `${online} en ligne`]);
      }
      const bytesPerSecond = num(user?.bandwidth_download_limit);
      if (bytesPerSecond > 0) metrics.push(['Débit max', `${Math.round((bytesPerSecond * 8) / 1e6)} Mbit/s`]);
      const timeleft = num(user?.timeleft);
      if (timeleft > 0) metrics.push(['Session', `reste ${duration(timeleft * 1000)}`]);

      let data = null;
      const used = num(user?.data_total_used);
      const limit = num(user?.data_total_limit);
      if (used !== null && limit > 0) data = { usedMB: used / 1e6, totalMB: limit / 1e6 };
      else if (used !== null) metrics.push(['Données', `${volume(used / 1e6)} utilisés`]);

      const name = str(system?.system_name) ?? str(system?.system);
      const rame = name?.split('-').find((part) => /^\d+$/.test(part));
      const satellites = num(p.satellites);
      return {
        trainNumber: null,
        subtitle: rame ? `Rame ${rame}` : name,
        speedKmh,
        position,
        altitude,
        stops: [],
        nextIndex: 0,
        stopped: false,
        delayMin: 0,
        delayCause: '',
        axis: null,
        wifiQuality: null,
        devices: null,
        data,
        metrics,
        note: `${satellites !== null ? `${satellites} satellite${satellites > 1 ? 's' : ''} · ` : ''}desserte et horaires non fournis par le WiFi Eurostar.`,
      };
    },
  };

  const ICE_MODELS = {
    401: 'ICE 1', 402: 'ICE 2', 403: 'ICE 3', 406: 'ICE 3M', 407: 'ICE 3 Velaro',
    408: 'ICE 3neo', 411: 'ICE T', 412: 'ICE 4', 415: 'ICE T', 605: 'ICE TD',
  };
  const ICE_INTERNET = {
    HIGH: 'fort', MIDDLE: 'moyen', WEAK: 'faible', UNSTABLE: 'instable', NO_INFO: 'inconnu', NO_INTERNET: 'coupé',
  };
  /// Les retards sont des chaînes : « +8 », « » quand il n'y en a pas.
  const iceDelay = (v) => {
    if (typeof v === 'string' && v.trim()) return parseInt(v.replace('+', ''), 10) || 0;
    return num(v) === null ? null : Math.trunc(num(v));
  };

  const ice = {
    id: 'ice',
    name: 'ICE',
    accent: '#EC0016',
    host: 'iceportal.de',
    portal: 'https://iceportal.de/',
    url(path) { return `${base(this.host)}${path}`; },

    async probe() {
      const s = await getJSON(this.url('/api1/rs/status'));
      return s?.trainType !== undefined || s?.speed !== undefined;
    },

    async live() {
      const s = await getJSON(this.url('/api1/rs/status'), LIVE_TIMEOUT);
      const speed = num(s?.speed);
      if (speed === null) return null;
      // Contrairement aux autres réseaux, `speed` est déjà en km/h.
      return { speedKmh: Math.round(speed), position: coord(s.latitude, s.longitude) };
    },

    async full() {
      const [status, tripRoot] = await Promise.all([
        getJSON(this.url('/api1/rs/status')),
        getJSON(this.url('/api1/rs/tripInfo/trip')),
      ]);
      const trip = tripRoot?.trip;
      const speedKmh = Math.round(num(status?.speed) ?? 0);
      const position = coord(status?.latitude, status?.longitude);

      const raw = Array.isArray(trip?.stops) ? trip.stops : [];
      const stops = raw.filter((s) => str(s?.station?.name)).map((s) => {
        const t = s.timetable ?? {};
        const schedDep = epochDate(t.scheduledDepartureTime);
        const realDep = epochDate(t.actualDepartureTime);
        const schedArr = epochDate(t.scheduledArrivalTime) ?? schedDep;
        const realArr = epochDate(t.actualArrivalTime) ?? realDep;
        return {
          id: str(s.station.evaNr) ?? s.station.name,
          label: s.station.name,
          sched: schedArr,
          arrival: realArr ?? schedArr,
          departure: realDep ?? schedDep,
          delay: iceDelay(t.arrivalDelay) ?? iceDelay(t.departureDelay) ?? 0,
          platform: str(s.track?.actual) ?? str(s.track?.scheduled),
          schedPlatform: str(s.track?.scheduled),
          coord: coord(s.station.geocoordinates?.latitude, s.station.geocoordinates?.longitude),
          km: int(s.info?.distanceFromStart) / 1000,
          positionStatus: s.info?.positionStatus ?? 'future',
        };
      });
      if (!stops.length && speedKmh === 0 && !position) return null;

      const totalM = int(trip?.totalDistance);
      // `actualPosition` est la distance du dernier arrêt passé, pas la position réelle.
      const travelledM = int(trip?.actualPosition) + int(trip?.distanceFromLastStop);
      const nextEva = str(trip?.stopInfo?.actualNext) ?? str(trip?.stopInfo?.scheduledNext);
      let nextIndex = stops.findIndex((s) => s.id === nextEva);
      if (nextIndex < 0) nextIndex = stops.findIndex((s) => s.positionStatus !== 'passed' && s.positionStatus !== 'departed');
      if (nextIndex < 0) nextIndex = Math.max(0, stops.length - 1);
      const stopped = speedKmh < 3 && stops[nextIndex]?.positionStatus === 'passed';

      const metrics = [];
      const conn = status?.connectivity;
      const current = str(conn?.currentState) ?? str(status?.internet);
      if (current) {
        const label = (st) => ICE_INTERNET[st.toUpperCase()] ?? st.toLowerCase();
        let text = label(current);
        const next = str(conn?.nextState);
        const seconds = num(conn?.remainingTimeSeconds);
        // `nextState` est une prévision pour la suite du parcours : le libellé doit le dire.
        if (next && next !== current && seconds > 0) {
          text += ` · ${label(next)} prévu dans ${Math.max(1, Math.floor(seconds / 60))} min`;
        }
        metrics.push(['Internet', text]);
      }
      const start = stops[0]?.departure;
      if (start && travelledM > 1000) {
        const hours = (Date.now() - start.getTime()) / 3600000;
        if (hours > 0.05) metrics.push(['Vitesse moyenne', `${Math.round(travelledM / 1000 / hours)} km/h`]);
      }
      const identity = [
        ICE_MODELS[status?.series],
        str(status?.tzn) ? `rame ${status.tzn}` : null,
        { FIRST: '1re classe', SECOND: '2e classe' }[status?.wagonClass],
      ].filter(Boolean);
      if (identity.length) metrics.push(['Rame', identity.join(' · ')]);

      const vzn = status?.vzn;
      return {
        trainNumber: str(vzn) ?? (num(vzn) !== null ? String(Math.trunc(num(vzn))) : null),
        subtitle: null,
        speedKmh,
        position,
        altitude: null,
        stops,
        nextIndex,
        stopped,
        delayMin: 0,
        delayCause: '',
        axis: totalM > 0 ? { unit: 'km', stops: stops.map((s) => s.km), train: travelledM / 1000 } : null,
        wifiQuality: null,
        devices: null,
        data: null,
        metrics,
        note: 'Carte du bar-restaurant : sur le portail iceportal.de.',
      };
    },
  };

  /// Les horaires Lyria sont suffixés `Z` mais portent l'heure **locale** du fuseau annoncé à
  /// côté (`arrivalTimezone` / `departureTimezone`).
  const zonedDate = (value, zone) => {
    const m = typeof value === 'string'
      && value.trim().replace(/Z$/, '').match(/^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)(?::(\d\d))?/);
    if (!m) return null;
    const wall = Date.UTC(+m[1], m[2] - 1, +m[3], +m[4], +m[5], +(m[6] ?? 0));
    const tz = zone || 'Europe/Paris';
    const offset = (t) => {
      try {
        const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
          timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
          hour: '2-digit', minute: '2-digit', second: '2-digit',
        }).formatToParts(new Date(t)).map((p) => [p.type, p.value]));
        return Date.UTC(+parts.year, parts.month - 1, +parts.day, +parts.hour, +parts.minute, +parts.second)
          - Math.floor(t / 1000) * 1000;
      } catch {
        return 0;
      }
    };
    let t = wall - offset(wall);
    const second = offset(t);
    if (wall - second !== t) t = wall - second;
    return new Date(t);
  };

  const lyria = {
    id: 'lyria',
    name: 'TGV Lyria',
    accent: '#E01028',
    host: 'wifi.tgv-lyria.com',
    portal: 'https://wifi.tgv-lyria.com/',
    // Le slash final est obligatoire, sinon 308.
    url(path) { return `${base(this.host)}/api/${path}/`; },
    /// Le portail rend sa page d'accueil en 200 pour tout chemin inconnu : une réponse ne vaut
    /// que si elle porte des coordonnées.
    isPosition: (j) => coord(j?.latitude, j?.longitude) !== null,

    async probe() {
      return this.isPosition(await getJSON(this.url('train/gps/position')));
    },

    async live() {
      const gps = await getJSON(this.url('train/gps/position'), LIVE_TIMEOUT);
      const speed = num(gps?.speed);
      if (!this.isPosition(gps) || speed === null) return null;
      return { speedKmh: Math.round(speed * 3.6), position: coord(gps.latitude, gps.longitude) };
    },

    async full() {
      const [travel, gpsRaw, wifi, vehicle] = await Promise.all([
        getJSON(this.url('travel')),
        getJSON(this.url('train/gps/position')),
        getJSON(this.url('wifi/status')),
        getJSON(this.url('transport/current')),
      ]);
      const gps = this.isPosition(gpsRaw) ? gpsRaw : await getJSON(this.url('travel/position'));

      const overs = Array.isArray(travel?.stopOvers) ? [...travel.stopOvers] : [];
      overs.sort((a, b) => int(a.order) - int(b.order));
      const stops = overs.map((o) => {
        const node = o?.node;
        const metas = Array.isArray(node?.metadatas) ? node.metadatas : [];
        const meta = metas.find((x) => String(x?.locale ?? '').startsWith('fr')) ?? metas[0];
        const name = str(meta?.title);
        if (!name) return null;
        const s = o.schedule ?? {};
        const schedArr = zonedDate(s.initialArrivalDate, s.arrivalTimezone);
        const realArr = zonedDate(s.realArrivalDate, s.arrivalTimezone);
        const schedDep = zonedDate(s.initialDepartureDate, s.departureTimezone);
        const realDep = zonedDate(s.realDepartureDate, s.departureTimezone);
        const real = realArr ?? realDep;
        const planned = schedArr ?? schedDep;
        return {
          id: str(node.identification) ?? name,
          label: name,
          sched: planned,
          arrival: realArr ?? schedArr ?? realDep ?? schedDep,
          departure: realDep ?? schedDep,
          delay: real && planned ? Math.round((real - planned) / 60000) : 0,
          coord: coord(node.point?.latitude, node.point?.longitude),
        };
      }).filter(Boolean);

      const position = this.isPosition(gps) ? coord(gps.latitude, gps.longitude) : null;
      if (!stops.length && !position) return null;
      const speedKmh = Math.round((num(gps?.speed) ?? 0) * 3.6);

      // Horaires figés au sillon théorique : le prochain arrêt et la jauge se déduisent du GPS,
      // projeté sur la ligne brisée des gares dont les segments pèsent leur durée théorique.
      let axis = null;
      let nextIndex = stops.findIndex((s) => s.arrival && s.arrival > new Date());
      if (nextIndex < 0) nextIndex = Math.max(0, stops.length - 1);
      if (position && stops.length > 1 && stops.every((s) => s.coord)) {
        const lengths = stops.slice(0, -1).map((s, i) => distance(s.coord, stops[i + 1].coord));
        const durations = stops.slice(0, -1).map((s, i) => {
          const to = stops[i + 1].arrival;
          return s.departure && to && to > s.departure ? to - s.departure : null;
        });
        const weights = durations.every((d) => d !== null) ? durations : lengths;
        let best = null;
        for (let i = 0; i < lengths.length; i += 1) {
          if (lengths[i] <= 0) continue;
          const [a, b] = [stops[i].coord, stops[i + 1].coord];
          const scale = Math.cos((a[0] * Math.PI) / 180);
          const ax = (b[1] - a[1]) * scale; const ay = b[0] - a[0];
          const bx = (position[1] - a[1]) * scale; const by = position[0] - a[0];
          const ratio = clamp((ax * bx + ay * by) / (ax * ax + ay * ay));
          const offset = distance(position, [a[0] + (b[0] - a[0]) * ratio, a[1] + (b[1] - a[1]) * ratio]);
          if (!best || offset < best.offset) best = { i, ratio, offset };
        }
        if (best) {
          const cumulative = [0];
          weights.forEach((w, i) => cumulative.push(cumulative[i] + w));
          axis = { unit: 'weight', stops: cumulative, train: cumulative[best.i] + weights[best.i] * best.ratio };
          nextIndex = Math.min(best.i + 1, stops.length - 1);
        }
      }
      let stopped = false;
      if (position && speedKmh < 36) {
        const at = stops.findIndex((s) => s.coord && distance(position, s.coord) < 1500);
        if (at >= 0) { stopped = true; nextIndex = at; }
      }

      const metrics = [];
      const altitude = num(gps?.altitude);
      if (altitude !== null) metrics.push(['Altitude', `${Math.round(altitude)} m`]);
      if (str(vehicle)) metrics.push(['Rame', vehicle]);
      const quality = num(wifi?.quality);
      return {
        trainNumber: str(travel?.identification),
        subtitle: null,
        speedKmh,
        position,
        altitude,
        stops,
        nextIndex,
        stopped,
        delayMin: 0,
        delayCause: '',
        axis,
        wifiQuality: quality === null ? null : clamp(Math.trunc(quality), 0, 5),
        devices: num(wifi?.nbConnectedDevices),
        data: null,
        metrics,
        note: 'Horaires théoriques : le portail Lyria ne les réactualise pas.',
      };
    },
  };

  const PROVIDERS = [sncf, eurostar, ice, lyria];

  // MARK: - Réglages (gares de départ et d'arrivée, réseau retenu)

  const store = {
    get(key) {
      try { return localStorage.getItem(`sncfwifi.${key}`); } catch { return null; }
    },
    set(key, value) {
      try {
        if (value === null) localStorage.removeItem(`sncfwifi.${key}`);
        else localStorage.setItem(`sncfwifi.${key}`, value);
      } catch { /* navigation privée */ }
    },
  };

  // MARK: - État

  const state = {
    phase: 'detecting', // detecting | none | ok
    provider: null,
    trip: null,
    live: null,
    /// Mètres parcourus d'après le GPS depuis le dernier cycle complet : les kilomètres restants
    /// diminuent chaque seconde entre deux lectures de l'API.
    liveMeters: 0,
    lastPosition: null,
    updatedAt: null,
    failures: 0,
    expanded: false,
    selected: null,
    wakeLock: null,
    visible: true,
  };

  /// Gares de départ et d'arrivée retenues, et tout ce qui en découle.
  function journey(trip) {
    const n = trip.stops.length;
    if (!n) return null;
    const find = (saved, fallback) => {
      if (!saved) return fallback;
      const i = trip.stops.findIndex((s) => s.id === saved || s.label === saved);
      return i < 0 ? fallback : i;
    };
    let dep = find(store.get('departure'), 0);
    let arr = find(store.get('arrival'), n - 1);
    // Gare d'arrivée déjà passée : on revient au terminus.
    if (arr < trip.nextIndex) arr = n - 1;
    if (dep >= arr) dep = 0;

    const now = Date.now();
    const position = state.live?.position ?? trip.position;
    let progress = null;
    let remainingKm = null;
    const axis = trip.axis;
    if (axis && axis.stops[dep] !== null && axis.stops[arr] !== null && axis.stops[arr] > axis.stops[dep]) {
      const travelled = axis.train + (axis.unit === 'km' ? state.liveMeters / 1000 : 0);
      progress = clamp((travelled - axis.stops[dep]) / (axis.stops[arr] - axis.stops[dep]));
      if (axis.unit === 'km') remainingKm = Math.max(0, axis.stops[arr] - travelled);
    }
    if (progress === null) {
      const from = trip.stops[dep].departure ?? trip.stops[dep].arrival;
      const to = trip.stops[arr].arrival;
      if (from && to && to > from) progress = clamp((now - from) / (to - from));
    }
    // À défaut de distances publiées : de gare en gare, à vol d'oiseau.
    if (remainingKm === null && position && trip.stops.slice(trip.nextIndex, arr + 1).every((s) => s.coord)) {
      let meters = 0;
      let previous = position;
      for (let i = trip.nextIndex; i <= arr; i += 1) {
        meters += distance(previous, trip.stops[i].coord);
        previous = trip.stops[i].coord;
      }
      remainingKm = meters / 1000;
    }
    const arrival = trip.stops[arr].arrival;
    return {
      dep,
      arr,
      progress,
      remainingKm,
      remainingMs: arrival && arrival > now ? arrival - now : null,
      delayMin: Math.max(trip.delayMin, trip.stops[arr].delay ?? 0),
    };
  }

  // MARK: - Boucles de rafraîchissement

  let fullTimer = null;
  let liveTimer = null;
  let fullBusy = false;
  let liveBusy = false;

  async function detect() {
    state.phase = state.provider ? state.phase : 'detecting';
    render();
    const remembered = store.get('provider');
    // Servie par un portail : son réseau d'abord, les autres seraient lus d'une autre origine.
    // En démo, `?demo=eurostar` choisit le réseau simulé (le serveur sert SNCF et Icomera).
    const own = PROVIDERS.find((p) => p.host === location.hostname || (DEMO && p.id === params.get('demo')));
    const order = own ? [own] : [...PROVIDERS].sort((a, b) => (b.id === remembered) - (a.id === remembered));
    const results = await Promise.all(order.map((p) => p.probe().catch(() => false)));
    const found = order[results.indexOf(true)] ?? null;
    if (found) {
      state.provider = found;
      store.set('provider', found.id);
      state.failures = 0;
      await refreshFull();
    } else {
      state.phase = 'none';
      state.provider = null;
      state.trip = null;
      render();
    }
    schedule();
  }

  async function refreshFull() {
    if (!state.provider || fullBusy) return;
    fullBusy = true;
    try {
      const trip = await state.provider.full().catch(() => null);
      if (trip) {
        state.trip = trip;
        state.phase = 'ok';
        state.failures = 0;
        state.liveMeters = 0;
        state.lastPosition = trip.position;
        state.updatedAt = new Date();
      } else if (++state.failures >= 3) {
        state.provider = null;
        state.phase = 'none';
        state.trip = null;
      }
      render();
    } finally {
      fullBusy = false;
    }
  }

  async function refreshLive() {
    if (!state.provider || !state.trip || liveBusy) return;
    liveBusy = true;
    try {
      const fix = await state.provider.live().catch(() => null);
      if (!fix) return;
      if (fix.position && state.lastPosition) {
        const step = distance(state.lastPosition, fix.position);
        // Un saut de plus de 2 km en une seconde est un écart du GPS, pas du chemin parcouru.
        if (step < 2000) state.liveMeters += step;
      }
      if (fix.position) state.lastPosition = fix.position;
      state.live = fix;
      renderHero();
    } finally {
      liveBusy = false;
    }
  }

  function schedule() {
    clearInterval(fullTimer);
    clearInterval(liveTimer);
    if (!state.visible) return;
    if (state.provider) {
      fullTimer = setInterval(refreshFull, FULL_INTERVAL);
      liveTimer = setInterval(refreshLive, LIVE_INTERVAL);
    } else {
      fullTimer = setInterval(detect, REDETECT_INTERVAL);
    }
  }

  // Onglet masqué : aucun appel, la batterie compte aussi à bord.
  document.addEventListener('visibilitychange', () => {
    state.visible = document.visibilityState === 'visible';
    if (state.visible) {
      if (state.wakeLock === 'lost') requestWakeLock();
      if (state.provider) refreshFull(); else detect();
    }
    schedule();
  });

  // MARK: - Écran toujours allumé

  async function requestWakeLock() {
    try {
      const lock = await navigator.wakeLock.request('screen');
      state.wakeLock = lock;
      lock.addEventListener('release', () => {
        if (state.wakeLock === lock) state.wakeLock = 'lost';
        render();
      });
    } catch {
      state.wakeLock = null;
    }
    render();
  }

  function toggleWakeLock() {
    if (state.wakeLock && state.wakeLock !== 'lost') {
      const lock = state.wakeLock;
      state.wakeLock = null;
      lock.release();
      render();
    } else if (state.wakeLock === 'lost') {
      state.wakeLock = null;
      render();
    } else {
      requestWakeLock();
    }
  }

  // MARK: - Rendu

  const STYLE = `
.sw{--accent:#7D206F;--bg:#f4f3f6;--card:#fff;--text:#16141a;--muted:#6d6878;--line:#e4e1e8;--warn:#c2410c;--warn-bg:#fff1e8;
  font:15px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:var(--text);background:var(--bg);
  -webkit-font-smoothing:antialiased;box-sizing:border-box;min-height:100%;padding:16px 16px 32px}
@media (prefers-color-scheme:dark){.sw{--bg:#111014;--card:#1c1a21;--text:#f2f0f5;--muted:#9a94a6;--line:#2e2b35;--warn:#fb923c;--warn-bg:#2a1a10}}
.sw *,.sw *::before,.sw *::after{box-sizing:border-box}
.sw-inner{max-width:560px;margin:0 auto;display:flex;flex-direction:column;gap:12px}
.sw-card{background:var(--card);border-radius:18px;padding:16px;box-shadow:0 1px 2px rgba(0,0,0,.06)}
.sw-head{display:flex;align-items:center;gap:10px}
.sw-badge{background:var(--accent);color:#fff;font-weight:700;font-size:13px;padding:4px 10px;border-radius:999px;white-space:nowrap}
.sw-head-text{min-width:0;flex:1}
.sw-title{font-weight:650;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sw-sub{color:var(--muted);font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sw-close{border:0;background:var(--line);color:var(--text);width:32px;height:32px;border-radius:50%;font-size:18px;cursor:pointer;flex:none}
.sw-hero{display:flex;align-items:flex-end;justify-content:space-between;gap:12px}
.sw-speed{font-size:64px;font-weight:750;letter-spacing:-2px;line-height:1;font-variant-numeric:tabular-nums}
.sw-unit{font-size:15px;font-weight:600;color:var(--muted);letter-spacing:0;margin-left:4px}
.sw-side{text-align:right;display:flex;flex-direction:column;gap:6px}
.sw-side b{font-size:22px;font-variant-numeric:tabular-nums}
.sw-side small{display:block;color:var(--muted);font-size:12px}
.sw-gauge{margin-top:14px;height:8px;border-radius:999px;background:var(--line);overflow:hidden}
.sw-gauge>i{display:block;height:100%;background:var(--accent);border-radius:999px;transition:width .6s}
.sw-ends{display:flex;justify-content:space-between;gap:8px;margin-top:6px;font-size:12px;color:var(--muted)}
.sw-ends span:last-child{text-align:right}
.sw-next{margin-top:12px;font-size:14px}
.sw-next b{font-weight:650}
.sw-delay{background:var(--warn-bg);color:var(--warn);border-radius:12px;padding:10px 12px;font-size:14px;font-weight:600}
.sw-h{font-size:13px;font-weight:650;color:var(--muted);text-transform:uppercase;letter-spacing:.04em;margin:0 0 8px}
.sw-stops{list-style:none;margin:0;padding:0}
.sw-stop{display:grid;grid-template-columns:52px 18px 1fr;gap:0 8px;align-items:stretch;cursor:pointer}
.sw-time{text-align:right;font-variant-numeric:tabular-nums;font-size:14px;padding:6px 0}
.sw-time s{display:block;color:var(--muted);font-size:12px}
.sw-rail{position:relative;display:flex;justify-content:center}
.sw-rail::before{content:"";position:absolute;top:0;bottom:0;width:3px;background:var(--line)}
.sw-stop:first-child .sw-rail::before{top:16px}
.sw-stop:last-child .sw-rail::before,.sw-stop.current .sw-rail::before{bottom:calc(100% - 16px)}
.sw-stop.passed .sw-rail::before,.sw-stop.current .sw-rail::before{background:var(--accent)}
.sw-dot{position:relative;align-self:flex-start;margin-top:10px;width:12px;height:12px;border-radius:50%;background:var(--card);border:3px solid var(--line)}
.sw-stop.passed .sw-dot{background:var(--accent);border-color:var(--accent)}
.sw-stop.current .sw-dot{border-color:var(--accent);width:16px;height:16px;margin-top:8px}
.sw-stop.mine .sw-dot{box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 25%,transparent)}
.sw-name{padding:6px 0;min-width:0}
.sw-stop.passed .sw-name,.sw-stop.passed .sw-time{color:var(--muted)}
.sw-name small{display:block;color:var(--muted);font-size:12px}
.sw-tag{display:inline-block;font-size:11px;font-weight:700;color:var(--accent);border:1px solid currentColor;border-radius:6px;padding:0 5px;margin-left:6px;vertical-align:1px}
.sw-changed{color:var(--warn);font-weight:650}
.sw-actions{display:flex;gap:8px;margin-top:6px}
.sw-btn{border:1px solid var(--line);background:var(--card);color:var(--text);border-radius:10px;padding:7px 12px;font:inherit;font-size:13px;font-weight:600;cursor:pointer}
.sw-btn.on{background:var(--accent);border-color:var(--accent);color:#fff}
.sw-fold{grid-column:3;color:var(--accent);font-size:13px;font-weight:600;padding:4px 0}
.sw-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px}
.sw-metric small{display:block;color:var(--muted);font-size:12px}
.sw-metric b{font-weight:650}
.sw-bars{display:inline-flex;gap:2px;align-items:flex-end;height:14px;margin-right:6px;vertical-align:-1px}
.sw-bars i{width:4px;background:var(--line);border-radius:1px}
.sw-bars i.on{background:var(--accent)}
.sw-note{color:var(--muted);font-size:12px;margin-top:10px}
.sw-foot{display:flex;flex-wrap:wrap;gap:8px;align-items:center;justify-content:space-between;color:var(--muted);font-size:12px}
.sw-foot div{display:flex;gap:8px}
.sw-empty{text-align:center;padding:28px 16px}
.sw-empty h2{margin:0 0 8px;font-size:20px}
.sw-empty p{color:var(--muted);margin:0 0 10px}
.sw-empty a{color:var(--accent)}
.sw-spin{width:28px;height:28px;border:3px solid var(--line);border-top-color:var(--accent);border-radius:50%;margin:0 auto 14px;animation:sw-spin 1s linear infinite}
@keyframes sw-spin{to{transform:rotate(360deg)}}
.sw-overlay{position:fixed;inset:0;z-index:2147483647;overflow-y:auto;-webkit-overflow-scrolling:touch}
`;

  // Montage : dans la page de la version web, ou en surimpression sur le portail du train.
  let root = document.getElementById('sncfwifi-app');
  const overlay = !root;
  if (!document.getElementById('sncfwifi-style')) {
    const style = document.createElement('style');
    style.id = 'sncfwifi-style';
    style.textContent = STYLE;
    document.head.appendChild(style);
  }
  if (overlay) {
    root = document.createElement('div');
    root.className = 'sw-overlay';
    document.body.appendChild(root);
  }
  root.classList.add('sw');

  function shortName(name) {
    return state.trip?.shortName?.(name) ?? name;
  }

  function heroHTML(trip, j) {
    const speed = state.live?.speedKmh ?? trip.speedKmh;
    let side = '';
    if (j?.remainingMs !== null && j?.remainingMs !== undefined) {
      side += `<div><b>${duration(j.remainingMs)}</b><small>restant</small></div>`;
    }
    if (j?.remainingKm !== null && j?.remainingKm !== undefined) {
      side += `<div><b>${km(j.remainingKm)} km</b><small>jusqu'à ${esc(shortName(trip.stops[j.arr].label))}</small></div>`;
    }
    let html = `<div class="sw-hero"><div class="sw-speed" data-speed>${speed}<span class="sw-unit">km/h</span></div>
      <div class="sw-side">${side}</div></div>`;
    if (j?.progress !== null && j?.progress !== undefined) {
      html += `<div class="sw-gauge"><i style="width:${(j.progress * 100).toFixed(1)}%"></i></div>
        <div class="sw-ends"><span>${esc(shortName(trip.stops[j.dep].label))}</span>
        <span>${Math.round(j.progress * 100)} %</span><span>${esc(shortName(trip.stops[j.arr].label))}</span></div>`;
    }
    const next = trip.stops[trip.nextIndex];
    if (next) {
      const platform = next.platform ? ` · voie ${esc(next.platform)}` : '';
      if (trip.stopped) {
        const leave = next.departure && next.departure > new Date() ? ` · départ ${time(next.departure)}` : '';
        html += `<div class="sw-next">En gare de <b>${esc(next.label)}</b>${platform}${leave}</div>`;
      } else {
        const when = next.arrival
          ? ` à ${time(next.arrival)}${next.arrival > new Date() ? ` · dans ${duration(next.arrival - new Date())}` : ''}`
          : '';
        html += `<div class="sw-next">Prochain arrêt <b>${esc(next.label)}</b>${when}${platform}</div>`;
      }
    }
    return html;
  }

  function stopsHTML(trip, j) {
    const rows = [];
    const fold = (count, where) => `<li class="sw-stop" data-fold><span></span><span class="sw-rail"></span>
      <span class="sw-fold">${state.expanded ? 'Replier' : `${count} arrêt${count > 1 ? 's' : ''} ${where}`}</span></li>`;
    if (!state.expanded && j.dep > 0) rows.push(fold(j.dep, 'avant'));
    trip.stops.forEach((s, i) => {
      if (!state.expanded && (i < j.dep || i > j.arr)) return;
      const status = i < trip.nextIndex ? 'passed' : i === trip.nextIndex ? 'current' : 'upcoming';
      const late = s.delay > 0 && s.sched && s.arrival && time(s.sched) !== time(s.arrival);
      const details = [];
      if (s.platform) {
        details.push(s.schedPlatform && s.schedPlatform !== s.platform
          ? `<span class="sw-changed">voie <s>${esc(s.schedPlatform)}</s> ${esc(s.platform)}</span>`
          : `voie ${esc(s.platform)}`);
      }
      if (s.dwell) details.push(`arrêt ${s.dwell} min`);
      if (s.delay > 0) details.push(`<span class="sw-changed">+${s.delay} min</span>`);
      const tag = i === j.dep ? '<span class="sw-tag">Départ</span>' : i === j.arr ? '<span class="sw-tag">Arrivée</span>' : '';
      const actions = state.selected === s.id ? `<div class="sw-actions">
          <button class="sw-btn${i === j.dep ? ' on' : ''}" data-departure="${esc(s.id)}">Ma gare de départ</button>
          ${i >= trip.nextIndex ? `<button class="sw-btn${i === j.arr ? ' on' : ''}" data-arrival="${esc(s.id)}">Ma gare d'arrivée</button>` : ''}</div>` : '';
      rows.push(`<li class="sw-stop ${status}${i >= j.dep && i <= j.arr ? ' mine' : ''}" data-stop="${esc(s.id)}">
        <span class="sw-time">${late ? `<s>${time(s.sched)}</s>` : ''}${time(s.arrival)}</span>
        <span class="sw-rail"><span class="sw-dot"></span></span>
        <span class="sw-name">${esc(s.label)}${tag}${details.length ? `<small>${details.join(' · ')}</small>` : ''}${actions}</span></li>`);
    });
    const after = trip.stops.length - 1 - j.arr;
    if (!state.expanded && after > 0) rows.push(fold(after, 'après'));
    if (state.expanded && (j.dep > 0 || after > 0)) rows.push(fold(0, ''));
    return `<div class="sw-card"><h3 class="sw-h">Desserte</h3><ul class="sw-stops">${rows.join('')}</ul>
      <div class="sw-note">Touchez une gare pour en faire votre gare de départ ou d'arrivée.</div></div>`;
  }

  function metricsHTML(trip) {
    const tiles = [];
    if (trip.wifiQuality !== null && trip.wifiQuality !== undefined) {
      const bars = [1, 2, 3, 4, 5].map((n) => `<i class="${n <= trip.wifiQuality ? 'on' : ''}" style="height:${4 + n * 2}px"></i>`).join('');
      tiles.push(`<div class="sw-metric"><small>WiFi</small><b><span class="sw-bars">${bars}</span>${trip.wifiQuality}/5</b></div>`);
    }
    if (trip.devices !== null && trip.devices !== undefined) {
      tiles.push(`<div class="sw-metric"><small>Appareils connectés</small><b>${trip.devices}</b></div>`);
    }
    if (trip.data) {
      const ratio = clamp(trip.data.usedMB / trip.data.totalMB);
      const reset = trip.data.reset ? ` · remise à zéro ${time(trip.data.reset)}` : '';
      tiles.push(`<div class="sw-metric" style="grid-column:1/-1"><small>Données : ${volume(trip.data.usedMB)} sur ${volume(trip.data.totalMB)}${reset}</small>
        <div class="sw-gauge" style="margin-top:6px"><i style="width:${(ratio * 100).toFixed(1)}%"></i></div></div>`);
    }
    for (const [label, value] of trip.metrics) {
      tiles.push(`<div class="sw-metric"><small>${esc(label)}</small><b>${esc(value)}</b></div>`);
    }
    if (!tiles.length && !trip.note) return '';
    return `<div class="sw-card"><h3 class="sw-h">En détail</h3><div class="sw-grid">${tiles.join('')}</div>
      ${trip.note ? `<div class="sw-note">${esc(trip.note)}</div>` : ''}</div>`;
  }

  function footHTML() {
    const wake = 'wakeLock' in navigator
      ? `<button class="sw-btn${state.wakeLock && state.wakeLock !== 'lost' ? ' on' : ''}" data-wake>Écran allumé</button>`
      : '';
    const ago = state.updatedAt ? `mis à jour à ${state.updatedAt.toLocaleTimeString('fr-FR')}` : '';
    return `<div class="sw-foot"><span>${esc(state.provider?.name ?? '')}${DEMO ? ' · démo' : ''} · ${ago}</span>
      <div>${wake}<button class="sw-btn" data-refresh>Actualiser</button></div></div>`;
  }

  function headHTML(trip) {
    const p = state.provider;
    const j = trip?.stops.length ? journey(trip) : null;
    const title = trip?.trainNumber ? `Train n° ${esc(trip.trainNumber)}` : esc(p?.name ?? 'SNCF Wifi');
    const destination = trip?.stops.length ? `→ ${esc(trip.stops[j.arr].label)}` : esc(trip?.subtitle ?? '');
    return `<div class="sw-head">${p ? `<span class="sw-badge">${esc(p.name)}</span>` : ''}
      <div class="sw-head-text"><div class="sw-title">${title}</div><div class="sw-sub">${destination}</div></div>
      ${overlay ? '<button class="sw-close" data-close aria-label="Fermer">×</button>' : ''}</div>`;
  }

  function emptyHTML() {
    if (state.phase === 'detecting') {
      return `<div class="sw-card sw-empty"><div class="sw-spin"></div><p>Recherche du WiFi du train…</p></div>`;
    }
    const hint = overlay
      ? `<p>Ce portail ne répond pas comme celui d'un train pris en charge (WiFi SNCF, Eurostar, ICE, TGV Lyria).</p>`
      : `<p>Connectez-vous au WiFi du train. Le portail SNCF ne laisse pas une page extérieure lire ses données :
         ouvrez <a href="https://wifi.sncf/fr/" target="_blank" rel="noopener">wifi.sncf</a>, puis lancez le favori
         <b>SNCF Wifi</b> (voir « Installer le favori » plus bas).</p>`;
    return `<div class="sw-card sw-empty"><h2>Pas de train détecté</h2>${hint}
      <p><button class="sw-btn" data-refresh>Réessayer</button></p></div>`;
  }

  function render() {
    const trip = state.phase === 'ok' ? state.trip : null;
    if (state.provider) root.style.setProperty('--accent', state.provider.accent);
    if (!trip) {
      root.innerHTML = `<div class="sw-inner">${overlay ? headHTML(null) : ''}${emptyHTML()}</div>`;
      return;
    }
    const j = trip.stops.length ? journey(trip) : null;
    const delay = j ? j.delayMin : trip.delayMin;
    root.innerHTML = `<div class="sw-inner">${headHTML(trip)}
      ${delay > 0 ? `<div class="sw-delay">Retard +${delay} min${trip.delayCause ? ` · ${esc(trip.delayCause)}` : ''}</div>` : ''}
      <div class="sw-card" data-hero>${heroHTML(trip, j)}</div>
      ${j ? stopsHTML(trip, j) : ''}
      ${metricsHTML(trip)}
      ${footHTML()}</div>`;
  }

  /// Relecture de la seconde : seul le bloc vitesse / jauge est redessiné.
  function renderHero() {
    const hero = root.querySelector('[data-hero]');
    if (!hero || !state.trip) return;
    hero.innerHTML = heroHTML(state.trip, state.trip.stops.length ? journey(state.trip) : null);
  }

  root.addEventListener('click', (event) => {
    const target = event.target.closest('button, [data-stop], [data-fold]');
    if (!target) return;
    if (target.matches('[data-close]')) { api.toggle(); return; }
    if (target.matches('[data-refresh]')) { detect(); return; }
    if (target.matches('[data-wake]')) { toggleWakeLock(); return; }
    if (target.matches('[data-fold]')) { state.expanded = !state.expanded; render(); return; }
    if (target.dataset.departure) {
      store.set('departure', target.dataset.departure);
      state.selected = null;
      render();
      return;
    }
    if (target.dataset.arrival) {
      store.set('arrival', target.dataset.arrival);
      state.selected = null;
      render();
      return;
    }
    if (target.dataset.stop) {
      state.selected = state.selected === target.dataset.stop ? null : target.dataset.stop;
      render();
    }
  });

  const api = {
    toggle() {
      if (!overlay) return;
      const hidden = root.style.display === 'none';
      root.style.display = hidden ? '' : 'none';
      state.visible = hidden;
      schedule();
      if (hidden) refreshFull();
    },
  };
  window.__sncfwifi = api;

  detect();
})();
