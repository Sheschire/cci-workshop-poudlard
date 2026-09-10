"""
Génération des visualisations Harry Potter.
Thème: "Le Procès de J.K. Rowling" - Visualisations humoristiques
"""

import os
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np
import plotly.graph_objects as go
from plotly.subplots import make_subplots
import pandas as pd

from data import HP_DATA, TOTALS, get_normalized_stats

# Configuration du style matplotlib
plt.style.use('seaborn-v0_8-whitegrid')

# Couleurs thème Harry Potter
COLORS = {
    'gryffindor_red': '#740001',
    'gryffindor_gold': '#D3A625',
    'slytherin_green': '#1A472A',
    'slytherin_silver': '#5D5D5D',
    'ravenclaw_blue': '#0E1A40',
    'hufflepuff_yellow': '#FFD800',
    'dark': '#2C2C2C',
    'parchment': '#F5E6C8',
    'gradient_red': ['#FFD1D1', '#FF8888', '#FF4444', '#CC0000', '#8B0000']
}

OUTPUT_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'output')


def setup_output_dir():
    """Crée le dossier output s'il n'existe pas."""
    os.makedirs(OUTPUT_DIR, exist_ok=True)


def style_ax(ax, title, xlabel='', ylabel=''):
    """Applique un style cohérent aux axes."""
    ax.set_title(title, fontsize=14, fontweight='bold', pad=15)
    ax.set_xlabel(xlabel, fontsize=11)
    ax.set_ylabel(ylabel, fontsize=11)
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)


def plot_scar_pain():
    """Graphique 1: Douleur de la cicatrice de Harry par livre."""
    fig, ax = plt.subplots(figsize=(12, 6))

    books = HP_DATA["books_short"]
    values = HP_DATA["scar_pain"]

    # Gradient de rouge basé sur l'intensité
    colors = [plt.cm.Reds(0.3 + (v / max(values)) * 0.7) for v in values]

    bars = ax.bar(books, values, color=colors, edgecolor='darkred', linewidth=1.5)

    # Ajouter les valeurs sur les barres
    for bar, val in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.5,
                str(val), ha='center', va='bottom', fontsize=11, fontweight='bold')

    style_ax(ax, "La cicatrice de Harry fait mal combien de fois?",
             "Livres", "Nombre d'occurrences de douleur")

    # Annotation humoristique
    ax.annotate('Voldemort revient\n(Harry souffre ++)',
                xy=(4, 40), xytext=(5.5, 35),
                arrowprops=dict(arrowstyle='->', color='darkred'),
                fontsize=9, color='darkred')

    plt.tight_layout()
    plt.savefig(os.path.join(OUTPUT_DIR, '01_scar_pain.png'), dpi=150, facecolor='white')
    plt.close()
    print("Graphique créé: 01_scar_pain.png")


def plot_hermione_mais():
    """Graphique 2: Hermione dit 'Mais' par livre."""
    fig, ax = plt.subplots(figsize=(12, 6))

    books = HP_DATA["books_short"]
    values = HP_DATA["hermione_mais"]

    # Couleurs Gryffindor
    bars = ax.bar(books, values, color=COLORS['gryffindor_gold'],
                  edgecolor=COLORS['gryffindor_red'], linewidth=2)

    # Ligne de tendance
    x = np.arange(len(books))
    z = np.polyfit(x, values, 2)
    p = np.poly1d(z)
    ax.plot(x, p(x), '--', color=COLORS['gryffindor_red'], linewidth=2, label='Tendance')

    for bar, val in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 1,
                str(val), ha='center', va='bottom', fontsize=11, fontweight='bold')

    style_ax(ax, 'Hermione dit "Mais..." (argumentative queen)',
             "Livres", "Nombre de 'Mais'")

    ax.legend()

    # Citation
    ax.text(0.02, 0.98, '"Mais Harry, c\'est interdit!"',
            transform=ax.transAxes, fontsize=10, style='italic',
            verticalalignment='top', color=COLORS['gryffindor_red'])

    plt.tight_layout()
    plt.savefig(os.path.join(OUTPUT_DIR, '02_hermione_mais.png'), dpi=150, facecolor='white')
    plt.close()
    print("Graphique créé: 02_hermione_mais.png")


