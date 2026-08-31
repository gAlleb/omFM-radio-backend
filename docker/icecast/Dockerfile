# Stage 1: Builder
FROM debian:trixie-slim as builder

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    build-essential \
    ca-certificates \
    gettext \
    git \
    libtool \
    make \
    pkg-config \
    # Icecast Dependencies
    libcurl4-openssl-dev \
    libogg-dev \
    libspeex-dev \
    libssl-dev \
    libtheora-dev \
    libvorbis-dev \
    libxml2-dev \
    libxslt1-dev \
    librhash-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# 1. Build libigloo from source (to get version >= 0.9.4)
RUN git clone --recursive https://gitlab.xiph.org/xiph/icecast-libigloo.git
WORKDIR /build/icecast-libigloo
RUN ./autogen.sh

RUN ./configure --prefix=/usr
RUN make 
RUN make install DESTDIR=/build/output
RUN make install

# 2. Build Icecast
WORKDIR /build
RUN git clone --recursive https://gitlab.xiph.org/xiph/icecast-server.git
WORKDIR /build/icecast-server
RUN ./autogen.sh 

RUN ./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var 

RUN make 
RUN make install DESTDIR=/build/output

# Stage 2: Runtime
FROM debian:trixie-slim

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates media-types tzdata adduser \
    libcurl4t64 libogg0 libspeex1 libssl3 libtheora0 \
    libvorbis0a libxml2 libxslt1.1 librhash1 \
    && rm -rf /var/lib/apt/lists/*

ENV USER=icecast
ENV TZ=UTC

RUN adduser --disabled-password --gecos '' --no-create-home $USER

# Copy everything built in the builder stage (Icecast + libigloo)
COPY --from=builder /build/output /

# Setup configuration and paths
# (Ensure these files exist in your local ./docker/icecast/config/ directory)
COPY ./docker/icecast/config/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
COPY ./docker/icecast/config/xml-edit.sh /usr/local/bin/xml-edit
RUN chmod +x /usr/local/bin/docker-entrypoint /usr/local/bin/xml-edit

COPY ./docker/icecast/config/icecast.xml /etc/icecast.xml
RUN xml-edit errorlog - /etc/icecast.xml || true

RUN mkdir -p /var/log/icecast && \
    chown -R $USER:$USER /var/log/icecast /etc/icecast.xml

# If these files don't exist in your local context, the build will fail here:
COPY ./docker/icecast/config/concat-om.pem /usr/share/icecast/
COPY ./docker/icecast/web /usr/share/icecast/web
COPY ./docker/icecast/config/style.css /usr/share/icecast/web/assets/css/style.css

EXPOSE 8000
ENTRYPOINT ["docker-entrypoint"]
USER $USER
CMD ["icecast", "-c", "/etc/icecast.xml"]
