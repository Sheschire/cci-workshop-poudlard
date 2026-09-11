# Hogwarts Points — Kotlin / Ktor / PostgreSQL

Application mobile Android native permettant à Dumbledore de gérer les points des quatre maisons :
Gryffondor, Serpentard, Poufsouffle et Serdaigle.

## Architecture

```text
Android (Kotlin + Jetpack Compose)
        │
        │ HTTP / JSON
        ▼
API REST (Ktor)
        │
        │ JDBC / Exposed
        ▼
PostgreSQL
```

Le projet n'utilise aucun BaaS.

## Fonctionnalités

- Affichage du classement des 4 maisons
- Ajout de points positifs ou négatifs
- Motif obligatoire côté API, optionnel dans l'interface
- Historique des actions
- Annulation de la dernière action
- Réinitialisation protégée de la coupe
- API REST documentée avec OpenAPI
- PostgreSQL lancé avec Docker Compose
- Tests unitaires côté API
- Tests unitaires côté Android
- Rapport de couverture Kover avec seuil à 80 %

## Prérequis

- JDK 17
- Android Studio Koala ou plus récent
- Android SDK 35
- Docker + Docker Compose
- Gradle 8.10+

## Lancer PostgreSQL

```bash
docker compose up -d db
```

Base :
- host: `localhost`
- port: `5432`
- database: `hogwarts`
- user: `hogwarts`
- password: `hogwarts_dev`

## Lancer l'API

```bash
./gradlew :server:run
```

L'API écoute sur `http://localhost:8080`.

Swagger UI :
`http://localhost:8080/swagger`

## Lancer l'application Android

Ouvrir le projet dans Android Studio puis lancer `app`.

Pour l'émulateur Android, l'API locale est accessible via :

```text
http://10.0.2.2:8080
```

Sur un téléphone physique, remplacer l'URL par l'adresse IP locale du PC.

## Tests

API :

```bash
./gradlew :server:test
```

Android :

```bash
./gradlew :app:testDebugUnitTest
```

Couverture API :

```bash
./gradlew :server:koverHtmlReport
```

Le rapport est généré dans :

```text
server/build/reports/kover/html/
```

Le build possède un seuil de couverture de 80 % sur le code métier du serveur.

## API

### GET /api/houses

Retourne les quatre maisons avec leur score.

### GET /api/scores

Retourne l'historique des mouvements de points.

### POST /api/scores

```json
{
  "houseId": 1,
  "points": 10,
  "reason": "Bonne réponse en cours"
}
```

### DELETE /api/scores/last

Annule la dernière opération.

### POST /api/scores/reset

Réinitialise les scores.

## Choix techniques

### Android
- Kotlin
- Jetpack Compose
- Material 3
- ViewModel
- Kotlin Coroutines
- Ktor Client
- kotlinx.serialization

### API
- Kotlin
- Ktor
- kotlinx.serialization
- Exposed
- PostgreSQL
- HikariCP

### Tests
- JUnit 5
- kotlinx-coroutines-test
- Ktor testApplication
- Kover

## Sécurité

Pour une vraie mise en production :
- déplacer les secrets PostgreSQL vers des variables d'environnement/secrets
- activer HTTPS
- ajouter une authentification Dumbledore/admin
- journaliser les opérations
- protéger `/reset` et `/scores/last`
- ajouter des migrations Flyway
- limiter le débit de l'API

Les mots de passe présents dans `docker-compose.yml` sont uniquement destinés au développement local.

## Assets

Aucun logo ou visuel officiel Harry Potter n'est inclus. Pour une livraison publique,
utiliser des assets dont les droits sont maîtrisés.
