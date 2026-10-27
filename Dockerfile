# Janus for TrueNAS / Nextcloud Talk — candidate build, NOT an auto-deployment.
# Source: meetecho/janus-gateway (upstream), not a third-party prebuilt image.
FROM ubuntu:24.04
ARG JANUS_REF=v1.4.3
ARG LIBNICE_REF=0.1.23
ARG LIBSRTP_REF=v2.8.0
ARG LWS_REF=v5.0-stable
# usrsctp's moving HEAD is logged into /opt/janus-build-info at build time.
ENV DEBIAN_FRONTEND=noninteractive \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib/x86_64-linux-gnu

RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
      build-essential git ca-certificates curl wget pkg-config libtool automake \
      autoconf cmake meson ninja-build python3-minimal \
      libmicrohttpd-dev libjansson-dev libssl-dev libsofia-sip-ua-dev \
      libglib2.0-dev libopus-dev libogg-dev libcurl4-openssl-dev \
      libconfig-dev zlib1g-dev libavutil-dev libavformat-dev libavcodec-dev \
      liblua5.3-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/local/src
RUN git clone --depth 1 --branch "${LIBNICE_REF}" https://gitlab.freedesktop.org/libnice/libnice.git libnice && \
    meson setup libnice/build libnice --prefix=/usr/local && \
    ninja -C libnice/build -j 2 && ninja -C libnice/build install && ldconfig

# libSRTP with OpenSSL support supplies AES-GCM cipher profiles.
RUN git clone --depth 1 --branch "${LIBSRTP_REF}" https://github.com/cisco/libsrtp.git libsrtp && \
    cd libsrtp && ./configure --prefix=/usr/local --enable-openssl && \
    make -j2 shared_library && make install && ldconfig

# 5.0-stable receives security fixes; Janus compatibility MUST be tested in isolation.
# Not a fully reproducible pin: exact commit is recorded in image build metadata.
RUN git clone --depth 1 --branch "${LWS_REF}" https://github.com/warmcat/libwebsockets.git libwebsockets && \
    mkdir -p /opt/janus-build-info && \
    git -C libwebsockets rev-parse HEAD > /opt/janus-build-info/libwebsockets.commit && \
    cmake -S libwebsockets -B libwebsockets/build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DLWS_WITHOUT_EXTENSIONS=0 \
      -DLWS_MAX_SMP=1 && \
    cmake --build libwebsockets/build --parallel 2 && \
    cmake --install libwebsockets/build && ldconfig

# Compile usrsctp to enable WebRTC Data Channels + TextRoom.
RUN git clone --depth 1 https://github.com/sctplab/usrsctp.git usrsctp && \
    git -C usrsctp rev-parse HEAD > /opt/janus-build-info/usrsctp.commit && \
    cd usrsctp && ./bootstrap && \
    ./configure --prefix=/usr/local --disable-programs --disable-inet --disable-inet6 && \
    make -j2 && make install && ldconfig

RUN git clone --depth 1 --branch "${JANUS_REF}" https://github.com/meetecho/janus-gateway.git janus-gateway && \
    git -C janus-gateway rev-parse HEAD > /opt/janus-build-info/janus.commit && \
    cd janus-gateway && sh autogen.sh && \
    ./configure --prefix=/opt/janus --enable-post-processing && \
    make -j2 && make install && make configs && ldconfig

COPY scripts/harden-defaults.py /usr/local/bin/harden-janus-defaults.py
RUN python3 /usr/local/bin/harden-janus-defaults.py /opt/janus/etc/janus && \
    useradd --system --uid 10001 --user-group --home /nonexistent --shell /usr/sbin/nologin janus && \
    chmod -R a+rX /opt/janus /opt/janus-build-info && \
    mkdir -p /mnt/recordings && chown -R janus:janus /mnt/recordings && \
    chmod -R a-w /opt/janus/etc/janus

LABEL org.opencontainers.image.title="Janus Gateway for Nextcloud Talk" \
      org.opencontainers.image.description="Locally compiled, WebSocket loopback only, Janus 1.4.3 with usrsctp and OpenSSL libSRTP" \
      org.opencontainers.image.version="1.4.3" \
      org.opencontainers.image.source="https://github.com/meetecho/janus-gateway"

WORKDIR /opt/janus
USER 10001:10001
STOPSIGNAL SIGTERM
ENTRYPOINT ["/opt/janus/bin/janus"]
CMD ["-F", "/opt/janus/etc/janus"]
