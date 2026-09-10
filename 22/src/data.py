"""
Données Harry Potter pour les visualisations.
Sources:
- Word count: https://wordcounter.net/blog/2015/11/23/10922_how-many-words-harry-potter.html
- Dialogues: Analyses des scripts des films
- Autres stats: Estimations basées sur l'analyse narrative
"""

HP_DATA = {
    # Titres des livres
    "books": [
        "L'École des sorciers",
        "La Chambre des secrets",
        "Le Prisonnier d'Azkaban",
        "La Coupe de feu",
        "L'Ordre du Phénix",
        "Le Prince de sang-mêlé",
        "Les Reliques de la mort"
    ],

    # Titres courts pour les graphiques
    "books_short": [
        "Tome 1",
        "Tome 2",
        "Tome 3",
        "Tome 4",
        "Tome 5",
        "Tome 6",
        "Tome 7"
    ],

    # Nombre de mots par livre (CONFIRMÉ)
    "word_count": [76944, 85141, 107253, 190637, 257045, 168923, 198227],

    # Nombre de pages par livre (CONFIRMÉ)
    "pages": [223, 251, 317, 636, 766, 607, 607],

    # Douleur de la cicatrice de Harry (ESTIMÉ)
    "scar_pain": [5, 3, 2, 15, 40, 8, 20],

    # Hermione dit "Mais" (ESTIMÉ)
    "hermione_mais": [25, 30, 35, 50, 70, 45, 55],

    # Dumbledore change le cours de l'histoire (ESTIMÉ)
    "dumbledore_interventions": [3, 2, 3, 4, 5, 7, 3],

    # Rogue mystérieux/dark (ESTIMÉ)
    "snape_dark": [20, 15, 18, 12, 25, 35, 30],

    # Actes moralement/légalement répréhensibles (ESTIMÉ)
    "crimes": [8, 10, 7, 12, 15, 10, 18],

    # Dialogues par personnage (% des dialogues totaux - CONFIRMÉ films)
    "dialogue_distribution": {
        "Harry": 25,
        "Ron": 12,
        "Hermione": 10,
        "Autres masculins": 23,
        "Personnages féminins": 30
    },

    # Détail des actes répréhensibles par catégorie (ESTIMÉ)
    "crimes_detail": {
        "books": ["T1", "T2", "T3", "T4", "T5", "T6", "T7"],
        "categories": {
            "Mise en danger d'enfants": [3, 3, 2, 5, 4, 3, 5],
            "Magie illégale/interdite": [2, 4, 2, 3, 4, 4, 8],
            "Violence/torture": [1, 1, 1, 2, 5, 2, 3],
            "Manipulation mentale": [2, 2, 2, 2, 2, 1, 2]
        }
    }
}

# Calcul des stats normalisées par 100 pages
def get_normalized_stats():
    """Retourne les statistiques normalisées par 100 pages."""
    pages = HP_DATA["pages"]

    return {
        "books": HP_DATA["books_short"],
        "scar_pain_per_100": [round(v / p * 100, 1) for v, p in zip(HP_DATA["scar_pain"], pages)],
        "hermione_mais_per_100": [round(v / p * 100, 1) for v, p in zip(HP_DATA["hermione_mais"], pages)],
        "dumbledore_per_100": [round(v / p * 100, 1) for v, p in zip(HP_DATA["dumbledore_interventions"], pages)],
        "snape_dark_per_100": [round(v / p * 100, 1) for v, p in zip(HP_DATA["snape_dark"], pages)],
        "crimes_per_100": [round(v / p * 100, 1) for v, p in zip(HP_DATA["crimes"], pages)]
    }

# Totaux
TOTALS = {
    "total_words": sum(HP_DATA["word_count"]),  # 1,084,170
    "total_pages": sum(HP_DATA["pages"]),  # 3,407
    "total_scar_pain": sum(HP_DATA["scar_pain"]),  # 93
    "total_hermione_mais": sum(HP_DATA["hermione_mais"]),  # 310
    "total_dumbledore": sum(HP_DATA["dumbledore_interventions"]),  # 27
    "total_snape_dark": sum(HP_DATA["snape_dark"]),  # 155
    "total_crimes": sum(HP_DATA["crimes"])  # 80
}
