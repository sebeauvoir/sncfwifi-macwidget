# CLAUDE.md

Fork de `antvgr/sncfwifi-macwidget` maintenu par sebeauvoir. Widget de barre de menus macOS
(Swift, AppKit + SwiftUI) : la pastille affiche la vitesse du train, relue chaque seconde, avec
la jauge de progression du trajet en dessous.

## Échanges

- Répondre en français, comme les commentaires du code, les commits et le README.
- Commits au format conventionnel en français : `feat(pastille): …`, `fix: …`, `docs: …`,
  `ci: …`. `scripts/release_notes.py` s'en sert pour rédiger le changelog des releases.

## Compiler et tester

- Les sessions cloud tournent sous Linux, sans compilateur Swift : impossible de lancer
  `./build.sh` sur place. La compilation se vérifie via GitHub Actions (build de test, ci-dessous).
- Tout nouveau fichier Swift doit être ajouté à `SWIFT_SOURCES` dans `build.sh` (liste explicite).
- Un nouveau réseau doit implémenter `TrainDataSource`, y compris `fetchLive` (pas de valeur
  par défaut) : voir « Ajouter un réseau » dans le README.

## Processus de livraison

Le workflow `.github/workflows/build.yml` publie une release (tag `vX.Y.Z` incrémenté, avec
`SNCFWifi.zip`) à chaque push sur `main`. Un build lancé à la main depuis une autre branche est
un build de test : le zip est déposé en artefact du run (`SNCFWifi-test-<n°>`, 14 jours), sans
tag ni release.

Pour chaque modification :

1. Travailler sur une branche, jamais directement sur `main`.
2. **Toujours demander à l'utilisateur avant de lancer un build**, même de test : il a souvent
   de nouvelles idées entre-temps. Une fois d'accord, lancer le workflow `build.yml` sur la
   branche (`workflow_dispatch`) et donner le lien direct de l'artefact
   (`actions/runs/<run>/artifacts/<id>`).
3. Ouvrir une pull request vers `main`.
4. Fusionner la pull request seulement quand l'utilisateur le demande, en méthode `rebase`
   (historique linéaire, changelog propre). GitHub supprime alors la branche tout seul
   (« Automatically delete head branches » est activé).
5. Le push sur `main` publie la release suivante : vérifier que le run a réussi et donner le
   lien de la release. Exception : un push qui ne touche que `*.md`, `img/` ou `.gitignore`
   ne déclenche aucun build (`paths-ignore`), ses commits rejoignent le changelog suivant.

## Limites connues des sessions cloud

- Supprimer une release, un tag ou une branche sur GitHub est refusé (outils absents, ou 403
  sur `git push --delete`). Ne pas contourner : le processus ci-dessus évite d'avoir à le faire,
  sinon donner à l'utilisateur les liens et commandes pour le faire lui-même.
- Si les workflows semblent absents (404 au déclenchement), vérifier qu'Actions est activé
  dans l'onglet Actions du dépôt.

## Pistes pour plus tard

- **Socket.IO du WiFi SNCF** : le portail reçoit ses données en temps réel sur
  `wss://wifi.sncf/socket.io/` (namespace `/router/api/pepita`). Événements relevés dans un HAR
  à bord : `gps` (≈ 1 Hz, même contenu que `train/gps`), `connected_devices`, `trainDetails`,
  `trainProgress`, `trainGraph`, `modulesConfiguration`. S'y abonner remplacerait la relecture
  de la vitesse chaque seconde et le cycle complet (aujourd'hui toutes les 5 s).
