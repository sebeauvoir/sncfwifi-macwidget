# Logos des compagnies

Déposez ici le logo de chaque compagnie. L'en-tête du panneau l'affiche à la place de l'icône
générique 🚋 **et** du nom de la compagnie ; seul le numéro de train reste à côté (`n° 6201`).

## Nommage

Le nom du fichier est construit sur l'`id` du descripteur du réseau, déclaré dans
[`Sources/TrainProvider.swift`](../../Sources/TrainProvider.swift) :

| Fichier | Rôle |
|---|---|
| `logo-sncf.png` | Logo TGV INOUI (`id` = `sncf`) |
| `logo-sncf@2x.png` | Variante Retina (facultative, choisie automatiquement) |
| `logo-sncf-dark.png` | Variante mode sombre (facultative) |
| `logo-sncf-dark@2x.png` | Variante mode sombre Retina (facultative) |
| `logo-eurostar.png` | Logo Eurostar (`id` = `eurostar`) |
| … | même schéma pour chaque réseau |

## Format

- **PNG à fond transparent**, hauteur utile ~40 px (80 px pour le `@2x`). Le logo est rendu sur
  20 pt de haut dans le panneau, la largeur s'ajuste au ratio.
- Le **PDF vectoriel** fonctionne aussi (`logo-sncf.pdf`), sans besoin de variante `@2x`.
- Le SVG n'est **pas** pris en charge : AppKit ne sait pas le charger, et le projet compile
  directement avec `swiftc`, sans *asset catalog* Xcode. Exportez en PNG ou en PDF.

## Variante mode sombre

Elle n'est utile que si le logo est illisible sur fond sombre — c'est le cas du bleu nuit
Eurostar, pas du carmillon SNCF. Sans fichier `-dark`, le logo principal est utilisé dans les deux
apparences.

## Absence de logo

Tout est facultatif, fichier par fichier. Si `logo-<compagnie>.png` n'existe pas, l'en-tête
retombe sur l'icône 🚋 teintée et le nom en toutes lettres — le comportement d'origine. Ces logos
étant des marques déposées, le dépôt peut donc être distribué sans eux, sans aucune modification
de code.

## Ajouter une compagnie

1. Ajouter le réseau comme décrit dans la section « Ajouter un réseau » du README : un
   `TrainDataSource` avec son descripteur (`id`, `displayName`, SSID), inscrit dans
   `TrainProviders.all`.
2. Déposer `logo-<id>.png` dans ce dossier.

`build.sh` les copie dans le bundle automatiquement.
