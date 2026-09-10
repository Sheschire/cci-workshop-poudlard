# Méthodologie - Le Procès de J.K. Rowling

## Vue d'ensemble

Ce projet analyse des statistiques de la saga Harry Potter pour créer des visualisations humoristiques. Les données proviennent de sources confirmées et d'estimations raisonnables basées sur l'analyse narrative.

## Sources des données

### Données CONFIRMÉES

#### 1. Nombre de mots et de pages
**Source**: [WordCounter.net - How Many Words are in Harry Potter?](https://wordcounter.net/blog/2015/11/23/10922_how-many-words-harry-potter.html)

| Livre | Mots | Pages |
|-------|------|-------|
| L'École des sorciers | 76,944 | 223 |
| La Chambre des secrets | 85,141 | 251 |
| Le Prisonnier d'Azkaban | 107,253 | 317 |
| La Coupe de feu | 190,637 | 636 |
| L'Ordre du Phénix | 257,045 | 766 |
| Le Prince de sang-mêlé | 168,923 | 607 |
| Les Reliques de la mort | 198,227 | 607 |
| **TOTAL** | **1,084,170** | **3,407** |

Ces chiffres sont basés sur les éditions anglaises.

#### 2. Distribution des dialogues
**Source**: Analyses des scripts des films Harry Potter

- Harry Potter : ~25% de toutes les lignes de dialogue
- Ron Weasley : ~12% (environ la moitié de Harry)
- Hermione Granger : ~10%
- Observation clé : **70% des dialogues sont masculins**

### Données ESTIMÉES

Les estimations suivantes sont basées sur une analyse narrative approfondie, en tenant compte de la progression de l'histoire et des thèmes de chaque livre.

#### 3. Douleur de la cicatrice de Harry

**Méthodologie**: Comptage des moments où la cicatrice de Harry fait mal, basé sur la présence/absence de Voldemort.

| Livre | Occurrences | Justification |
|-------|-------------|---------------|
| Tome 1 | 5 | Premiers contacts avec Voldemort (Quirrell) |
| Tome 2 | 3 | Peu de présence directe de Voldemort |
| Tome 3 | 2 | Pas de Voldemort direct |
| Tome 4 | 15 | Retour de Voldemort, scène du cimetière |
| Tome 5 | 40 | Connexion mentale constante, visions |
| Tome 6 | 8 | Occlumencie, moins de visions directes |
| Tome 7 | 20 | Confrontation finale, Horcruxes |
| **TOTAL** | **93** | |

**Note**: Le pic au Tome 5 correspond à la connexion mentale entre Harry et Voldemort, thème central du livre.

#### 4. Hermione dit "Mais"

**Méthodologie**: Estimation du nombre de fois où Hermione commence une phrase par "Mais" dans des dialogues, reflétant son caractère argumentatif.

| Livre | Occurrences | Par 100 pages |
|-------|-------------|---------------|
| Tome 1 | 25 | 11.2 |
| Tome 2 | 30 | 12.0 |
| Tome 3 | 35 | 11.0 |
| Tome 4 | 50 | 7.9 |
| Tome 5 | 70 | 9.1 |
| Tome 6 | 45 | 7.4 |
| Tome 7 | 55 | 9.1 |
| **TOTAL** | **310** | |

**Note**: Le pic au Tome 5 correspond aux nombreux débats avec Ron et Harry concernant l'Ordre du Phénix et l'armée de Dumbledore.

#### 5. Interventions décisives de Dumbledore

**Méthodologie**: Comptage des moments où Dumbledore intervient de manière à changer significativement le cours de l'histoire (le "puppet master").

| Livre | Interventions | Exemples |
|-------|---------------|----------|
| Tome 1 | 3 | Protection de Harry, miroir du Risèd, intervention finale |
| Tome 2 | 2 | Envoie Fumseck, ferme les yeux sur l'enquête des enfants |
| Tome 3 | 3 | Suggère le Retourneur de Temps, libère Sirius indirectement |
| Tome 4 | 4 | Valide la participation au Tournoi, cache Harry, organise la fuite |
| Tome 5 | 5 | Crée l'Ordre, combat au Ministère, évite l'arrestation |
| Tome 6 | 7 | Révèle les Horcruxes, planifie sa mort, manipule Drago |
| Tome 7 | 3 | Guidance posthume via Snape et les objets légués |
| **TOTAL** | **27** | |

**Note**: Le pic au Tome 6 correspond au climax de la manipulation de Dumbledore, révélé seulement dans le Tome 7.

#### 6. Moments "dark" de Rogue

**Méthodologie**: Comptage des descriptions où Snape est présenté comme sombre, menaçant, ou mystérieux.

| Livre | Occurrences | Contexte |
|-------|-------------|----------|
| Tome 1 | 20 | Suspect principal de l'intrigue |
| Tome 2 | 15 | Rôle réduit |
| Tome 3 | 18 | Tension avec Sirius Black |
| Tome 4 | 12 | Présence minimale |
| Tome 5 | 25 | Leçons d'Occlumencie, conflit ouvert avec Harry |
| Tome 6 | 35 | Révélation du Prince de Sang-Mêlé, mort de Dumbledore |
| Tome 7 | 30 | Révélation finale, rédemption |
| **TOTAL** | **155** | |

#### 7. Actes moralement/légalement répréhensibles

**Méthodologie**: Identification des actes qui seraient considérés comme illégaux ou immoraux dans le monde réel.

**Catégories analysées**:
- Mise en danger d'enfants
- Magie illégale/interdite
- Violence/torture
- Manipulation mentale

| Livre | Total | Exemples |
|-------|-------|----------|
| Tome 1 | 8 | Cerbère devant des enfants, dragon illégal, forêt interdite |
| Tome 2 | 10 | Voiture volante, Polynectar sur mineurs, Lockhart |
| Tome 3 | 7 | Carte du Maraudeur, attaque de Snape par des élèves |
| Tome 4 | 12 | Tournoi mortel, Imperium sur élèves, enlèvement |
| Tome 5 | 15 | Torture (Umbridge), armée illégale, intrusion au Ministère |
| Tome 6 | 10 | Potions non autorisées, Sectumsempra, manipulation |
| Tome 7 | 18 | Vol à Gringotts, Imperium, infiltration, meurtres |
| **TOTAL** | **80** | |

## Normalisation des données

Pour permettre une comparaison équitable entre les livres de longueurs différentes, toutes les statistiques sont également présentées **par 100 pages**.

Formule: `(valeur / nombre_de_pages) * 100`

## Limites de l'étude

1. **Subjectivité**: Les estimations sont basées sur une interprétation narrative qui peut varier selon les lecteurs.

2. **Version linguistique**: Les chiffres de mots/pages sont basés sur les éditions anglaises. Les traductions peuvent varier.

3. **Définitions**: Ce qui constitue un "moment dark" de Rogue ou un "acte répréhensible" reste ouvert à interprétation.

4. **But humoristique**: Ce projet est avant tout une analyse humoristique et ne prétend pas être une étude académique rigoureuse.

## Sources complémentaires

- [Harry Potter Wiki - Fandom](https://harrypotter.fandom.com)
- [FandomWire - Every Time Dumbledore Manipulated Harry](https://fandomwire.com/every-time-dumbledore-manipulated-harry/)
- Analyse narrative personnelle des sept livres

---

*Document créé dans le cadre du Défi 22 : Le Procès de J.K. Rowling*