def plot_dumbledore_interventions():
    """Graphique 3: Dumbledore - Le puppet master."""
    fig, ax = plt.subplots(figsize=(12, 6))

    books = HP_DATA["books_short"]
    values = HP_DATA["dumbledore_interventions"]

    # Couleurs mystérieuses (bleu/violet)
    colors = plt.cm.Purples(np.linspace(0.4, 0.9, len(values)))

    bars = ax.bar(books, values, color=colors, edgecolor='indigo', linewidth=1.5)

    for bar, val in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.1,
                str(val), ha='center', va='bottom', fontsize=11, fontweight='bold')

    style_ax(ax, "Dumbledore: Le Puppet Master",
             "Livres", "Interventions qui changent tout")

    # Annotation sur le tome 6
    ax.annotate('Plan de sa propre mort\n+ manipulation de Drago',
                xy=(5, 7), xytext=(3, 6),
                arrowprops=dict(arrowstyle='->', color='indigo'),
                fontsize=9, color='indigo')

    plt.tight_layout()
    plt.savefig(os.path.join(OUTPUT_DIR, '03_dumbledore_interventions.png'), dpi=150, facecolor='white')
    plt.close()
    print("Graphique créé: 03_dumbledore_interventions.png")


def plot_dialogue_distribution():
    """Graphique 4: Distribution des dialogues (pie chart)."""
    fig, ax = plt.subplots(figsize=(10, 8))

    labels = list(HP_DATA["dialogue_distribution"].keys())
    sizes = list(HP_DATA["dialogue_distribution"].values())

    colors = [COLORS['gryffindor_red'], COLORS['gryffindor_gold'],
              '#8B4513', COLORS['slytherin_green'], COLORS['ravenclaw_blue']]

    explode = (0.05, 0.02, 0.02, 0, 0)  # Mettre Harry en avant

    wedges, texts, autotexts = ax.pie(sizes, labels=labels, autopct='%1.1f%%',
                                       startangle=90, colors=colors, explode=explode,
                                       shadow=True)

    # Style du texte
    for autotext in autotexts:
        autotext.set_color('white')
        autotext.set_fontweight('bold')

    ax.set_title("Qui parle dans Harry Potter?\n(Distribution des dialogues - Films)",
                 fontsize=14, fontweight='bold')

    # Annotation
    ax.text(0, -1.4, "70% des dialogues sont masculins",
            ha='center', fontsize=11, style='italic', color='gray')

    plt.tight_layout()
    plt.savefig(os.path.join(OUTPUT_DIR, '04_dialogue_distribution.png'), dpi=150, facecolor='white')
    plt.close()
    print("Graphique créé: 04_dialogue_distribution.png")


def plot_snape_dark():
    """Graphique 5: Rogue - Moments mystérieux/dark."""
    fig, ax = plt.subplots(figsize=(12, 6))

    books = HP_DATA["books_short"]
    values = HP_DATA["snape_dark"]

    # Palette sombre
    colors = plt.cm.Greys(np.linspace(0.5, 0.9, len(values)))

    bars = ax.bar(books, values, color=colors, edgecolor='black', linewidth=1.5)

    for bar, val in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.5,
                str(val), ha='center', va='bottom', fontsize=11, fontweight='bold')

    style_ax(ax, "Rogue: Combien de fois est-il mystérieux/menaçant?",
             "Livres", "Moments 'dark'")

    # Fond légèrement sombre
    ax.set_facecolor('#F0F0F0')

    # Annotation
    ax.annotate('Le Prince de Sang-Mêlé\n+ Mort de Dumbledore',
                xy=(5, 35), xytext=(3, 32),
                arrowprops=dict(arrowstyle='->', color='black'),
                fontsize=9, color='black')

    plt.tight_layout()
    plt.savefig(os.path.join(OUTPUT_DIR, '05_snape_dark.png'), dpi=150, facecolor='white')
    plt.close()
    print("Graphique créé: 05_snape_dark.png")


