ARG R_VERSION=4.6.1
ARG R_VERSION_SHORT=4.6
ARG DEBIAN_NUMERIC=13
ARG DEBIAN_CODENAME=trixie

FROM debian:${DEBIAN_CODENAME}-slim AS base

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tzdata \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Etc/UTC \
    R_LIBS_SITE=/opt/r-site-library

FROM base AS r-deb

ARG R_VERSION
ARG DEBIAN_NUMERIC

RUN curl --fail --location --output /tmp/r.deb \
        "https://cdn.posit.co/r/debian-${DEBIAN_NUMERIC}/pkgs/r-${R_VERSION}_1_$(dpkg --print-architecture).deb" \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/r.deb \
    && ln -s /opt/R/${R_VERSION}/bin/R /usr/local/bin/R \
    && ln -s /opt/R/${R_VERSION}/bin/Rscript /usr/local/bin/Rscript \
    && rm /tmp/r.deb \
    && rm -rf /var/lib/apt/lists/*

FROM r-deb AS builder

ARG R_VERSION
ARG R_VERSION_SHORT
ARG DEBIAN_CODENAME

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libpq-dev \
        libsodium-dev \
        libssl-dev \
        libcurl4-openssl-dev \
        # fs/httpuv PPM binaries link system libuv; renv load-tests packages at install time
        libuv1 \
        libxml2-dev \
        zlib1g-dev \
        pkg-config \
        libfontconfig1-dev \
        libfreetype6-dev \
        libharfbuzz-dev \
        libfribidi-dev \
        libpng-dev \
        libtiff-dev \
        libjpeg-dev \
        libwebp-dev \
    && rm -rf /var/lib/apt/lists/*

# No RENV_CONFIG_REPOS_OVERRIDE: restores must honor the lockfile's dated PPM snapshot.
# No renv cache: restores install real files straight into the site library
# (cache symlinks would break COPY --from, and the cache doubles the image).
ENV RENV_CONFIG_SANDBOX_ENABLED=false \
    RENV_CONFIG_AUTO_SNAPSHOT=false \
    RENV_CONFIG_CACHE_ENABLED=false

# Latest renv, as a PPM binary; it only drives restores (lockfiles pin their own records).
RUN mkdir -p /opt/renv-bootstrap \
    && PPM_LATEST="https://packagemanager.posit.co/cran/__linux__/${DEBIAN_CODENAME}/latest" \
       Rscript -e 'install.packages("renv", lib = "/opt/renv-bootstrap", repos = Sys.getenv("PPM_LATEST"))'

COPY renv/profiles/docker-${R_VERSION_SHORT}/renv.lock /tmp/renv.lock

# The selected lockfile must match the installed R (guards matrix typos pairing
# e.g. R 4.5.3 with the docker-4.6 lockfile)
RUN grep -A2 '"R":' /tmp/renv.lock | grep -q "\"Version\": \"${R_VERSION}\"" \
    || { echo "Lockfile R version does not match R_VERSION=${R_VERSION}"; exit 1; }

# auth0r comes from a private GitHub repo: its install needs a read-scoped PAT,
# passed as a BuildKit secret so it never lands in a layer.
RUN --mount=type=secret,id=github_pat \
    mkdir -p "${R_LIBS_SITE}" \
    && GITHUB_PAT="$(cat /run/secrets/github_pat 2>/dev/null || true)" \
    Rscript -e '.libPaths(c("/opt/renv-bootstrap", .libPaths())); renv::restore(lockfile = "/tmp/renv.lock", library = Sys.getenv("R_LIBS_SITE"), clean = TRUE, prompt = FALSE)' \
    && rm -rf /root/.cache/R

RUN find "${R_LIBS_SITE}" -depth -type d \
        \( -name help -o -name html -o -name doc -o -name tests \) -exec rm -rf {} +

FROM base AS runtime

ARG R_VERSION

COPY --from=r-deb /opt/R/${R_VERSION} /opt/R/${R_VERSION}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        fontconfig \
        libbz2-1.0 \
        libcairo2 \
        libcurl4t64 \
        libdeflate0 \
        libfontconfig1 \
        libfreetype6 \
        libfribidi0 \
        libgfortran5 \
        libglib2.0-0t64 \
        libgomp1 \
        libgssapi-krb5-2 \
        libharfbuzz0b \
        libicu76 \
        libkrb5-3 \
        liblzma5 \
        libopenblas0-pthread \
        libpango-1.0-0 \
        libpangocairo-1.0-0 \
        libpaper-utils \
        libpcre2-8-0 \
        libpng16-16t64 \
        libpq5 \
        libreadline8t64 \
        libsodium23 \
        libtcl8.6 \
        libtiff6 \
        libtirpc3t64 \
        libtinfo6 \
        libtk8.6 \
        libuv1 \
        libwebpmux3 \
        libx11-6 \
        libxml2 \
        libxt6t64 \
        libzstd1 \
        ucf \
        unzip \
        zip \
        zlib1g \
    && ln -s /opt/R/${R_VERSION}/bin/R /usr/local/bin/R \
    && ln -s /opt/R/${R_VERSION}/bin/Rscript /usr/local/bin/Rscript \
    && mkdir -p "${R_LIBS_SITE}" \
    && useradd --system --create-home app \
    && rm -rf /var/lib/apt/lists/*

ENV HOST=0.0.0.0

FROM runtime AS verify

COPY --from=builder ${R_LIBS_SITE} ${R_LIBS_SITE}

RUN Rscript -e 'library_path <- Sys.getenv("R_LIBS_SITE"); packages <- rownames(installed.packages(lib.loc = library_path)); failed <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE, lib.loc = library_path)]; if (length(failed)) stop(paste("Could not load:", paste(failed, collapse = ", ")))'

# Runtime contract: no build tooling, app user exists, library path wired
RUN <<'EOF'
#!/bin/bash
set -eu
for tool in gcc g++ gfortran make git; do
    if command -v "$tool" > /dev/null 2>&1; then
        echo "forbidden tool in runtime: $tool"
        exit 1
    fi
done
id app > /dev/null
[ -d "$R_LIBS_SITE" ]
Rscript -e 'stopifnot(Sys.getenv("R_LIBS_SITE") %in% .libPaths())'
echo "runtime contract OK"
EOF
