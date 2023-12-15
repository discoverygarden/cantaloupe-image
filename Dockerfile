ARG CANTALOUPE_REMOTE=https://github.com/cantaloupe-project/cantaloupe.git
ARG CANTALOUPE_BRANCH=release/4.1
ARG CANTALOUPE_VERSION=4.1.11

ARG TOMCAT_UID=101
ARG TOMCAT_GID=101

FROM maven:3-eclipse-temurin-8-focal as cantaloupe-build

ARG TARGETPLATFORM
ARG TARGETOS
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

FROM tomcat:9.0.69-jdk8-temurin-focal

ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

ARG CANTALOUPE_VERSION
ENV LIBJPEGTURBO_VERSION=2.0.2
ENV CANTALOUPE_VERSION=$CANTALOUPE_VERSION
ENV CANTALOUPE_CONFIGS=/opt/cantaloupe_configs
ENV CANTALOUPE_PROPERTIES=${CANTALOUPE_CONFIGS}/actual_cantaloupe.properties
ENV GEM_PATH=${CANTALOUPE_CONFIGS}/gems
ENV CATALINA_BASE=/usr/local/tomcat
ENV CATALINA_HOME=/usr/local/tomcat
ENV CATALINA_PID=/usr/local/tomcat/pid/catalina.pid
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
  ffmpeg libopenjp2-tools imagemagick curl rubygems unzip

# NOTE: can leave out this piece if you don't need the TurboJpegProcessor
# https://cantaloupe-project.github.io/manual/5.0/processors.html#TurboJpegProcessor
RUN \
  --mount=type=cache,target=/var/lib/apt/lists,sharing=locked,id=debian-apt-lists-$TARGETARCH$TARGETVARIANT \
  --mount=type=cache,target=/var/cache/apt/archives,sharing=locked,id=debian-apt-archives-$TARGETARCH$TARGETVARIANT \
  cd /tmp && apt-get install -qy cmake g++ make nasm \
  && curl --silent --fail -OL https://downloads.sourceforge.net/project/libjpeg-turbo/${LIBJPEGTURBO_VERSION}/libjpeg-turbo-${LIBJPEGTURBO_VERSION}.tar.gz \
  && tar -xpf libjpeg-turbo-${LIBJPEGTURBO_VERSION}.tar.gz \
  && cd libjpeg-turbo-${LIBJPEGTURBO_VERSION} \
  && cmake \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=/usr/lib \
  -DBUILD_SHARED_LIBS=True \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DWITH_JPEG8=1 \
  -DWITH_JAVA=1 \
  && make && make install \
  && mkdir -p /opt/libjpeg-turbo/lib \
  && ln -s /usr/lib/libturbojpeg.so /opt/libjpeg-turbo/lib/libturbojpeg.so \
  && cd /tmp && rm -Rf libjpeg-turbo-${LIBJPEGTURBO_VERSION}* \
  && apt-get purge -qy cmake g++ make nasm \
  && apt-get -qqy autoremove

# Run non privileged
RUN addgroup --system tomcat --gid $TOMCAT_GID \
  && adduser --system tomcat --ingroup tomcat --uid $TOMCAT_UID

# Copy ImageMagick policy
COPY --link imagemagick_policy.xml /etc/ImageMagick-7/policy.xml

# Get and unpack Cantaloupe release archive
COPY --link --from=cantaloupe-build /build/cantaloupe/target/cantaloupe-${CANTALOUPE_VERSION}.war /usr/local/tomcat/webapps/cantaloupe.war
RUN mkdir -p /var/cache/cantaloupe /var/log/cantaloupe \
  && chown -R tomcat:tomcat /var/cache/cantaloupe /var/log/cantaloupe \
  && chown -R tomcat:tomcat /usr/local/tomcat/


# Cantaloupe configs
RUN mkdir -p ${CANTALOUPE_CONFIGS} \
  && gem install --no-document --install-dir ${GEM_PATH} cache_lib \
  && chown -R tomcat:tomcat ${CANTALOUPE_CONFIGS}

COPY --link --chown=$TOMCAT_UID:$TOMCAT_GID \
  actual_cantaloupe.properties cantaloupe.properties delegates.rb default_i8_delegates.rb info.yaml \
  ${CANTALOUPE_CONFIGS}/

USER tomcat

CMD ["catalina.sh", "run"]