def plot_crimes():
    """Graphique 6: Actes moralement/légalement répréhensibles (stacked bar)."""
    fig, ax = plt.subplots(figsize=(14, 7))

    data = HP_DATA["crimes_detail"]
    books = data["books"]
    categories = data["categories"]

    x = np.arange(len(books))
    width = 0.6

    # Couleurs par catégorie
    cat_colors = {
        "Mise en danger d'enfants": '#FF6B6B',
        "Magie illégale/interdite": '#4ECDC4',
        "Violence/torture": '#8B0000',
        "Manipulation mentale": '#9B59B6'
    }

    bottom = np.zeros(len(books))

    for cat_name, cat_values in categories.items():
        bars = ax.bar(x, cat_values, width, label=cat_name,
                      bottom=bottom, color=cat_colors[cat_name],
                      edgecolor='white', linewidth=0.5)
        bottom += np.array(cat_values)

    # Totaux au-dessus
    for i, total in enumerate(HP_DATA["crimes"]):
        ax.text(i, total + 0.5, str(total), ha='center', va='bottom',
                fontsize=11, fontweight='bold')

    ax.set_xticks(x)
    ax.set_xticklabels(books)

    style_ax(ax, "Actes moralement/légalement répréhensibles dans Harry Potter",
             "Livres", "Nombre d'actes")

    ax.legend(loc='upper left', framealpha=0.9)

    # Commentaire
    ax.text(0.98, 0.02, "Poudlard violerait toutes les\nnormes de sécurité modernes",
            transform=ax.transAxes, ha='right', va='bottom',
            fontsize=9, style='italic', color='gray')

    plt.tight_layout()
    plt.savefig(os.path.join(OUTPUT_DIR, '06_crimes.png'), dpi=150, facecolor='white')
    plt.close()
    print("Graphique créé: 06_crimes.png")


def plot_normalized_heatmap():
    """Graphique 7: Heatmap des stats normalisées par 100 pages."""
    fig, ax = plt.subplots(figsize=(12, 8))

    normalized = get_normalized_stats()

    # Créer la matrice de données
    data_matrix = np.array([
        normalized["scar_pain_per_100"],
        normalized["hermione_mais_per_100"],
        normalized["dumbledore_per_100"],
        normalized["snape_dark_per_100"],
        normalized["crimes_per_100"]
    ])

    # Normaliser pour la visualisation (0-1 par ligne)
    data_normalized = (data_matrix - data_matrix.min(axis=1, keepdims=True)) / \
                      (data_matrix.max(axis=1, keepdims=True) - data_matrix.min(axis=1, keepdims=True) + 0.001)

    labels_y = [
        "Douleur cicatrice",
        "Hermione 'Mais'",
        "Interventions Dumbledore",
        "Rogue mystérieux",
        "Actes répréhensibles"
    ]

    im = ax.imshow(data_normalized, cmap='YlOrRd', aspect='auto')

    # Ticks
    ax.set_xticks(np.arange(len(normalized["books"])))
    ax.set_yticks(np.arange(len(labels_y)))
    ax.set_xticklabels(normalized["books"])
    ax.set_yticklabels(labels_y)

    # Rotation des labels x
    plt.setp(ax.get_xticklabels(), rotation=45, ha="right", rotation_mode="anchor")

    # Valeurs dans les cellules
    for i in range(len(labels_y)):
        for j in range(len(normalized["books"])):
            text = ax.text(j, i, f'{data_matrix[i, j]:.1f}',
                          ha="center", va="center", color="black", fontsize=10)

    ax.set_title("Statistiques normalisées par 100 pages\n(Intensité relative)",
                 fontsize=14, fontweight='bold')

    # Colorbar
    cbar = ax.figure.colorbar(im, ax=ax, shrink=0.8)
    cbar.ax.set_ylabel("Intensité relative", rotation=-90, va="bottom")

    plt.tight_layout()
    plt.savefig(os.path.join(OUTPUT_DIR, '07_all_normalized.png'), dpi=150, facecolor='white')
    plt.close()
    print("Graphique créé: 07_all_normalized.png")


