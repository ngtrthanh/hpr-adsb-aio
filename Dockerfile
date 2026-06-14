# ==============================================================================
# STAGE 1: COMPILE TCLLAUNCHER & PIAWARE ENGINE (CROSS-COMPILING READY)
# ==============================================================================
FROM ghcr.io/sdr-enthusiasts/docker-baseimage:base AS tcl-builder
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    automake build-essential cmake git pkg-config libusb-1.0-0-dev \
    libncurses-dev tcl-dev chrpath devscripts debhelper tcl8.6-dev autoconf libssl-dev \
    libboost-dev libboost-system-dev libboost-program-options-dev libboost-regex-dev
WORKDIR /src
RUN git clone --depth 1 https://github.com/flightaware/tcllauncher.git && \
    cd tcllauncher && autoconf && ./configure --prefix=/opt/tcl && make -j$(nproc) install && \
    TCL_PKG=$(find / -not -path "/proc/*" -path "*/Tcllauncher*" -name "tcllauncher.tcl" 2>/dev/null | head -1) && \
    mkdir -p /opt/tcl/lib/Tcllauncher1.10 && \
    cp -r "$(dirname "$TCL_PKG")/." /opt/tcl/lib/Tcllauncher1.10/
RUN git clone --depth 1 https://github.com/flightaware/piaware.git && \
    cd piaware && make -j$(nproc) install && cp -v package/ca/*.pem /etc/ssl/ && \
    # Consolidate all installed Tcl pkgIndex.tcl directories into /opt/tcl/lib
    # so the single COPY --from=tcl-builder /opt/tcl picks them all up
    find / -not -path "/proc/*" -name "pkgIndex.tcl" 2>/dev/null | while read f; do \
        dir=$(dirname "$f"); base=$(basename "$dir"); \
        mkdir -p /opt/tcl/lib/"$base" && cp -r "$dir/." /opt/tcl/lib/"$base"/; \
    done
RUN git clone --depth 1 https://github.com/flightaware/dump1090.git && \
    cd dump1090 && sed -i -e 's/uname -m/dpkg --print-architecture/' Makefile && make -j$(nproc) faup1090 RTLSDR=yes
RUN git clone --depth 1 https://github.com/flightaware/beast-splitter.git && \
    cd beast-splitter && make -j$(nproc)

# ==============================================================================
# STAGE 2: COMPILE MLAT EXTENSIONS
# ==============================================================================
FROM ghcr.io/sdr-enthusiasts/docker-baseimage:base AS mlat-builder
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git python3-dev python3-setuptools python3-pip
WORKDIR /src
RUN git clone --depth 1 https://github.com/mutability/mlat-client.git && \
    cd mlat-client && pip install . --target=/opt/mlat-client --break-system-packages

# ==============================================================================
# STAGE 3: THE ULTIMATE PRODUCTION RUNTIME (HYBRID MULTI-ARCH)
# ==============================================================================
FROM ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:latest
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    itcl3 tcllib tcl tclx tcl-tls libatomic1 libusb-1.0-0 socat python3-minimal && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Hút ruột binary sạch từ các image hãng (Đã chuẩn hóa 100% theo tọa độ thực tế s6-overlay)
COPY --from=ghcr.io/sdr-enthusiasts/docker-flightradar24:latest_nohealthcheck /usr/bin/fr24feed /usr/bin/fr24feed
COPY --from=ghcr.io/sdr-enthusiasts/docker-airnavradar:latest /usr/bin/rbfeeder /usr/bin/rbfeeder
COPY --from=ghcr.io/sdr-enthusiasts/docker-adsbhub:latest /usr/bin/adsbhub.sh /usr/bin/adsbhub.sh
COPY --from=ghcr.io/sdr-enthusiasts/docker-opensky-network:latest /usr/bin/openskyd-dump1090 /usr/bin/openskyd
COPY --from=ghcr.io/sdr-enthusiasts/docker-planefinder:latest /usr/local/bin/pfclient /usr/bin/pfclient

# Đổ thành phẩm sạch vừa tự compile sang
COPY --from=tcl-builder /opt/tcl /opt/tcl
# Tcllauncher path is hardcoded in the piaware binary at compile time → must be at /usr/lib/
COPY --from=tcl-builder /usr/lib/Tcllauncher1.10 /usr/lib/Tcllauncher1.10
# Remaining Tcl packages (piaware, fa_adept_codec, etc.) use env-var auto-discovery
ENV TCLLIBPATH=/opt/tcl/lib
COPY --from=tcl-builder /usr/lib/piaware /usr/lib/piaware
COPY --from=tcl-builder /usr/bin/piaware /usr/bin/piaware
COPY --from=tcl-builder /src/dump1090/faup1090 /usr/lib/piaware/helpers/
COPY --from=tcl-builder /src/beast-splitter/beast-splitter /usr/local/bin/
COPY --from=mlat-builder /opt/mlat-client /opt/mlat-client

# Detect runtime Python version and install mlat-client into the correct site-packages path
RUN PY=$(python3 -c "import sys; print(f'python{sys.version_info.major}.{sys.version_info.minor}')") && \
    mkdir -p /usr/local/lib/${PY}/dist-packages && \
    cp -r /opt/mlat-client /usr/local/lib/${PY}/dist-packages/mlat-client && \
    rm -rf /opt/mlat-client && \
    ln -sf /usr/local/lib/${PY}/dist-packages/mlat-client/bin/fa-mlat-client /usr/lib/piaware/helpers/fa-mlat-client
# Note: /run/piaware is NOT created here — /run is tmpfs at container start
# (see compose.yaml), so the directory is created by init-aio-feeders.sh instead.

# Bootstrap script: generates feeder configs, launches all feeders, runs status loop
COPY init-aio-feeders.sh /etc/cont-init.d/99-start-aio-feeders
RUN chmod +x /etc/cont-init.d/99-start-aio-feeders

# Dashboard at /feeding/, status API at /api/
COPY index.html /var/www/html/feeding/index.html
COPY nginx-hpr-aio.conf /etc/nginx/snippets/hpr-aio.conf
RUN sed -i \
    '/include \/etc\/nginx\/nginx-tar1090-webroot\.conf;/a\  include /etc/nginx/snippets/hpr-aio.conf;' \
    /etc/nginx/sites-enabled/tar1090

EXPOSE 80 30005 8754 30053