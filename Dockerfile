FROM tomcat:9.0.69-jdk8-temurin-focal

ENV LIBJPEGTURBO_VERSION=2.0.2
ENV CANTALOUPE_VERSION=4.1.9
ENV CANTALOUPE_CONFIGS=/opt/cantaloupe_configs
ENV CANTALOUPE_PROPERTIES=${CANTALOUPE_CONFIGS}/actual_cantaloupe.properties
ENV GEM_PATH=${CANTALOUPE_CONFIGS}/gems
ENV CATALINA_BASE=/usr/local/tomcat
ENV CATALINA_HOME=/usr/local/tomcat
ENV CATALINA_PID=/usr/local/tomcat/pid/catalina.pid
ENV TOMCAT_MEM=1g
ENV JAVA_OPTS="-Xms${TOMCAT_MEM} -Xmx${TOMCAT_MEM} -server -Djava.awt.headless=true -Dcantaloupe.config=${CANTALOUPE_PROPERTIES}"

EXPOSE 8080

# Update packages and install tools
RUN apt-get update -qqy && apt-get dist-upgrade -qqy \
  && apt-get install -qqy --no-install-recommends \
     ffmpeg libopenjp2-tools imagemagick \
     curl rubygems unzip \
  && apt-get -qqy autoremove && apt-get -qqy autoclean

# NOTE: can leave out this piece if you don't need the TurboJpegProcessor
# https://cantaloupe-project.github.io/manual/5.0/processors.html#TurboJpegProcessor
RUN cd /tmp && apt-get install -qy cmake g++ make nasm \
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
  && apt-get -qqy autoremove && apt-get -qqy autoclean

# Run non privileged
RUN addgroup --system tomcat \
  && adduser --system tomcat --ingroup tomcat

# Copy ImageMagick policy
COPY imagemagick_policy.xml /etc/ImageMagick-7/policy.xml

# Get and unpack Cantaloupe release archive
RUN mkdir -p /var/cache/cantaloupe /var/log/cantaloupe \
  && chown -R tomcat:tomcat /var/cache/cantaloupe /var/log/cantaloupe \
  && curl --silent --fail -OL https://github.com/cantaloupe-project/cantaloupe/releases/download/v${CANTALOUPE_VERSION}/cantaloupe-${CANTALOUPE_VERSION}.zip \
  && unzip cantaloupe-${CANTALOUPE_VERSION}.zip \
  && mv cantaloupe-${CANTALOUPE_VERSION}/cantaloupe-${CANTALOUPE_VERSION}.war /usr/local/tomcat/webapps/cantaloupe.war \
  && rm cantaloupe-${CANTALOUPE_VERSION}.zip \
  && chown -R tomcat:tomcat /usr/local/tomcat/

# Cantaloupe configs
RUN mkdir -p ${CANTALOUPE_CONFIGS} \
  && gem install --no-document --install-dir ${GEM_PATH} cache_lib \
  && chown -R tomcat:tomcat ${CANTALOUPE_CONFIGS}

COPY --chown=tomcat:tomcat \
  actual_cantaloupe.properties cantaloupe.properties delegates.rb default_i8_delegates.rb info.yaml \
  ${CANTALOUPE_CONFIGS}/

USER tomcat

CMD ["catalina.sh", "run"]
