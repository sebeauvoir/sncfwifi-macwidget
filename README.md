# SNCFWifi — Widget barre de menus macOS 🚄

[![Build](https://github.com/antvgr/sncfwifi-macwidget/actions/workflows/build.yml/badge.svg)](https://github.com/antvgr/sncfwifi-macwidget/actions/workflows/build.yml)
[![GitHub Release](https://img.shields.io/github/v/release/antvgr/sncfwifi-macwidget?include_prereleases)](https://github.com/antvgr/sncfwifi-macwidget/releases/latest)
[![Coding with AI](https://img.shields.io/badge/Coding_with-AI-blue?style=flat)](https://github.com/nuclearrockstone/coding-with-ai-badge)

Un widget pour la barre de menus macOS qui exploite l'API du portail WiFi de votre train pour
afficher en temps réel les informations de votre trajet : gare suivante, vitesse, retard,
données mobiles, etc.

Deux réseaux embarqués sont pris en charge — **WiFi SNCF** et **WiFi Eurostar** (transmanche et
continental) — et détectés automatiquement. Chaque réseau expose des données différentes : le tableau de la section
[Réseaux pris en charge](#réseaux-wifi-pris-en-charge-) dit exactement ce que vous verrez dans
chaque train.

---

## Réseaux WiFi pris en charge 🚆

| Réseau | Trains | API | Desserte · retard · ETA | Vitesse | Position · cap | Opérateurs mobiles | Données | Qualité WiFi |
|---|---|---|---|---|---|---|---|---|
| **WiFi SNCF** | TGV INOUI, Intercités, Lyria | `wifi.sncf` | ✅ | ✅ | interne¹ | ❌ | ✅ | ✅ |
| **WiFi Eurostar** | Eurostar transmanche (Londres ↔ Paris / Bruxelles / Amsterdam) et Eurostar continental (ex-Thalys) | `ombord.info` (Icomera) | ❌² | ✅ | ✅ | ✅ | ✅ | ❌³ |

<sub>¹ La position GPS sert à détecter l'arrêt en gare, elle n'est pas affichée. ·
² L'API du portail n'expose aucune donnée de trajet, voir ci-dessous. ·
³ Le RSSI disponible est celui des modems 4G du toit, pas du WiFi de la voiture : il est affiché
comme « lien montant » plutôt que déguisé en qualité WiFi.</sub>

### 🇫🇷 WiFi SNCF — TGV INOUI, Intercités, Lyria

SSID reconnus : `_SNCF_WIFI_INOUI`, `OUIFI`, `SNCF_WIFI_INTERCITES`, `WIFI_SNCF`, `_WIFI_LYRIA`

<p align="center">
  <img src="img/sncf-panel.gif" width="55%" />
</p>

Ce que le widget affiche :

- **Pastille** : prochaine gare et temps restant (`Milano · 3h42`) avec jauge de progression, ou
  `En gare de Lyon` à l'arrêt ; le retard s'intercale 5 s (`⚠ +12min · Régulation du trafic`)
- **Panneau** : numéro de train et destination, desserte complète avec heures théoriques barrées
  en cas de retard, vitesse, qualité WiFi et nombre de passagers connectés, consommation de
  données avec heure de remise à zéro
- **Réglages** : choix de la gare d'arrivée (pour l'ETA et la progression) et notification
  système 5 / 10 / 15 min avant l'arrivée

| Endpoint | Contenu utilisé |
|---|---|
| `GET /router/api/train/gps` | vitesse (**en m/s**), latitude, longitude |
| `GET /router/api/train/progress` (ou `/details`) | numéro de train, arrêts, horaires, retard et cause |
| `GET /router/api/connection/statistics` | qualité WiFi (0…5), appareils connectés |
| `GET /router/api/connection/status` | données consommées / restantes, prochaine remise à zéro |
| `GET /router/api/bar/attendance` | affluence au bar — lue et présente dans le JSON de debug, pas encore affichée |

### 🇪🇺 WiFi Eurostar — transmanche et continental (ex-Thalys)

Toute la flotte Eurostar utilise le portail Icomera « Internet Ombord », que ce soit sur les
liaisons transmanche ou sur les rames continentales héritées de Thalys.

SSID reconnus : `EurostarWiFi`, `Eurostar WiFi`, `Eurostar`, `_EUROSTAR_WIFI`, `THALYSNET`, `_THALYSNET`

<p align="center">
  <img src="img/eurostar-panel.png" width="42%" />
  &nbsp;&nbsp;
  <img src="img/eurostar-menubar.png" width="30%" />
</p>

Ce que le widget affiche :

- **Pastille** : `Eurostar · 278 km/h`, sans jauge — il n'y a pas de progression à calculer
- **Panneau** : numéro de rame, vitesse, position GPS, altitude, cap cardinal, état des liens
  montants (`4G · 5/5 liens · -28 dBm`), **opérateurs mobiles agrégés** (`Orange BE ×2 ·
  Proximus ×2 · BASE`), appareils connectés, consommation de données

**Pas de desserte, ni d'horaires, ni de retard sur ce réseau** : le portail expose bien une API
PIS (`onboard.eurostar.com/services/pis/v1/journey`, `/route`, `/stations`, `/vehicle`), mais elle
répond `{"error":"journey not found"}` là où elle a été testée. C'est une limite de l'API
embarquée, pas du widget — si elle s'avère provisionnée sur d'autres rames, la desserte pourra
être ajoutée sans rien changer d'autre (il suffit de déclarer `.journey` et de remplir `stops`).

> Les relevés d'endpoints ci-dessous ont été faits sur une rame **continentale** (`eurostar-4342-2i`).
> La flotte transmanche partageant le même portail Icomera, les mêmes endpoints s'appliquent ;
> si vous constatez un écart à bord, **Debug → Copier le JSON** donne le détail des réponses.

| Endpoint | Contenu utilisé |
|---|---|
| `GET https://www.ombord.info/api/jsonp/position/` | latitude, longitude, altitude, vitesse (**en m/s**), `cmg` (cap), satellites |
| `GET https://www.ombord.info/api/jsonp/user/` | quota de l'appareil (`data_total_used` / `data_total_limit`, en octets) |
| `GET https://www.ombord.info/api/jsonp/users/` | appareils connectés (`online` / `total`) |
| `GET https://www.ombord.info/api/jsonp/connectivity/` | liens montants : technologie, RSSI, `operator_id` (PLMN → opérateur) |
| `GET https://www.ombord.info/api/jsonp/system/` | `system_name` (ex. `eurostar-4342-2i`) → numéro de rame |

> Ces réponses sont du **JSONP même sans paramètre `callback`** (`({ … });`) : le corps est
> décapsulé avant d'être décodé.

### Comment le réseau est détecté

1. Le **SSID** est comparé aux listes ci-dessus : si ça correspond, l'API du réseau est appelée
   directement.
2. Si le SSID est **inconnu** ou **illisible** (macOS 14.4+ exige l'autorisation Localisation pour
   le lire), les APIs de tous les réseaux sont sondées en parallèle, un appel chacune. Le verdict
   est mémorisé par SSID pour ne pas re-sonder à chaque cycle ; un réseau sans train est écarté
   pendant 5 min, et le bouton **Actualiser** court-circuite ce délai.
3. Un réseau peut exiger que l'hôte de son API résolve vers une **adresse privée** : à bord,
   `ombord.info` pointe sur le routeur du train. Sans ce contrôle, une API joignable depuis
   l'internet public pourrait afficher un train fantôme.

Hors d'un réseau connu, le widget ne fait aucun appel : c'est autant de batterie économisée.

---

## Téléchargement ⬇️

> Pas besoin de compiler — téléchargez directement le `.zip` depuis la page **Releases**.

**[→ Télécharger la dernière version](https://github.com/antvgr/sncfwifi-macwidget/releases/latest)**

1. Décompressez le `.zip`
2. Glissez `SNCFWifi.app` dans votre dossier `Applications`
3. Double-cliquez pour lancer — l'icône apparaît dans la barre des menus

> **macOS bloque l'app** (non signée avec un certificat Apple Developer) lors du premier lancement. Deux options :
> - **Méthode simple** : faites un **clic droit → Ouvrir** sur `SNCFWifi.app`, puis cliquez **Ouvrir** dans la fenêtre d'avertissement
> - **Via le Terminal** : après avoir déplacé l'app dans `/Applications`, exécutez `xattr -cr /Applications/SNCFWifi.app` puis double-cliquez normalement

💡 **Lancement automatique au démarrage** : `Réglages Système > Général > Éléments de connexion` → cliquez `+` et ajoutez `SNCFWifi.app`.

---

## Prérequis ⚙️

- macOS 11 (Big Sur) ou plus récent — Apple Silicon et Intel (binaire universel)
- Connexion au WiFi d'un train pris en charge pour que l'API réponde
- *(pour compiler)* Xcode Command Line Tools (`xcode-select --install`)

---

## Compilation manuelle 🔨

Un script bash compile et empaquète le projet en `.app` :

```bash
chmod +x build.sh
./build.sh
open SNCFWifi.app
```

---

## Ajouter un réseau 🧩

Un réseau = **un fichier**. Rien à modifier dans les vues, le contrôleur ou la pastille.

**1.** Créez `Sources/MonReseauDataSource.swift` conforme à `TrainDataSource` :

```swift
final class MonReseauDataSource: TrainDataSource {

    let descriptor = TrainProviderDescriptor(
        id: "monreseau",
        displayName: "Mon Réseau",
        ssids: ["mon_wifi_train"],        // en minuscules
        accentHex: 0x1B7F4B,              // couleur d'accent du panneau
        features: [.speed, .position],    // pilote la forme du panneau
        apiHost: "portail.exemple",
        requiresPrivateAPIHost: true      // l'API n'est joignable qu'à bord
    )

    func probe(completion: @escaping (Bool) -> Void) {
        // Un seul appel : « suis-je à bord ? »
    }

    func fetch(completion: @escaping (TrainSnapshot?) -> Void) {
        // Appelez votre API, puis rendez un TrainSnapshot (nil si injoignable).
        // Les spécificités du réseau passent par TrainViewState.metrics :
        //   MetricRow(id: "position", symbol: "location.fill", text: "…")
        // Déclarez .journey et remplissez stops + JourneyContext pour obtenir
        // la timeline, l'ETA et les notifications d'arrivée sans code en plus.
    }
}
```

**2.** Enregistrez-le dans `TrainProviders.all` (`Sources/TrainProvider.swift`). L'ordre ne sert
qu'à départager si deux réseaux répondent : aucun n'est privilégié.

**3.** Ajoutez le fichier à `SWIFT_SOURCES` dans `build.sh` (la liste est explicite, pas un glob).

**4.** Testez : `./build.sh && open SNCFWifi.app`, et **Debug → Copier le JSON** pour vérifier les
payloads bruts reçus. Sans être à bord, un petit binaire de sonde suffit :
`swiftc Sources/*.swift votre_main.swift -o sonde`.

---

## Mode Démo via serveur local 🧪

Permet de simuler un trajet **SNCF** sans être dans le train.

1. Lancer le serveur :
   ```bash
   chmod +x start_demo_server.sh
   ./start_demo_server.sh
   ```
2. Ouvrir le panneau de configuration :
   - dans l'app : **Debug → Ouvrir le panneau démo**
   - ou directement : `http://127.0.0.1:8787`
3. Activer **Debug → Mode Démo** dans l'app.

Le panneau HTML fait varier vitesse, retard et cause, index d'arrêt, arrêt en gare, qualité WiFi
et données. Il rejoue les 5 endpoints `wifi.sncf` consommés par l'app.

---

## À intégrer plus tard 📋

- **Serveur démo multi-réseaux** : étendre `scripts/demo_server.py` aux 5 routes Icomera et rendre
  l'URL de base configurable par réseau dans `MockTrainData`, pour développer un réseau Eurostar
  sans être à bord. Piste plus ambitieuse : un serveur piloté par des scénarios JSON, un dossier
  par réseau, pour ne plus toucher au Python à chaque ajout.
- **Affluence au bar** : l'endpoint SNCF est lu mais la sémantique de `attendance` reste à
  confirmer avant de l'afficher.
- **Position en mode SNCF** : les coordonnées sont déjà là, elles pourraient alimenter les mêmes
  métriques que le mode Eurostar.
- **Eurostar** : re-tester l'API PIS sur d'autres rames, notamment **transmanche** — elle existe,
  elle n'est simplement pas provisionnée sur celles observées. Si elle répond, la desserte, l'ETA
  et les notifications s'activent en déclarant `.journey` sur le descripteur.
- **Contrôle d'hôte privé pour SNCF** : à bord d'un TGV, vérifier `dig +short wifi.sncf` puis
  activer `requiresPrivateAPIHost` sur le descripteur SNCF.
- **Réseaux repérés, non pris en charge** : WifiOnICE (`iceportal.de`), Trenitalia
  (`portalefrecce.it`), NS, Renfe, TER / Ouigo.

---

## Développé avec l'IA 🤖

Ce projet a été développé en grande partie avec l'aide de l'Intelligence Artificielle.

![Claude](https://cwab.nuclearrockstone.xyz/api/badge?name=claude&theme=dark)
