# Build and run a full Shoal node (blind mailbox + mixnet).
#   docker build -f deploy/Dockerfile -t shoal-node .
#   docker run -p 5077:5077 -p 5078:5078 -v shoal:/data shoal-node \
#     --advertise-mix your.host:5078 --advertise-provider your.host:5077 \
#     --bootstrap seed.shoal.example:5078
FROM rust:1-slim AS build
WORKDIR /src
COPY . .
RUN cargo build --release -p shoal-relay-server

FROM debian:stable-slim
RUN useradd -r -u 10001 shoal && mkdir /data && chown shoal /data
COPY --from=build /src/target/release/shoal-relay-server /usr/local/bin/shoal-relay-server
USER shoal
VOLUME /data
EXPOSE 5077 5078
# Mailbox on 5077, mix on 5078. Pass --advertise-* + --bootstrap as CMD args.
ENTRYPOINT ["shoal-relay-server", "--listen", "0.0.0.0:5077", \
            "--mix", "0.0.0.0:5078", "--data", "/data"]
