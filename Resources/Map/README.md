# Carte hors ligne

Moteur de la carte du panneau quand le réseau embarque son propre serveur de tuiles
(WiFi SNCF : `https://wifi.sncf/karto/style-light.json`, tuiles `maps/*.pmtiles`). Aucune
requête ne part sur Internet : style, tuiles, polices et pictogrammes viennent du train.

| Fichier | Origine | Licence |
|---|---|---|
| `maplibre-gl.js`, `maplibre-gl.css` | [maplibre-gl](https://www.npmjs.com/package/maplibre-gl) 5.24.0, `dist/` | BSD-3-Clause (`LICENSE-maplibre-gl.txt`) |
| `pmtiles.js` | [pmtiles](https://www.npmjs.com/package/pmtiles) 4.5.0, `dist/` | BSD-3-Clause (`LICENSE-pmtiles.txt`) |
| `map.html` | ce dépôt | — |

Les deux bibliothèques sont copiées telles quelles, commentaire `sourceMappingURL` retiré.
`TrainMapView.swift` insère leur contenu dans `map.html` (aux marqueurs `/*MAPLIBRE_CSS*/`,
`/*MAPLIBRE_JS*/`, `/*PMTILES_JS*/`) et charge la page avec l'origine du portail pour que les
lectures de tuiles restent de même origine (le serveur du train n'envoie pas d'en-têtes CORS).

Mise à jour : `npm pack maplibre-gl@5 pmtiles@4`, puis recopier les fichiers `dist/`.
MapLibre 5 exige WebGL 2 (Safari 15 ou plus récent).
