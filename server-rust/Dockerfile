# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: Build (uses full Rust toolchain)
# ─────────────────────────────────────────────────────────────────────────────
FROM rust:1.76-slim-bookworm AS builder

# Install system deps for sqlx native-tls
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Cache dependencies separately (faster rebuilds)
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main(){}' > src/main.rs
RUN cargo build --release 2>/dev/null; rm -rf src

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
