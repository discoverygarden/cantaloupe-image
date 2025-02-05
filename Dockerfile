ARG CANTALOUPE_REMOTE=https://github.com/cantaloupe-project/cantaloupe.git
ARG CANTALOUPE_BRANCH=release/5.0
# renovate: datasource=github-releases depName=cantaloupe-project/cantaloupe
ARG CANTALOUPE_VERSION=5.0.6
# renovate: datasource=github-tags depName=discoverygarden/cantaloupe_configs
ARG CANTALOUPE_CONFIGS_VERSION=v2.1.0
ARG CANTALOUPE_CONFIGS_REMOTE=https://github.com/discoverygarden/cantaloupe_configs.git#${CANTALOUPE_CONFIGS_VERSION}
ARG CANTALOUPE_CONFIGS=/opt/cantaloupe_configs
ARG GEM_PATH=${CANTALOUPE_CONFIGS}/gems

# XXX: jdk is required for (at least) our build stages. Final run could possibly
# swap over to jre, but probably not worth the complexity.
ARG BASE_IMAGE=eclipse-temurin:11.0.25_9-jdk-focal

# renovate: datasource=github-releases depName=libjpeg-turbo/libjpeg-turbo
ARG LIBJPEGTURBO_VERSION=2.1.5.1

ARG CANTALOUPE_UID=101
ARG CANTALOUPE_GID=101

# -----------------------------------
# Cantaloupe WAR building
# -----------------------------------
FROM maven:3.9.9-eclipse-temurin-11-focal AS cantaloupe-build

ARG TARGETARCH
ARG TARGETVARIANT

ARG CANTALOUPE_REMOTE
ARG CANTALOUPE_BRANCH

RUN \
  --mount=type=cache,target=/var/lib/apt/lists,sharing=locked,id=debian-apt-lists-$TARGETARCH$TARGETVARIANT \
  --mount=type=cache,target=/var/cache/apt/archives,sharing=locked,id=debian-apt-archives-$TARGETARCH$TARGETVARIANT \
  apt-get update -qqy && apt-get install -qqy --no-install-recommends \
  git

WORKDIR /build
RUN git clone --depth 1 --branch $CANTALOUPE_BRANCH -- $CANTALOUPE_REMOTE cantaloupe

WORKDIR cantaloupe
ADD --link patches/ patches/
RUN \
  find patches -name "*.patch" -exec git apply {} +

RUN --mount=type=cache,target=/root/.m2 \
 mvn clean package -DskipTests

# ------------------------------------
# JPEGTurbo acquisition
# ------------------------------------
FROM scratch AS jpegturbo-build

ARG TARGETARCH
ARG LIBJPEGTURBO_VERSION

WORKDIR /tmp

ADD --link https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEGTURBO_VERSION}/libjpeg-turbo-official_${LIBJPEGTURBO_VERSION}_${TARGETARCH}.deb ./

# --------------------------------------
# Cantaloupe delegate gems acquisition.
# --------------------------------------
FROM $BASE_IMAGE AS delegate-gem-acquisition

ARG TARGETARCH
ARG TARGETVARIANT

ARG GEM_PATH

# Update packages and install tools
RUN \
  --mount=type=cache,target=/var/lib/apt/lists,sharing=locked,id=debian-apt-lists-$TARGETARCH$TARGETVARIANT \
  --mount=type=cache,target=/var/cache/apt/archives,sharing=locked,id=debian-apt-archives-$TARGETARCH$TARGETVARIANT \
  apt-get update -qqy && apt-get install -qqy --no-install-recommends \
  rubygems

RUN \
  --mount=type=cache,target=/root/.gem/specs,sharing=locked \
  gem install --no-document --install-dir $GEM_PATH cache_lib

# --------------------------------------
# Reference to the base image as a build stage.
#
# Odd situation of wanting to chown a directory that's provided by the base
# image, without a `RUN chown [...]` invocation.
# --------------------------------------
FROM $BASE_IMAGE AS base

# --------------------------------------
# Main image build.
# --------------------------------------
FROM $BASE_IMAGE

ARG TARGETARCH
ARG TARGETVARIANT
ARG LIBJPEGTURBO_VERSION
ARG CANTALOUPE_VERSION
ENV CANTALOUPE_VERSION=$CANTALOUPE_VERSION
ARG CANTALOUPE_CONFIGS
ARG CANTALOUPE_CONFIGS_REMOTE
ENV CANTALOUPE_CONFIGS=$CANTALOUPE_CONFIGS
ENV CANTALOUPE_PROPERTIES=${CANTALOUPE_CONFIGS}/actual_cantaloupe.properties
ARG GEM_PATH
ENV GEM_PATH=$GEM_PATH
ENV CANTALOUPE_MEM=1g
ENV JAVA_OPTS="-Xms${CANTALOUPE_MEM} -Xmx${CANTALOUPE_MEM} -server -Djava.awt.headless=true -Dcantaloupe.config=${CANTALOUPE_PROPERTIES}"
ARG CANTALOUPE_UID
ARG CANTALOUPE_GID

EXPOSE 8080

# Update packages and install tools
RUN \
  --mount=type=cache,target=/var/lib/apt/lists,sharing=locked,id=debian-apt-lists-$TARGETARCH$TARGETVARIANT \
  --mount=type=cache,target=/var/cache/apt/archives,sharing=locked,id=debian-apt-archives-$TARGETARCH$TARGETVARIANT \
  apt-get update -qqy && apt-get install -qqy --no-install-recommends \
  ffmpeg libopenjp2-tools imagemagick

# NOTE: can leave out this piece if you don't need the TurboJpegProcessor
# https://cantaloupe-project.github.io/manual/5.0/processors.html#TurboJpegProcessor
RUN \
  --mount=type=bind,target=/tmp/jpegturbo-build,from=jpegturbo-build \
  dpkg -i /tmp/jpegturbo-build/tmp/libjpeg-turbo-official_${LIBJPEGTURBO_VERSION}_${TARGETARCH}.deb

# Run non privileged
RUN addgroup --system cantaloupe --gid $CANTALOUPE_GID \
  && adduser --system cantaloupe --ingroup cantaloupe --uid $CANTALOUPE_UID

# Copy ImageMagick policy
COPY --link imagemagick_policy.xml /etc/ImageMagick-7/policy.xml

USER cantaloupe

# Cantaloupe configs
COPY --link --chown=$CANTALOUPE_UID:$CANTALOUPE_GID --from=delegate-gem-acquisition ${GEM_PATH}/ ${GEM_PATH}/
ADD --link --chown=$CANTALOUPE_UID:$CANTALOUPE_GID $CANTALOUPE_CONFIGS_REMOTE ${CANTALOUPE_CONFIGS}/
COPY --link --chown=$CANTALOUPE_UID:$CANTALOUPE_GID actual_cantaloupe.properties info.yaml ${CANTALOUPE_CONFIGS}/

WORKDIR /var/cache/cantaloupe
WORKDIR /var/log/cantaloupe

# Get and unpack Cantaloupe release archive
WORKDIR /cantaloupe
COPY --link --chown=$CANTALOUPE_UID:$CANTALOUPE_GID --from=cantaloupe-build /build/cantaloupe/target/cantaloupe-${CANTALOUPE_VERSION}.jar cantaloupe.jar
COPY --link --chown=$CANTALOUPE_UID:$CANTALOUPE_GID --chmod=500 <<-'EOS' entrypoint.sh
#!/bin/bash
exec java $JAVA_OPTS -jar cantaloupe.jar

EOS

CMD ["./entrypoint.sh"]
