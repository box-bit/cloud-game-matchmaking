FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y \
    && apt-get install -y software-properties-common \
    && add-apt-repository -y universe \
    && apt-get update -y \
    && apt-get install -y --no-install-recommends redeclipse \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash redeclipse \
    && mkdir -p /home/redeclipse/.redeclipse \
    && chown -R redeclipse:redeclipse /home/redeclipse

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER redeclipse
WORKDIR /home/redeclipse

# SERVER_PORT      UDP port the server listens on (default: 26000)
# MAX_PLAYERS      Max concurrent players (default: 8)
# SERVER_DESC      Name shown in server browser (default: "Cloud Game Server")
# SERVER_PUBLIC    1 = register with master server, 0 = private (default: 0)
# SERVER_PASS      Connection password, empty = no password (default: "")
# TIME_LIMIT       Match duration in seconds (default: 600)
# FRAG_LIMIT       Kills needed to end the match (default: 30)
ENV SERVER_PORT=26000 \
    MAX_PLAYERS=8 \
    SERVER_DESC="Cloud Game Server" \
    SERVER_PUBLIC=0 \
    SERVER_PASS="" \
    TIME_LIMIT=600 \
    FRAG_LIMIT=30

EXPOSE ${SERVER_PORT}/udp

ENTRYPOINT ["/entrypoint.sh"]