def create_dashboard():
    """Graphique 8: Dashboard interactif avec Plotly."""

    fig = make_subplots(
        rows=3, cols=2,
        subplot_titles=(
            "Douleur de la cicatrice de Harry",
            "Hermione dit 'Mais'",
            "Dumbledore: Le Puppet Master",
            "Rogue: Moments mystérieux",
            "Actes répréhensibles",
            "Distribution des dialogues"
        ),
        specs=[
            [{"type": "bar"}, {"type": "bar"}],
            [{"type": "bar"}, {"type": "bar"}],
            [{"type": "bar"}, {"type": "pie"}]
        ],
        vertical_spacing=0.12,
        horizontal_spacing=0.1
    )

    books = HP_DATA["books_short"]

    # 1. Cicatrice
    fig.add_trace(
        go.Bar(x=books, y=HP_DATA["scar_pain"], name="Douleur cicatrice",
               marker_color='crimson'),
        row=1, col=1
    )

    # 2. Hermione
    fig.add_trace(
        go.Bar(x=books, y=HP_DATA["hermione_mais"], name="Hermione 'Mais'",
               marker_color='gold'),
        row=1, col=2
    )

    # 3. Dumbledore
    fig.add_trace(
        go.Bar(x=books, y=HP_DATA["dumbledore_interventions"], name="Dumbledore",
               marker_color='purple'),
        row=2, col=1
    )

    # 4. Rogue
    fig.add_trace(
        go.Bar(x=books, y=HP_DATA["snape_dark"], name="Rogue dark",
               marker_color='dimgray'),
        row=2, col=2
    )

    # 5. Crimes
    fig.add_trace(
        go.Bar(x=books, y=HP_DATA["crimes"], name="Actes répréhensibles",
               marker_color='darkred'),
        row=3, col=1
    )

    # 6. Dialogues pie chart
    fig.add_trace(
        go.Pie(labels=list(HP_DATA["dialogue_distribution"].keys()),
               values=list(HP_DATA["dialogue_distribution"].values()),
               hole=0.3),
        row=3, col=2
    )

    # Mise en forme
    fig.update_layout(
        title_text="Le Procès de J.K. Rowling - Dashboard des Statistiques Harry Potter",
        title_x=0.5,
        title_font_size=20,
        showlegend=False,
        height=900,
        template="plotly_white"
    )

    # Sauvegarder en HTML
    output_path = os.path.join(OUTPUT_DIR, '08_dashboard.html')
    fig.write_html(output_path)
    print(f"Dashboard créé: 08_dashboard.html")


def generate_all():
    """Génère tous les graphiques."""
    setup_output_dir()
    print("Génération des visualisations Harry Potter...\n")

    plot_scar_pain()
    plot_hermione_mais()
    plot_dumbledore_interventions()
    plot_dialogue_distribution()
    plot_snape_dark()
    plot_crimes()
    plot_normalized_heatmap()
    create_dashboard()

    print(f"\nTous les graphiques ont été générés dans: {OUTPUT_DIR}")
    print(f"\nStatistiques totales:")
    print(f"  - Total mots: {TOTALS['total_words']:,}")
    print(f"  - Total pages: {TOTALS['total_pages']:,}")
    print(f"  - Douleurs cicatrice: {TOTALS['total_scar_pain']}")
    print(f"  - Hermione 'Mais': {TOTALS['total_hermione_mais']}")
    print(f"  - Interventions Dumbledore: {TOTALS['total_dumbledore']}")
    print(f"  - Rogue mystérieux: {TOTALS['total_snape_dark']}")
    print(f"  - Actes répréhensibles: {TOTALS['total_crimes']}")


if __name__ == "__main__":
    generate_all()
