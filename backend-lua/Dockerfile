FROM openresty/openresty:jammy

LABEL description="Yvy backend — OpenResty + LuaJIT + SQLite JSONB"

# ── System deps ──────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential wget unzip luarocks libssl-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── SQLite 3.45+ from source (JSONB support) ─────────────────────────────
ARG SQLITE_VERSION=3450000
RUN wget -q https://sqlite.org/2024/sqlite-autoconf-${SQLITE_VERSION}.tar.gz \
    && tar xzf sqlite-autoconf-${SQLITE_VERSION}.tar.gz \
    && cd sqlite-autoconf-${SQLITE_VERSION} \
    && ./configure --prefix=/usr/local --enable-json1 \
    && make -j$(nproc) && make install \
    && ldconfig \
    && cd .. && rm -rf sqlite-autoconf-*

# ── Lua rocks ────────────────────────────────────────────────────────────
RUN luarocks install lsqlite3 SQLITE_DIR=/usr/local \
    && luarocks install lua-resty-http \
    && luarocks install lua-resty-redis \
    && luarocks install lua-resty-lock \
    && luarocks install luaexpat \
    && luarocks install lua-csv \
    && luarocks install busted

# ── App directories ──────────────────────────────────────────────────────
RUN mkdir -p /opt/yvy/data /opt/yvy/frontend/build

# ── Copy app ─────────────────────────────────────────────────────────────
COPY backend-lua/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY backend-lua/ /opt/yvy/backend-lua/
COPY frontend/build/ /opt/yvy/frontend/build/

# ── Environment ──────────────────────────────────────────────────────────
ENV SQLITE_PATH=/opt/yvy/data/yvy.db
ENV REDIS_URL=redis://127.0.0.1:6379/0
ENV AUTH_REQUIRED=1
ENV LOG_LEVEL=INFO

EXPOSE 80

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
