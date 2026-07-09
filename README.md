# docker-plumber2

Base Docker images for R web services built with plumber2. Two images are published per R version:

- `<R version>-builder` is for installing packages. It ships R (Posit's build for Debian 13), the compilers and system headers needed to build R packages, and a ready-made library of the packages my plumber2 services use (including my own `auth0r`, installed from its GitHub repo). An application build starts from here and only installs what its own lockfile adds or changes, which usually takes seconds instead of minutes.
- `<R version>-runtime` is for running the service. It ships the same R and only the system libraries the packages need at runtime. No compilers, no build tools: production images stay small.

Both halves of a pair are built together from the same Dockerfile, so they always agree on the R version and system libraries. Example pair: `4.5.3-builder` and `4.5.3-runtime`. There are no `latest` tags: applications pin a full R version and upgrade it deliberately. Existing tags are rebuilt monthly to pick up Debian security updates and newer package versions.

## Using the images

An application image is built in two stages: install packages on the builder, then copy the finished library onto the runtime.

```dockerfile
FROM ghcr.io/ma-riviere/docker-plumber2:4.5.3-builder AS builder
COPY renv.lock /build/renv.lock
RUN Rscript \
    -e '.libPaths(c("/opt/renv-bootstrap", .libPaths()))' \
    -e 'renv::restore(lockfile = "/build/renv.lock", library = Sys.getenv("R_LIBS_SITE"), prompt = FALSE, clean = TRUE)'

FROM ghcr.io/ma-riviere/docker-plumber2:4.5.3-runtime
COPY --from=builder /opt/r-site-library /opt/r-site-library
COPY . /app
USER app
WORKDIR /app
CMD ["Rscript", "entrypoint.R"]
```

Packages already present in the builder at the version the lockfile asks for are kept as-is; the rest are installed from Posit Package Manager binaries. `clean = TRUE` removes anything the lockfile does not list, so the final image contains exactly the locked set.

## Building locally

Build the `verify` stage first: it copies the package library into the runtime image and tries to load every package, which catches a missing system library before the pair is used anywhere.

```sh
docker build --target verify --secret id=github_pat,env=GITHUB_PAT -t docker-plumber2:verify .
docker build --target builder --secret id=github_pat,env=GITHUB_PAT -t ghcr.io/ma-riviere/docker-plumber2:4.5.3-builder .
docker build --target runtime -t ghcr.io/ma-riviere/docker-plumber2:4.5.3-runtime .
```

The builder installs `auth0r` from a private GitHub repository, so building it (or `verify`) requires a `GITHUB_PAT` environment variable holding a token with read access to that repository. The runtime image needs no token. Pass `--build-arg R_VERSION=<version>` to build a different R version than the default.
