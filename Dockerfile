# syntax=docker/dockerfile:1

########## Builder stage ##########
FROM eclipse-temurin:17-jdk-jammy AS builder

ARG FILE_VERSION=5.43
ARG FILE_SHA256=8c8015e91ae0e8d0321d94c78239892ef9dbc70c4ade0008c0e95894abfb1991

RUN apt-get update && apt-get install -yqq --no-install-recommends \
      ruby curl unzip make gcc zlib1g-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Build `file` FILE_VERSION from source (Harvard's recipe), install into /usr/local.
RUN cd /var/tmp && \
    curl -fsSLo file-${FILE_VERSION}.tar.gz https://astron.com/pub/file/file-${FILE_VERSION}.tar.gz && \
    echo "${FILE_SHA256}  file-${FILE_VERSION}.tar.gz" | sha256sum --check && \
    tar xzf file-${FILE_VERSION}.tar.gz && \
    cd file-${FILE_VERSION} && ./configure --prefix=/usr/local && make -j"$(nproc)" && make install && \
    cd / && rm -rf /var/tmp/file-${FILE_VERSION}*

# Install FITS via bin/setup (SHA-256 verified inside FitsInstaller).
COPY bin/setup bin/setup
COPY lib/fits_jruby/fits_installer.rb lib/fits_jruby/fits_installer.rb
ENV FITS_HOME=/opt/fits
RUN ruby bin/setup

########## Runtime stage ##########
FROM eclipse-temurin:17-jre-jammy AS runtime

# FITS tool runtime dependencies (no compilers).
RUN apt-get update && apt-get install -yqq --no-install-recommends \
      python3 python-is-python3 \
      libarchive-zip-perl libio-compress-perl libcompress-raw-zlib-perl \
      libcompress-bzip2-perl libcompress-raw-bzip2-perl libio-digest-perl \
      libdigest-md5-file-perl libdigest-perl-md5-perl libdigest-sha-perl \
      libposix-strptime-perl libunicode-linebreak-perl \
      libmms0 libcurl3-gnutls \
      curl unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install JRuby 9.4.15.0 (SHA-256 verified) to /opt/jruby.
ARG JRUBY_VERSION=9.4.15.0
ARG JRUBY_SHA256=c8b8c5a7a1581fdba3ba73f7c375f793f6528117b444cc6baf6fb29bbcf9696d
RUN curl -fsSLo /tmp/jruby.tar.gz \
      https://repo1.maven.org/maven2/org/jruby/jruby-dist/${JRUBY_VERSION}/jruby-dist-${JRUBY_VERSION}-bin.tar.gz && \
    echo "${JRUBY_SHA256}  /tmp/jruby.tar.gz" | sha256sum --check && \
    mkdir -p /opt/jruby && tar xzf /tmp/jruby.tar.gz -C /opt/jruby --strip-components=1 && \
    rm /tmp/jruby.tar.gz
ENV PATH=/opt/jruby/bin:$PATH

WORKDIR /app

# Bundle install (production only) using the app's Gemfile.
COPY Gemfile Gemfile.lock ./
RUN jruby -S gem install bundler && \
    jruby -S bundle config set --local without 'development test' && \
    jruby -S bundle install

# App code + the built `file` + FITS.
COPY --from=builder /usr/local /usr/local
COPY --from=builder /opt/fits /opt/fits
COPY . /app
RUN ldconfig

# Unprivileged user; UID/GID overridable at run time.
ARG FITS_UID=1000
ARG FITS_GID=1000
RUN groupadd -g ${FITS_GID} fits && \
    useradd -u ${FITS_UID} -g ${FITS_GID} -M -s /usr/sbin/nologin fits && \
    mkdir -p /run/fits && chown fits:fits /run/fits

ENV FITS_HOME=/opt/fits \
    FITS_SOCKET_PATH=/run/fits/fits.sock \
    FITS_QUEUE_CAPACITY=64 \
    FITS_LOG_LEVEL=info \
    FITS_READ_TIMEOUT=5 \
    FITS_WRITE_TIMEOUT=30 \
    JAVA_OPTS="-Xms256m -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ExitOnOutOfMemoryError"

USER fits
ENTRYPOINT ["bin/docker-entrypoint"]
