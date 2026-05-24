#!/usr/bin/env bash
# =============================================================================
# Render all Mermaid and PlantUML diagrams
# =============================================================================

set -euo pipefail

BOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIAGRAMS_DIR="${BOOK_DIR}/diagrams"
OUTPUT_DIR="${BOOK_DIR}/output/diagrams"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}✓${NC} $*"; }
log_skip() { echo -e "${YELLOW}⏭${NC} $*"; }
log_fail() { echo -e "${RED}✗${NC} $*"; }

mkdir -p "${OUTPUT_DIR}"

# ── Mermaid diagrams ──────────────────────────────────────────────────────────
echo "Rendering Mermaid diagrams..."

MERMAID_CONFIG="${BOOK_DIR}/themes/mermaid-config.json"
cat > "${MERMAID_CONFIG}" << 'EOF'
{
  "theme": "neutral",
  "themeVariables": {
    "fontFamily": "IBM Plex Sans, Arial, sans-serif",
    "fontSize": "14px",
    "primaryColor": "#e3f2fd",
    "primaryBorderColor": "#1565c0",
    "primaryTextColor": "#1a1f36",
    "secondaryColor": "#e8f5e9",
    "tertiaryColor": "#fff9c4",
    "background": "#ffffff",
    "mainBkg": "#ffffff",
    "nodeBorder": "#1565c0",
    "clusterBkg": "#f8f9fa"
  },
  "flowchart": {
    "htmlLabels": true,
    "curve": "basis"
  },
  "sequence": {
    "actorFontFamily": "IBM Plex Sans",
    "noteFontFamily": "IBM Plex Sans"
  }
}
EOF

MERMAID_COUNT=0
MERMAID_FAILED=0

find "${DIAGRAMS_DIR}" -name "*.mmd" | sort | while read -r diagram; do
    name=$(basename "${diagram}" .mmd)
    out_svg="${OUTPUT_DIR}/${name}.svg"
    out_png="${OUTPUT_DIR}/${name}.png"

    if command -v mmdc >/dev/null 2>&1; then
        if mmdc \
            --input "${diagram}" \
            --output "${out_svg}" \
            --configFile "${MERMAID_CONFIG}" \
            --backgroundColor white \
            --width 1400 \
            --height 900 \
            2>/dev/null; then
            log_ok "${name}.svg"
            MERMAID_COUNT=$((MERMAID_COUNT + 1))

            # Also generate PNG for PDF embedding
            mmdc \
                --input "${diagram}" \
                --output "${out_png}" \
                --configFile "${MERMAID_CONFIG}" \
                --backgroundColor white \
                --width 1400 \
                --height 900 \
                --scale 2 \
                2>/dev/null || true
        else
            log_fail "Failed: ${name}.mmd"
            MERMAID_FAILED=$((MERMAID_FAILED + 1))
        fi
    else
        log_skip "mmdc not installed — skipping ${name}.mmd"
        log_skip "Install: npm install -g @mermaid-js/mermaid-cli"
        break
    fi
done

echo ""
echo "Mermaid: ${MERMAID_COUNT} rendered, ${MERMAID_FAILED} failed"

# ── PlantUML diagrams ─────────────────────────────────────────────────────────
echo ""
echo "Rendering PlantUML diagrams..."

PLANTUML_COUNT=0
PLANTUML_FAILED=0

find "${DIAGRAMS_DIR}" -name "*.puml" | sort | while read -r diagram; do
    name=$(basename "${diagram}" .puml)

    if command -v plantuml >/dev/null 2>&1; then
        if plantuml -tsvg -o "${OUTPUT_DIR}" "${diagram}" 2>/dev/null; then
            log_ok "${name}.svg"
            PLANTUML_COUNT=$((PLANTUML_COUNT + 1))
        else
            log_fail "Failed: ${name}.puml"
            PLANTUML_FAILED=$((PLANTUML_FAILED + 1))
        fi
    elif command -v java >/dev/null 2>&1 && [[ -f "/usr/local/lib/plantuml.jar" ]]; then
        if java -jar /usr/local/lib/plantuml.jar -tsvg -o "${OUTPUT_DIR}" "${diagram}" 2>/dev/null; then
            log_ok "${name}.svg"
            PLANTUML_COUNT=$((PLANTUML_COUNT + 1))
        else
            log_fail "Failed: ${name}.puml"
            PLANTUML_FAILED=$((PLANTUML_FAILED + 1))
        fi
    else
        log_skip "plantuml not installed — skipping ${name}.puml"
        log_skip "Install: brew install plantuml  OR  apt-get install plantuml"
        break
    fi
done

echo ""
echo "PlantUML: ${PLANTUML_COUNT} rendered, ${PLANTUML_FAILED} failed"
echo ""
echo "Diagrams output: ${OUTPUT_DIR}"
