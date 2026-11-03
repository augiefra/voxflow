#!/usr/bin/env python3
"""Self-contained SVGs for the GitHub README. Standard library only."""

from html import escape
from pathlib import Path


ROOT = Path(__file__).parent
COPY = {
    "fr": {
        "tag": "LA DICTÉE QUI APPREND VOS MOTS",
        "headline": "Parlez. Le texte suit.",
        "sub": "Corrigez un mot. Votre dictionnaire s’enrichit.",
        "mobile_sub": ["Corrigez un mot.", "Votre dictionnaire s’enrichit."],
        "steps": ["DICTEZ", "CORRIGEZ", "C’EST RETENU"],
        "speech": ["Je t’envoie le devis", "facil a beau demain."],
        "correct": ["Directement dans votre texte.", "Comme vous le faites déjà."],
        "learned": "Appris : FacilAbo",
        "remember": ["Une règle locale pour", "les prochaines dictées."],
        "footer": "GRATUIT  ·  SANS COMPTE  ·  SUR VOTRE MAC",
        "mobile_footer": ["GRATUIT  ·  SANS COMPTE", "SUR VOTRE MAC"],
        "download": "Télécharger pour Mac",
        "title": "VoxFlow : dictez, corrigez, enrichissez votre dictionnaire",
    },
    "en": {
        "tag": "DICTATION THAT LEARNS YOUR WORDS",
        "headline": "Speak. The words follow.",
        "sub": "Fix a spelling. Your dictionary grows with you.",
        "mobile_sub": ["Fix a spelling.", "Your dictionary grows with you."],
        "steps": ["SPEAK", "CORRECT", "IT’S LEARNED"],
        "speech": ["Je t’envoie le devis", "facil a beau demain."],
        "correct": ["Right in your text.", "Just as you normally would."],
        "learned": "Learned: FacilAbo",
        "remember": ["A local rule for", "your next dictations."],
        "footer": "FREE  ·  NO ACCOUNT  ·  ON YOUR MAC",
        "mobile_footer": ["FREE  ·  NO ACCOUNT", "ON YOUR MAC"],
        "download": "Download for Mac",
        "title": "VoxFlow: speak, correct, grow your dictionary",
    },
}


def text(x, y, value, size=26, color="#F5F5F3", weight=400, extra=""):
    return (f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" '
            f'font-weight="{weight}" {extra}>{escape(value)}</text>')


def rect(x, y, w, h, fill, radius=20, stroke="none"):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" '
            f'fill="{fill}" stroke="{stroke}"/>')


def wave(x, y, color="#F5F5F3", scale=1):
    bars = []
    for i, height in enumerate([12, 24, 38, 52, 40, 26, 14]):
        bars.append(rect(x + i * 10 * scale, y - height * scale / 2,
                         5 * scale, height * scale, color, 2.5 * scale))
    return "".join(bars)


def svg(body, width, height, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height}" role="img" aria-labelledby="title">\n'
            f'<title id="title">{escape(title)}</title>\n'
            '<g font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif">\n'
            + "\n".join(body) + '\n</g>\n</svg>\n')


