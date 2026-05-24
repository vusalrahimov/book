#!/usr/bin/env bash
# =============================================================================
# Dependency checker for the book build pipeline
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; }
info() { echo -e "${BLUE}ℹ${NC} $*"; }

ERRORS=0
WARNINGS=0

check_command() {
    local cmd="$1"
    local name="${2:-$cmd}"
    local install_hint="${3:-}"
    local required="${4:-true}"

    if command -v "$cmd" >/dev/null 2>&1; then
        local version
        version=$(${cmd} --version 2>/dev/null | head -1 || echo "unknown version")
        ok "$name — $version"
        return 0
    else
        if [[ "$required" == "true" ]]; then
            fail "$name — NOT FOUND"
            [[ -n "$install_hint" ]] && echo "      Install: $install_hint"
            ERRORS=$((ERRORS + 1))
        else
            warn "$name — not found (optional)"
            [[ -n "$install_hint" ]] && echo "      Install: $install_hint"
            WARNINGS=$((WARNINGS + 1))
        fi
        return 1
    fi
}

check_java_version() {
    if command -v java >/dev/null 2>&1; then
        local version
        version=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d'.' -f1)
        if [[ -n "$version" ]] && [[ "$version" -ge 21 ]]; then
            ok "Java — $(java -version 2>&1 | head -1)"
        else
            warn "Java — found but version < 21 (found: $version). Java 21+ recommended for virtual threads"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        warn "Java — not found (optional, needed for PlantUML JAR)"
        WARNINGS=$((WARNINGS + 1))
    fi
}

check_pandoc_version() {
    if command -v pandoc >/dev/null 2>&1; then
        local version
        version=$(pandoc --version | head -1 | awk '{print $2}')
        local major
        major=$(echo "$version" | cut -d'.' -f1)
        if [[ "$major" -ge 3 ]]; then
            ok "pandoc — $version"
        else
            warn "pandoc — $version found, but 3.x+ recommended"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        fail "pandoc — NOT FOUND"
        echo "      Install: https://pandoc.org/installing.html  OR  brew install pandoc"
        ERRORS=$((ERRORS + 1))
    fi
}

check_python_pkg() {
    local pkg="$1"
    local import_name="${2:-$pkg}"
    if python3 -c "import $import_name" 2>/dev/null; then
        ok "Python pkg: $pkg"
    else
        warn "Python pkg: $pkg — not installed (pip install $pkg)"
        WARNINGS=$((WARNINGS + 1))
    fi
}

# =============================================================================
echo ""
echo "╔════════════════════════════════════════╗"
echo "║  Book Build — Dependency Check         ║"
echo "╚════════════════════════════════════════╝"
echo ""

# ── Core build tools ──────────────────────────────────────────────────────────
echo "── Core PDF Pipeline ──────────────────────────────────────────────────────"
check_pandoc_version
check_command "xelatex" "XeLaTeX" "brew install --cask mactex  OR  apt-get install texlive-xetex"
check_command "xetex" "xetex (verify)" "" "false"

echo ""
echo "── Diagram Rendering ───────────────────────────────────────────────────────"
check_command "mmdc" "mermaid-cli (mmdc)" "npm install -g @mermaid-js/mermaid-cli"
check_command "plantuml" "PlantUML" "brew install plantuml  OR  apt-get install plantuml" "false"
check_java_version

echo ""
echo "── Syntax Highlighting ─────────────────────────────────────────────────────"
check_command "python3" "Python 3" "brew install python3"
if command -v python3 >/dev/null 2>&1; then
    check_python_pkg "pygments" "pygments"
fi

echo ""
echo "── Node.js Ecosystem ───────────────────────────────────────────────────────"
check_command "node" "Node.js" "brew install node  OR  https://nodejs.org" "false"
check_command "npm" "npm" "Included with Node.js" "false"

echo ""
echo "── Container Tools (for docker target) ────────────────────────────────────"
check_command "docker" "Docker" "https://docs.docker.com/get-docker/" "false"
check_command "docker-compose" "docker-compose" "brew install docker-compose" "false"

echo ""
echo "── LaTeX Packages ─────────────────────────────────────────────────────────"
# Check for key LaTeX packages used in the template
for pkg in xcolor tcolorbox geometry fancyhdr titlesec listings fontspec; do
    if command -v kpsewhich >/dev/null 2>&1; then
        if kpsewhich "${pkg}.sty" >/dev/null 2>&1; then
            ok "LaTeX: $pkg.sty"
        else
            warn "LaTeX: $pkg.sty — missing (install texlive-full or missing TeX package)"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        warn "LaTeX: kpsewhich not found — cannot verify LaTeX packages"
        WARNINGS=$((WARNINGS + 1))
        break
    fi
done

echo ""
echo "── Fonts ───────────────────────────────────────────────────────────────────"
if command -v fc-list >/dev/null 2>&1; then
    if fc-list | grep -qi "IBM Plex Sans"; then
        ok "Font: IBM Plex Sans"
    else
        warn "Font: IBM Plex Sans — not found. PDF will fall back to system font."
        info "  Download: https://github.com/IBM/plex/releases"
        info "  macOS: brew install --cask font-ibm-plex"
        WARNINGS=$((WARNINGS + 1))
    fi

    if fc-list | grep -qi "JetBrains Mono"; then
        ok "Font: JetBrains Mono"
    else
        warn "Font: JetBrains Mono — not found. PDF will fall back to system mono font."
        info "  Download: https://www.jetbrains.com/lp/mono/"
        info "  macOS: brew install --cask font-jetbrains-mono"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    warn "fc-list not found — skipping font check"
    WARNINGS=$((WARNINGS + 1))
fi

# =============================================================================
echo ""
echo "══════════════════════════════════════════════════════════════════════════"
if [[ $ERRORS -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
    echo -e "${GREEN}All dependencies satisfied. Ready to build!${NC}"
elif [[ $ERRORS -eq 0 ]]; then
    echo -e "${YELLOW}${WARNINGS} warning(s). Core build will work; some optional features may be unavailable.${NC}"
else
    echo -e "${RED}${ERRORS} error(s), ${WARNINGS} warning(s). Fix required dependencies before building.${NC}"
    exit 1
fi
echo ""
