FROM ubuntu:22.04

LABEL maintainer="Enterprise Engineering Collective"
LABEL description="Book build environment: Pandoc + XeLaTeX + Mermaid + PlantUML"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # LaTeX
    texlive-xetex \
    texlive-fonts-recommended \
    texlive-fonts-extra \
    texlive-latex-extra \
    texlive-science \
    lmodern \
    # Pandoc
    pandoc \
    # Java (for PlantUML)
    default-jre-headless \
    # Python (for Pygments)
    python3 \
    python3-pip \
    # Node.js (for Mermaid)
    nodejs \
    npm \
    # Fonts
    fonts-ibm-plex \
    fonts-jetbrains-mono \
    # Tools
    wget \
    curl \
    graphviz \
    git \
    make \
    bash \
    && rm -rf /var/lib/apt/lists/*

# Install Mermaid CLI
RUN npm install -g @mermaid-js/mermaid-cli@latest

# Install Pygments (syntax highlighting)
RUN pip3 install --no-cache-dir Pygments

# Install PlantUML
RUN wget -q https://github.com/plantuml/plantuml/releases/latest/download/plantuml.jar \
    -O /usr/local/lib/plantuml.jar && \
    echo '#!/bin/bash\njava -jar /usr/local/lib/plantuml.jar "$@"' > /usr/local/bin/plantuml && \
    chmod +x /usr/local/bin/plantuml

# Install pandoc-crossref filter
RUN wget -q https://github.com/lierdakil/pandoc-crossref/releases/download/v0.3.17.0/pandoc-crossref-Linux.tar.xz \
    -O /tmp/crossref.tar.xz && \
    tar -xf /tmp/crossref.tar.xz -C /usr/local/bin/ && \
    rm /tmp/crossref.tar.xz 2>/dev/null || true

# Install extra LaTeX packages
RUN tlmgr init-usertree 2>/dev/null || true

WORKDIR /book

# Copy fonts
COPY fonts/ /usr/share/fonts/book-fonts/
RUN fc-cache -fv 2>/dev/null || true

ENTRYPOINT ["/book/build.sh"]
CMD ["all"]