def card(x, y, width, height, index, copy, mobile=False):
    parts = [rect(x, y, width, height, "#1B1D20", 22, "#32353A")]
    inset = 32 if mobile else 26
    title_size = 34 if mobile else 26
    body_size = 38 if mobile else 28
    px = x + inset
    parts += [text(px, y + 45, f"0{index + 1}", title_size, "#8D9299", 500),
              text(px + (62 if mobile else 48), y + 45, copy["steps"][index], title_size, "#E5E7EB", 600)]
    if index == 0:
        for i, line in enumerate(copy["speech"]):
            parts.append(text(px, y + 100 + i * (43 if mobile else 37), line, body_size))
        parts += [rect(px, y + 169, 54, 44, "#2A2D32", 10, "#4A4F55"),
                  text(px + 14, y + 198, "fn", 24, "#F5F5F3", 500),
                  wave(px + 80, y + 191, "#D8DADD", 0.65),
                  f'<circle cx="{px + 144}" cy="{y + 191}" r="5" fill="#FF6257"/>']
    elif index == 1:
        parts += [text(px, y + 99, "facil a beau", body_size, "#A6ABB2"),
                  f'<path d="M{px} {y + 89}h{218 if mobile else 160}" stroke="#A6ABB2" stroke-width="2"/>',
                  text(px, y + 144, "FacilAbo", 44 if mobile else 34, "#9BE5B5", 600)]
        for i, line in enumerate(copy["correct"]):
            parts.append(text(px, y + 187 + i * (40 if mobile else 33), line, 34 if mobile else 25, "#B7BDC5"))
    else:
        pill_width = width - inset * 2
        parts += [rect(px, y + 81, pill_width, 54, "#163526", 27, "#2B6345"),
                  f'<path d="M{px + 19} {y + 108}l5 5 10-11" fill="none" '
                  'stroke="#9BE5B5" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>',
                  text(px + 45, y + 116, copy["learned"], 34 if mobile else 26, "#B9F2CB", 500)]
        for i, line in enumerate(copy["remember"]):
            parts.append(text(px, y + 187 + i * (40 if mobile else 34), line, 34 if mobile else 28, "#B7BDC5"))
    return parts


def hero(copy, mobile):
    # Compact layout is designed first; desktop adds a horizontal story.
    width, height = (720, 1360) if mobile else (1440, 728)
    inset = 42 if mobile else 66
    body = [rect(0, 0, width, height, "#111315", 30),
            rect(inset, 42, 58, 58, "#22252A", 16, "#454A50"),
            wave(inset + 14, 71, scale=0.48),
            f'<circle cx="{inset + 46}" cy="54" r="4" fill="#FF6257"/>',
            text(inset + 78, 82, "VoxFlow", 42 if mobile else 36, weight=600)]
    if mobile:
        body += [text(inset, 152, copy["tag"], 34, "#B7BDC5", 500),
                 text(inset, 219, "Parlez." if copy is COPY["fr"] else "Speak.", 62, weight=650),
                 text(inset, 289, "Le texte suit." if copy is COPY["fr"] else "The words follow.", 62, weight=650)]
        for i, line in enumerate(copy["mobile_sub"]):
            body.append(text(inset, 345 + i * 43, line, 36, "#B7BDC5"))
        for i in range(3):
            body.extend(card(inset, 426 + i * 265, width - inset * 2, 245, i, copy, True))
        for i, line in enumerate(copy["mobile_footer"]):
            body.append(text(width / 2, 1272 + i * 46, line, 34, "#B7BDC5", 500,
                             'text-anchor="middle"'))
    else:
        body += [text(width - inset, 81, copy["tag"], 25, "#B7BDC5", 500,
                      'text-anchor="end"'),
                 text(inset, 216, copy["headline"], 72, weight=650),
                 text(inset, 272, copy["sub"], 30, "#B7BDC5")]
        gap = 22
        card_width = (width - inset * 2 - gap * 2) / 3
        for i in range(3):
            body.extend(card(inset + i * (card_width + gap), 326, card_width, 270, i, copy))
        body.append(text(width / 2, 665, copy["footer"], 25, "#B7BDC5", 500,
                         'text-anchor="middle"'))
    return svg(body, width, height, copy["title"])


def button(copy):
    body = [rect(1, 1, 358, 66, "#24292F", 14, "#535960"),
            '<path d="M29 24v18m-7-7 7 7 7-7M19 47h20" fill="none" stroke="#FFFFFF" '
            'stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>',
            text(54, 43, copy["download"], 24, "#FFFFFF", 600)]
    return svg(body, 360, 68, copy["download"])


if __name__ == "__main__":
    for lang, copy in COPY.items():
        for mobile in (True, False):
            suffix = "-mobile" if mobile else ""
            (ROOT / f"voxflow-hero-{lang}{suffix}.svg").write_text(hero(copy, mobile), encoding="utf-8")
        (ROOT / f"download-{lang}.svg").write_text(button(copy), encoding="utf-8")
