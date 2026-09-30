# syntax = docker/dockerfile:1
#
# The docs app dogfoods the gem via `gem "phlex-reactive", path: ".."`, so the
# build context is the REPO ROOT (not docs/): the gem lives at /app and the docs
# app at /app/docs. Build with `docker build -f docs/Dockerfile .` from the repo
# root, or via Kamal's builder `context: ..` + `dockerfile: docs/Dockerfile`.

ARG RUBY_VERSION=3.4.2
FROM ruby:$RUBY_VERSION-slim AS base

ARG BUN_VERSION=1.4.2
ENV BUN_INSTALL="/usr/local/bun"
ENV PATH="/usr/local/bun/bin:$PATH"

WORKDIR /app/docs

ENV BUNDLE_DEPLOYMENT="0" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    BUNDLE_GEMFILE="/app/docs/Gemfile" \
    RAILS_ENV="production"

# libpq for the pg gem (production uses Postgres so the site dogfoods pgbus).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libpq5 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

RUN gem update --system --no-document && gem install -N bundler


# --- Build stage --------------------------------------------------------------
FROM base AS build

# build-essential + libpq-dev/libyaml-dev to compile native gems (pg, etc.);
# git so the gem's gemspec (`git ls-files`) resolves the path dependency;
# unzip for the Bun installer.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential curl git libpq-dev libyaml-dev pkg-config unzip

# Bun runs the Tailwind CSS v4 CLI (bun run build:css) — the canonical CSS build
# shared with the daisyUI docs site (no tailwindcss-rails).
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v${BUN_VERSION}"

# Copy the WHOLE repo first (gem at /app, app at /app/docs) — the gem is a path
# dependency whose gemspec runs `git ls-files`, so it needs the full checkout
# (incl. .git) present before bundle install resolves it.
COPY . /app/

# Frozen is off: the path-gem's git-ls-files gemspec digest can't be pinned
# across commits (see the CI note); the lock still pins every other gem.
# Prune the bundler cache + any git-sourced gem checkouts afterwards so they
# don't bloat the layer the final stage copies.
RUN bundle config set frozen false && bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# Install JS deps (Tailwind CLI + daisyUI). assets:precompile is enhanced by the
# css:build rake task (lib/tasks/build_css.rake), so it runs `bun run build:css`
# — which shells to bin/build-css, resolving the daisyui + docs-kit gem @source
# globs from `bundle show` — before propshaft fingerprints application.css.
RUN bun install --frozen-lockfile
# Drop node_modules + the bun/asset caches after the precompile — only the built
# CSS is kept, so the final stage's COPY of /app never carries the JS deps.
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile && \
    rm -rf node_modules /usr/local/bun tmp/cache


# --- Final stage --------------------------------------------------------------
FROM base

# Kamal verifies this `service` label on deploy; it MUST equal `service:` in
# config/deploy.yml (= the repo name, phlex-reactive, so the ghcr package links
# to the repo). The reusable deploy workflow also stamps it via
# docker/build-push-action, but keep it here so a plain `docker build` produces a
# Kamal-deployable image too.
LABEL service="phlex-reactive"

# curl for the healthcheck; libpq5 (Postgres client lib) is already in `base`.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /app /app

# Non-root runtime user; owns the writable dirs.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R 1000:1000 /app/docs/log /app/docs/tmp /app/docs/storage
USER 1000:1000

# DATABASE_URL is injected by Kamal from the postgres accessory at runtime.

ENTRYPOINT ["/app/docs/bin/docker-entrypoint"]

EXPOSE 3000
# Thruster fronts Puma (HTTP caching + compression + X-Sendfile). It listens on
# HTTP_PORT and proxies to Puma on TARGET_PORT (it sets PORT for the child, which
# config/puma.rb reads). HTTP_PORT MUST be the port traffic is routed to (Kamal's
# `app_port: 3000` in config/deploy.yml, the EXPOSE above) — Thruster's default
# is 80, which the non-root user can't reliably bind AND which kamal-proxy would
# never route to, silently bypassing Thruster straight into Puma.
ENV HTTP_PORT="3000" \
    TARGET_PORT="3001"
CMD ["./bin/thrust", "./bin/rails", "server"]
