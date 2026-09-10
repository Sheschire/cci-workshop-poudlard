#!/usr/bin/env python3
"""
Le Procès de J.K. Rowling - Visualisations de données Harry Potter

Point d'entrée CLI pour générer les visualisations.

Usage:
    python main.py              # Génère tous les graphiques
    python main.py --stats      # Affiche uniquement les statistiques
"""

import argparse
import sys
import os

# Ajouter le dossier src au path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from data import HP_DATA, TOTALS, get_normalized_stats
from visualize import generate_all, setup_output_dir


def print_stats():
    """Affiche les statistiques collectées."""
    print("\n" + "="*60)
    print("    LE PROCÈS DE J.K. ROWLING - STATISTIQUES HARRY POTTER")
    print("="*60 + "\n")

    print("DONNÉES CONFIRMÉES:")
    print("-" * 40)

    print("\nNombre de mots par livre:")
    for book, words, pages in zip(HP_DATA["books"], HP_DATA["word_count"], HP_DATA["pages"]):
        print(f"  {book}: {words:,} mots ({pages} pages)")

    print(f"\n  TOTAL: {TOTALS['total_words']:,} mots sur {TOTALS['total_pages']:,} pages")

    print("\n\nDISTRIBUTION DES DIALOGUES (Films):")
    print("-" * 40)
    for char, pct in HP_DATA["dialogue_distribution"].items():
        bar = "█" * (pct // 2)
        print(f"  {char:20} {pct:3}% {bar}")

    print("\n\nDONNÉES ESTIMÉES:")
    print("-" * 40)

    print("\nDouleur de la cicatrice de Harry:")
    for book, val in zip(HP_DATA["books_short"], HP_DATA["scar_pain"]):
        bar = "█" * (val // 2)
        print(f"  {book}: {val:3} {bar}")
    print(f"  TOTAL: {TOTALS['total_scar_pain']}")

    print("\nHermione dit 'Mais':")
    for book, val in zip(HP_DATA["books_short"], HP_DATA["hermione_mais"]):
        bar = "█" * (val // 3)
        print(f"  {book}: {val:3} {bar}")
    print(f"  TOTAL: {TOTALS['total_hermione_mais']}")

    print("\nInterventions de Dumbledore:")
    for book, val in zip(HP_DATA["books_short"], HP_DATA["dumbledore_interventions"]):
        bar = "█" * val
        print(f"  {book}: {val:3} {bar}")
    print(f"  TOTAL: {TOTALS['total_dumbledore']}")

    print("\nRogue mystérieux/menaçant:")
    for book, val in zip(HP_DATA["books_short"], HP_DATA["snape_dark"]):
        bar = "█" * (val // 2)
        print(f"  {book}: {val:3} {bar}")
    print(f"  TOTAL: {TOTALS['total_snape_dark']}")

    print("\nActes moralement répréhensibles:")
    for book, val in zip(HP_DATA["books_short"], HP_DATA["crimes"]):
        bar = "█" * val
        print(f"  {book}: {val:3} {bar}")
    print(f"  TOTAL: {TOTALS['total_crimes']}")

    print("\n" + "="*60)
    print("    Sources: wordcounter.net, Harry Potter Wiki, estimations")
    print("="*60 + "\n")


def main():
    parser = argparse.ArgumentParser(
        description="Le Procès de J.K. Rowling - Visualisations Harry Potter",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemples:
  python main.py              # Génère tous les graphiques
  python main.py --stats      # Affiche les statistiques
  python main.py --all        # Stats + graphiques
        """
    )

    parser.add_argument('--stats', action='store_true',
                        help='Afficher les statistiques sans générer les graphiques')
    parser.add_argument('--visualize', action='store_true',
                        help='Générer uniquement les graphiques')
    parser.add_argument('--all', action='store_true',
                        help='Afficher les stats ET générer les graphiques')

    args = parser.parse_args()

    if args.stats:
        print_stats()
    elif args.visualize or (not args.stats and not args.all):
        generate_all()
    elif args.all:
        print_stats()
        generate_all()


if __name__ == "__main__":
    main()
