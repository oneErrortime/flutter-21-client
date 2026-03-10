# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: Build (uses full Rust toolchain)
# ─────────────────────────────────────────────────────────────────────────────
# FIX: use 'stable' tag — pinning to 1.88 broke the build because that image
# didn't exist. 'stable' always resolves to the current stable release.
FROM rust:stable-slim-bookworm AS builder

# Install system deps for sqlx native-tls
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# SQLX_OFFLINE=true — sqlx::query!() macros validate against .sqlx/ cache
# instead of a live database. The CI job runs `cargo sqlx prepare` against
# a live DB first, commits the resulting .sqlx/ directory, and Docker just
# uses that cache to compile without needing a database.
ENV SQLX_OFFLINE=true

# Cache dependencies separately (faster rebuilds on code-only changes)
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main(){}' > src/main.rs
RUN cargo build --release 2>/dev/null; rm -rf src

# FIX: copy .sqlx/ BEFORE building — required for SQLX_OFFLINE=true.
# Without this, sqlx::query!() macros can't find their cached type info
# and the build fails with "set SQLX_OFFLINE=true or run cargo sqlx prepare".
COPY .sqlx ./.sqlx

# Build actual source
COPY src ./src
RUN touch src/main.rs && cargo build --release

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: Runtime (minimal distroless image — no shell, no package manager)
# Final image: ~10MB vs ~1GB for the builder
# ─────────────────────────────────────────────────────────────────────────────
FROM gcr.io/distroless/cc-debian12:nonroot

COPY --from=builder /build/target/release/voicecall-server /app/voicecall-server

EXPOSE 3000

# Distroless nonroot user (uid 65532)
USER nonroot:nonroot

ENTRYPOINT ["/app/voicecall-server"]
