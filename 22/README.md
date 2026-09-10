# Défi 22 : Le Procès de J.K. Rowling

Visualisations de données humoristiques sur la saga Harry Potter.

## Concept

Ce projet analyse des statistiques (confirmées et estimées) de la saga Harry Potter pour créer des visualisations révélant les aspects cachés de l'univers de J.K. Rowling :

- Combien de fois la cicatrice de Harry lui fait-elle mal ?
- Combien de fois Hermione dit-elle "Mais" ?
- Dumbledore est-il vraiment un puppet master ?
- Rogue est-il trop mystérieux pour son propre bien ?
- Combien d'actes répréhensibles sont commis dans ces livres pour enfants ?

## Installation

```bash
cd 22
pip install -r requirements.txt
```

## Utilisation

```bash
# Générer tous les graphiques
python src/main.py

# Afficher uniquement les statistiques
python src/main.py --stats

# Stats + graphiques
python src/main.py --all
```

## Graphiques générés

Les visualisations sont sauvegardées dans le dossier `output/` :

| Fichier | Description |
|---------|-------------|
| `01_scar_pain.png` | Douleur de la cicatrice par livre |
| `02_hermione_mais.png` | Fréquence de "Mais" par Hermione |
| `03_dumbledore_interventions.png` | Interventions du puppet master |
| `04_dialogue_distribution.png` | Répartition des dialogues (pie chart) |
| `05_snape_dark.png` | Moments mystérieux de Rogue |
| `06_crimes.png` | Actes répréhensibles (stacked bar) |
| `07_all_normalized.png` | Heatmap normalisée par 100 pages |
| `08_dashboard.html` | Dashboard interactif Plotly |

## Données utilisées

### Confirmées
- Nombre de mots par livre (source: wordcounter.net)
- Distribution des dialogues dans les films (70% masculins)

### Estimées
- Occurrences de douleur de la cicatrice
- Fréquence des "Mais" d'Hermione
- Interventions de Dumbledore
- Moments "dark" de Rogue
- Actes moralement répréhensibles

Voir `docs/methodology.md` pour les détails.

## Structure du projet

```
22/
├── README.md                 # Ce fichier
├── requirements.txt          # Dépendances Python
├── data/                     # (Optionnel) Textes des livres
├── src/
│   ├── data.py              # Données et constantes
│   ├── visualize.py         # Génération des graphiques
│   └── main.py              # Point d'entrée CLI
├── output/                   # Graphiques générés
│   ├── 01_scar_pain.png
│   ├── 02_hermione_mais.png
│   ├── ...
│   └── 08_dashboard.html
└── docs/
    └── methodology.md        # Méthodologie détaillée
```

## Statistiques clés

| Métrique | Total sur 7 livres |
|----------|-------------------|
| Total mots | 1,084,170 |
| Total pages | 3,407 |
| Douleurs cicatrice | 93 |
| Hermione "Mais" | 310 |
| Interventions Dumbledore | 27 |
| Moments Rogue dark | 155 |
| Actes répréhensibles | 80 |

## Disclaimer

Ce projet est une analyse humoristique et ne constitue pas une critique sérieuse de l'œuvre de J.K. Rowling. Les données estimées sont basées sur une interprétation subjective de la saga.

---

*Créé dans le cadre du workshop Harry Potter*
