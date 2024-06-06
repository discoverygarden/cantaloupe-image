ARG CANTALOUPE_REMOTE=https://github.com/cantaloupe-project/cantaloupe.git
ARG CANTALOUPE_BRANCH=release/5.0
ARG CANTALOUPE_VERSION=5.0.6
ARG CANTALOUPE_CONFIGS_REF=main
ARG CANTALOUPE_CONFIGS_REMOTE=https://github.com/discoverygarden/cantaloupe_configs.git#${CANTALOUPE_CONFIGS_REF}
ARG CANTALOUPE_CONFIGS=/opt/cantaloupe_configs
ARG GEM_PATH=${CANTALOUPE_CONFIGS}/gems

# XXX: jdk is required for (at least) our build stages. Final run could possibly
# swap over to jre, but probably not worth the complexity.
ARG BASE_IMAGE=eclipse-temurin:11-jdk-focal

ARG LIBJPEGTURBO_VERSION=2.0.2

ARG TOMCAT_UID=101
ARG TOMCAT_GID=101

# -----------------------------------
# Cantaloupe WAR building
# -----------------------------------
FROM maven:3.9.6-eclipse-temurin-17-focal as cantaloupe-build

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
# JPEGTurbo building
# ------------------------------------
FROM $BASE_IMAGE as jpegturbo-build

ARG TARGETARCH
ARG TARGETVARIANT

ARG LIBJPEGTURBO_VERSION
ENV LIBJPEGTURBO_VERSION=$LIBJPEGTURBO_VERSION

WORKDIR /tmp

# NOTE: can leave out this piece if you don't need the TurboJpegProcessor
# https://cantaloupe-project.github.io/manual/5.0/processors.html#TurboJpegProcessor
RUN \
  --mount=type=cache,target=/var/lib/apt/lists,sharing=locked,id=debian-apt-lists-$TARGETARCH$TARGETVARIANT \
  --mount=type=cache,target=/var/cache/apt/archives,sharing=locked,id=debian-apt-archives-$TARGETARCH$TARGETVARIANT \
  apt-get update -qqy && apt-get install -qqy cmake g++ make nasm checkinstall

ADD --link https://downloads.sourceforge.net/project/libjpeg-turbo/${LIBJPEGTURBO_VERSION}/libjpeg-turbo-${LIBJPEGTURBO_VERSION}.tar.gz ./

RUN tar -xpf libjpeg-turbo-${LIBJPEGTURBO_VERSION}.tar.gz

WORKDIR libjpeg-turbo-${LIBJPEGTURBO_VERSION}

RUN cmake \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=/usr/lib \
  -DBUILD_SHARED_LIBS=True \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DWITH_JPEG8=1 \
  -DWITH_JAVA=1 \
  && make \
  && checkinstall --default --install=no

# --------------------------------------
# Cantaloupe delegate gems acquisition.
# --------------------------------------
FROM $BASE_IMAGE as delegate-gem-acquisition

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
FROM $BASE_IMAGE as base

# --------------------------------------
# Main image build.
# --------------------------------------
FROM $BASE_IMAGE

ARG TARGETARCH
ARG TARGETVARIANT
ARG LIBJPEGTURBO_VERSION
ENV LIBJPEGTURBO_VERSION=$LIBJPEGTURBO_VERSION
ARG CANTALOUPE_VERSION
ENV CANTALOUPE_VERSION=$CANTALOUPE_VERSION
ARG CANTALOUPE_CONFIGS
ARG CANTALOUPE_CONFIGS_REMOTE
ENV CANTALOUPE_CONFIGS=$CANTALOUPE_CONFIGS
ENV CANTALOUPE_PROPERTIES=${CANTALOUPE_CONFIGS}/actual_cantaloupe.properties
ARG GEM_PATH
ENV GEM_PATH=$GEM_PATH
ENV TOMCAT_MEM=1g
ENV JAVA_OPTS="-Xms${TOMCAT_MEM} -Xmx${TOMCAT_MEM} -server -Djava.awt.headless=true -Dcantaloupe.config=${CANTALOUPE_PROPERTIES}"
ARG TOMCAT_UID
ARG TOMCAT_GID

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
  dpkg -i /tmp/jpegturbo-build/tmp/libjpeg-turbo-${LIBJPEGTURBO_VERSION}/libjpeg-turbo_${LIBJPEGTURBO_VERSION}-1_${TARGETARCH}.deb

WORKDIR /opt/libjpeg-turbo/lib
RUN ln -s /usr/lib/libturbojpeg.so

# Run non privileged
RUN addgroup --system tomcat --gid $TOMCAT_GID \
  && adduser --system tomcat --ingroup tomcat --uid $TOMCAT_UID

# Copy ImageMagick policy
COPY --link imagemagick_policy.xml /etc/ImageMagick-7/policy.xml

USER tomcat

# Cantaloupe configs
COPY --link --chown=$TOMCAT_UID:$TOMCAT_GID --from=delegate-gem-acquisition ${GEM_PATH}/ ${GEM_PATH}/
ADD --link --chown=$TOMCAT_UID:$TOMCAT_GID $CANTALOUPE_CONFIGS_REMOTE ${CANTALOUPE_CONFIGS}/
COPY --link --chown=$TOMCAT_UID:$TOMCAT_GID actual_cantaloupe.properties info.yaml ${CANTALOUPE_CONFIGS}/

WORKDIR /var/cache/cantaloupe
WORKDIR /var/log/cantaloupe

# Get and unpack Cantaloupe release archive
WORKDIR /cantaloupe
COPY --link --chown=$TOMCAT_UID:$TOMCAT_GID --from=cantaloupe-build /build/cantaloupe/target/cantaloupe-${CANTALOUPE_VERSION}.jar cantaloupe.jar
COPY --link --chown=$TOMCAT_UID:$TOMCAT_GID --chmod=500 <<-'EOS' entrypoint.sh
#!/bin/bash
java $JAVA_OPTS -jar cantaloupe.jar

EOS

CMD ["./entrypoint.sh"]
