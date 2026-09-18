FROM golang:1.22-bookworm AS builder

# Pinned to a release commit: an unpinned clone tracks main HEAD, so the
# Action's behaviour would change underneath consumers with no version signal.
ARG QRLFT_COMMIT=edc20365292418f65865c831f3d1364e62e34801 # v4.0.0
RUN git clone https://github.com/theQRL/qrlft.git /qrlft \
 && git -C /qrlft checkout "${QRLFT_COMMIT}"
WORKDIR /qrlft
RUN go mod download
RUN CGO_ENABLED=0 go build -o qrlft .

FROM debian:bookworm-slim
# jq builds the manifest JSON. Hand-rolling it in shell would mean hand-rolling
# the escaping too, on strings that come from filenames.
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /qrlft/qrlft /qrlft/qrlft
COPY entrypoint.sh build-manifest.sh /qrlft/
RUN chmod +x /qrlft/entrypoint.sh /qrlft/build-manifest.sh

ENTRYPOINT ["/qrlft/entrypoint.sh"]
