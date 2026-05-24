#!/usr/bin/env bash
# =============================================================================
# Enterprise Java & Distributed Systems Engineering — Book Build Script
# =============================================================================
# Usage:
#   ./build.sh           — full build (diagrams + PDF)
#   ./build.sh pdf       — PDF only (skip diagram rendering)
#   ./build.sh diagrams  — render diagrams only
#   ./build.sh clean     — clean build artifacts
#   ./build.sh check     — check dependencies
#   ./build.sh docker    — build inside Docker (no local deps required)
# =============================================================================

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
BOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer local mmdc (avoids snap Chromium sandbox restrictions on /usr/lib/...)
if [[ -x "${BOOK_DIR}/node_modules/.bin/mmdc" ]]; then
    MMDC="${BOOK_DIR}/node_modules/.bin/mmdc"
else
    MMDC="mmdc"
fi

OUTPUT_DIR="${BOOK_DIR}/output"
CHAPTERS_DIR="${BOOK_DIR}/chapters"
DIAGRAMS_DIR="${BOOK_DIR}/diagrams"
IMAGES_DIR="${BOOK_DIR}/images"
THEMES_DIR="${BOOK_DIR}/themes"
SCRIPTS_DIR="${BOOK_DIR}/scripts"
METADATA="${BOOK_DIR}/metadata.yaml"
BOOK_MD="${BOOK_DIR}/book.md"
OUTPUT_PDF="${OUTPUT_DIR}/enterprise-java-distributed-systems.pdf"
OUTPUT_HTML="${OUTPUT_DIR}/enterprise-java-distributed-systems.html"
LOG_FILE="${OUTPUT_DIR}/build.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ── Logging ───────────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}\n"; }

# ── Dependency Check ──────────────────────────────────────────────────────────
check_dependencies() {
    log_step "Checking Dependencies"

    local missing=()

    command -v pandoc   >/dev/null 2>&1 || missing+=("pandoc")
    command -v xelatex  >/dev/null 2>&1 || missing+=("xelatex (texlive-xetex)")
    command -v "${MMDC}" >/dev/null 2>&1 || [[ -x "${MMDC}" ]] || missing+=("mmdc (run: cd ${BOOK_DIR} && npm install @mermaid-js/mermaid-cli)")
    command -v java     >/dev/null 2>&1 || missing+=("java")
    command -v plantuml >/dev/null 2>&1 || log_warn "plantuml not found — PlantUML diagrams will be skipped"
    command -v pygmentize>/dev/null 2>&1 || missing+=("pygmentize (pip install Pygments)")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            echo -e "  ${RED}✗${NC} $dep"
        done
        echo ""
        echo "Install guide:"
        echo "  macOS:  brew install pandoc mermaid-cli plantuml && brew install --cask mactex"
        echo "  Ubuntu: apt-get install pandoc texlive-xetex texlive-fonts-recommended"
        echo "          npm install -g @mermaid-js/mermaid-cli"
        echo "          pip install Pygments"
        echo ""
        echo "Or run: ./build.sh docker"
        exit 1
    fi

    log_success "All dependencies found"
    echo "  pandoc:    $(pandoc --version | head -1)"
    echo "  xelatex:   $(xelatex --version | head -1)"
    echo "  mmdc:      $(${MMDC} --version 2>/dev/null || echo 'ok') [${MMDC}]"
}

# ── Directory Setup ───────────────────────────────────────────────────────────
setup_dirs() {
    mkdir -p "${OUTPUT_DIR}"
    mkdir -p "${OUTPUT_DIR}/diagrams"
    mkdir -p "${OUTPUT_DIR}/images"
}

# ── Diagram Rendering ─────────────────────────────────────────────────────────
render_diagrams() {
    log_step "Rendering Mermaid Diagrams"

    local count=0
    local failed=0

    # Locate a usable Chrome/Chromium executable
    local puppeteer_cfg="${OUTPUT_DIR}/puppeteer-config.json"
    local chrome_exec=""
    for candidate in \
        /usr/bin/chromium \
        /usr/bin/chromium-browser \
        /snap/bin/chromium \
        /usr/bin/google-chrome \
        /usr/bin/google-chrome-stable \
        /usr/local/bin/chromium \
        /usr/local/bin/google-chrome; do
        if [[ -x "${candidate}" ]]; then
            chrome_exec="${candidate}"
            break
        fi
    done

    if [[ -n "${chrome_exec}" ]]; then
        log_info "Chromium found: ${chrome_exec}"
        cat > "${puppeteer_cfg}" <<EOF
{
  "executablePath": "${chrome_exec}",
  "args": ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage", "--disable-gpu"]
}
EOF
    else
        log_warn "No Chrome/Chromium found — trying system default (may fail)"
        log_warn "Fix: apt-get install -y chromium-browser   OR   snap install chromium"
        cat > "${puppeteer_cfg}" <<'EOF'
{
  "args": ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage", "--disable-gpu"]
}
EOF
    fi

    log_info "Puppeteer config: $(cat "${puppeteer_cfg}")"

    find "${DIAGRAMS_DIR}" -name "*.mmd" | while read -r diagram; do
        local name
        name=$(basename "${diagram}" .mmd)
        local out="${OUTPUT_DIR}/diagrams/${name}.svg"
        local err_tmp
        err_tmp=$(mktemp)

        log_info "Rendering: ${name}.mmd → ${name}.svg"
        if "${MMDC}" \
            --input "${diagram}" \
            --output "${out}" \
            --theme neutral \
            --backgroundColor white \
            --width 1200 \
            --height 800 \
            --puppeteerConfigFile "${puppeteer_cfg}" \
            2>"${err_tmp}"; then
            count=$((count + 1))
            log_success "${name}.svg"
        else
            failed=$((failed + 1))
            log_warn "Failed to render ${name}.mmd — error:"
            # Show error inline AND append to log
            while IFS= read -r errline; do
                echo "          ${errline}" >&2
                echo "          ${errline}" >> "${LOG_FILE}"
            done < "${err_tmp}"
        fi
        rm -f "${err_tmp}"
    done

    log_step "Rendering PlantUML Diagrams"

    if command -v plantuml >/dev/null 2>&1; then
        find "${DIAGRAMS_DIR}" -name "*.puml" | while read -r diagram; do
            local name
            name=$(basename "${diagram}" .puml)
            log_info "Rendering: ${name}.puml"
            plantuml -tsvg -o "${OUTPUT_DIR}/diagrams/" "${diagram}" 2>>"${LOG_FILE}" \
                && log_success "${name}.svg" \
                || log_warn "Failed: ${name}.puml"
        done
    fi

    log_success "Diagram rendering complete"
}

