# Build and run a full Aegis node (blind mailbox + mixnet).
#   docker build -f deploy/Dockerfile -t aegis-node .
#   docker run -p 5077:5077 -p 5078:5078 -v aegis:/data aegis-node \
#     --advertise-mix your.host:5078 --advertise-provider your.host:5077 \
#     --bootstrap seed.aegis.example:5078
FROM rust:1-slim AS build
WORKDIR /src
COPY . .
RUN cargo build --release -p aegis-relay-server

FROM debian:stable-slim
RUN useradd -r -u 10001 aegis && mkdir /data && chown aegis /data
COPY --from=build /src/target/release/aegis-relay-server /usr/local/bin/aegis-relay-server
USER aegis
VOLUME /data
EXPOSE 5077 5078
# Mailbox on 5077, mix on 5078. Pass --advertise-* + --bootstrap as CMD args.
ENTRYPOINT ["aegis-relay-server", "--listen", "0.0.0.0:5077", \
            "--mix", "0.0.0.0:5078", "--data", "/data"]