# ── Chapter Assembly ──────────────────────────────────────────────────────────
assemble_chapters() {
    log_step "Assembling Chapter Files"

    local combined="${OUTPUT_DIR}/combined.md"
    : > "${combined}"

    # Process book.md — resolve !include directives
    while IFS= read -r line; do
        if [[ "${line}" =~ ^!include\ (.+)$ ]]; then
            local include_file="${BOOK_DIR}/${BASH_REMATCH[1]}"
            if [[ -f "${include_file}" ]]; then
                cat "${include_file}" >> "${combined}"
                echo "" >> "${combined}"
            else
                log_warn "Include not found: ${include_file}"
            fi
        else
            echo "${line}" >> "${combined}"
        fi
    done < "${BOOK_MD}"

    # Replace diagram references to point to rendered SVGs
    sed -i.bak "s|diagrams/|${OUTPUT_DIR}/diagrams/|g" "${combined}" 2>/dev/null || true
    sed -i.bak "s|images/|${BOOK_DIR}/images/|g" "${combined}" 2>/dev/null || true
    rm -f "${combined}.bak"

    log_success "Chapters assembled → ${combined}"
    echo "${combined}"
}

# ── PDF Build ─────────────────────────────────────────────────────────────────
build_pdf() {
    log_step "Building PDF with Pandoc + XeLaTeX"

    local combined="${OUTPUT_DIR}/combined.md"

    if [[ ! -f "${combined}" ]]; then
        combined=$(assemble_chapters)
    fi

    local crossref_filter=()
    if command -v pandoc-crossref >/dev/null 2>&1; then
        crossref_filter=(--filter pandoc-crossref)
    fi

    pandoc \
        "${combined}" \
        --metadata-file="${METADATA}" \
        --template="${THEMES_DIR}/book.latex" \
        --pdf-engine=xelatex \
        --highlight-style=tango \
        --listings \
        --number-sections \
        --toc \
        --toc-depth=3 \
        --top-level-division=chapter \
        --resource-path="${BOOK_DIR}:${OUTPUT_DIR}" \
        --variable=graphics \
        "${crossref_filter[@]}" \
        --output="${OUTPUT_PDF}" \
        2>&1 | tee -a "${LOG_FILE}"

    if [[ -f "${OUTPUT_PDF}" ]]; then
        local size
        size=$(du -sh "${OUTPUT_PDF}" | cut -f1)
        log_success "PDF built: ${OUTPUT_PDF} (${size})"
    else
        log_error "PDF build failed — check ${LOG_FILE}"
        exit 1
    fi
}

# ── HTML Build ────────────────────────────────────────────────────────────────
build_html() {
    log_step "Building HTML"

    local combined="${OUTPUT_DIR}/combined.md"

    pandoc \
        "${combined}" \
        --metadata-file="${METADATA}" \
        --standalone \
        --highlight-style=tango \
        --number-sections \
        --toc \
        --toc-depth=3 \
        --css="${THEMES_DIR}/book.css" \
        --output="${OUTPUT_HTML}" \
        2>&1 | tee -a "${LOG_FILE}"

    log_success "HTML built: ${OUTPUT_HTML}"
}

# ── Docker Build ──────────────────────────────────────────────────────────────
docker_build() {
    log_step "Building via Docker"

    docker build -t book-builder:latest "${BOOK_DIR}"
    docker run --rm \
        -v "${BOOK_DIR}:/book" \
        -v "${OUTPUT_DIR}:/output" \
        book-builder:latest \
        /book/build.sh pdf

    log_success "Docker build complete"
}

# ── Clean ─────────────────────────────────────────────────────────────────────
clean() {
    log_step "Cleaning Build Artifacts"
    rm -rf "${OUTPUT_DIR}"
    log_success "Cleaned"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║   Enterprise Java & Distributed Systems Engineering          ║${NC}"
    echo -e "${BOLD}${CYAN}║   Book Build System v1.0                                     ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local command="${1:-all}"
    setup_dirs

    case "${command}" in
        all)
            check_dependencies
            render_diagrams
            assemble_chapters
            build_pdf
            build_html
            ;;
        pdf)
            check_dependencies
            assemble_chapters
            build_pdf
            ;;
        html)
            check_dependencies
            assemble_chapters
            build_html
            ;;
        diagrams)
            render_diagrams
            ;;
        check)
            check_dependencies
            ;;
        clean)
            clean
            ;;
        docker)
            docker_build
            ;;
        *)
            echo "Usage: $0 [all|pdf|html|diagrams|check|clean|docker]"
            exit 1
            ;;
    esac

    echo ""
    log_success "Build complete! Output: ${OUTPUT_DIR}/"
    echo ""
}

main "$@"
