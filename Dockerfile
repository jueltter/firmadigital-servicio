################################################################################

# Create a stage for downloading the application code.
FROM alpine/git:v2.52.0 AS source

ARG MAIN_DOMAIN_ARG
RUN echo "MAIN_DOMAIN_ARG: $MAIN_DOMAIN_ARG"

WORKDIR /app

# Clone the library repository
RUN --mount=type=secret,id=ext-repository-read-token \
    EXT_REPOSITORY_READ_TOKEN=$(cat /run/secrets/ext-repository-read-token) \
    && git -c http.sslVerify=false clone --branch 5.2.0-minka --single-branch --depth 1 https://oauth2:${EXT_REPOSITORY_READ_TOKEN}@${MAIN_DOMAIN_ARG}/development-ext/firmaec/firmadigital-libreria.git

# Clone the repository
RUN --mount=type=secret,id=ext-repository-read-token \
    EXT_REPOSITORY_READ_TOKEN=$(cat /run/secrets/ext-repository-read-token) \
    && git -c http.sslVerify=false clone --branch 5.2.0-minka --single-branch --depth 1 https://oauth2:${EXT_REPOSITORY_READ_TOKEN}@${MAIN_DOMAIN_ARG}/development-ext/firmaec/firmadigital-servicio.git

################################################################################

# Create a stage for downloading the library dependencies.
FROM maven:3.9.2-eclipse-temurin-17 AS library-deps

WORKDIR /build

# Download dependencies AS a separate step to take advantage of Docker's caching.
# Leverage a cache mount to /root/.m2 so that subsequent builds don't have to
# re-download packages.
RUN --mount=type=bind,from=source,source=app/firmadigital-libreria/pom.xml,target=pom.xml \
    --mount=type=cache,target=/root/.m2 mvn -B dependency:go-offline -DskipTests

################################################################################

# Create a stage for building the library based on the stage with downloaded dependencies.
FROM library-deps AS library-install

WORKDIR /build

COPY --chown=mvn:mvn --from=source ./app/firmadigital-libreria/src src/
RUN --mount=type=bind,from=source,source=app/firmadigital-libreria/pom.xml,target=pom.xml \
    --mount=type=cache,target=/root/.m2 \
    mvn -B install -DskipTests -Dmaven.compiler.source=17 -Dmaven.compiler.target=17 && \
    rm -rf src/ target/

################################################################################

# Create a stage for downloading the application dependencies.
FROM library-install AS deps

WORKDIR /build

# Download dependencies AS a separate step to take advantage of Docker's caching.
# Leverage a cache mount to /root/.m2 so that subsequent builds don't have to
# re-download packages.
RUN --mount=type=bind,from=source,source=app/firmadigital-servicio/pom.xml,target=pom.xml \
    --mount=type=cache,target=/root/.m2 mvn -B dependency:go-offline -DskipTests

################################################################################

# Create a stage for building the application based on the stage with downloaded dependencies.
FROM deps AS package

WORKDIR /build

COPY --chown=mvn:mvn --from=source ./app/firmadigital-servicio/src src/
RUN --mount=type=bind,from=source,source=app/firmadigital-servicio/pom.xml,target=pom.xml \
    --mount=type=cache,target=/root/.m2 \
    mvn -B package -DskipTests

################################################################################

# Final stage.
FROM quay.io/wildfly/wildfly:33.0.2.Final-jdk17

# Set the timezone environment variable
ENV TZ=America/Guayaquil

# Switch to root to copy files and set ownership
USER root

# Copy the WAR produced by Maven into WildFly deployments and set ownership to jboss
COPY --chown=jboss:jboss --from=package build/target/servicio.war /opt/jboss/wildfly/standalone/deployments/

# Ensure WildFly picks up the deployment
RUN sh -c 'for f in /opt/jboss/wildfly/standalone/deployments/*.war; do touch "${f}.dodeploy"; done || true'

# Preserve original docker-entrypoint if present
RUN if [ -f /opt/jboss/tools/docker-entrypoint.sh ]; then mv /opt/jboss/tools/docker-entrypoint.sh /opt/jboss/tools/docker-entrypoint.sh.original; fi

# Copy PostgreSQL JDBC driver
COPY container-src/main/resources/libs/postgresql-42.2.2.jar /opt/jboss/
RUN chown jboss:jboss /opt/jboss/postgresql-42.2.2.jar

# Copy CLI script for datasource configuration
COPY container-src/main/resources/config/setup-postgres-datasource.cli /opt/jboss/
RUN chown jboss:jboss /opt/jboss/setup-postgres-datasource.cli

# Copy wrapper entrypoint that can add a management user at container start
COPY container-src/main/resources/config/docker-entrypoint.sh /opt/jboss/tools/docker-entrypoint.sh
RUN chmod +x /opt/jboss/tools/docker-entrypoint.sh && chown jboss:jboss /opt/jboss/tools/docker-entrypoint.sh

# Copy the old organization certificate
COPY .container/build/old-main-domain.pem /tmp/old-main-domain.pem

# Import the organization certificate into the Java Truststore
# $JAVA_HOME is usually set by the base WildFly image
RUN keytool -importcert -trustcacerts \
    -aliAS old-main-domain \
    -file /tmp/old-main-domain.pem \
    -keystore $JAVA_HOME/lib/security/cacerts \
    -storepass changeit \
    -noprompt \
    && rm /tmp/old-main-domain.pem

# Copy the organization certificate
COPY .container/build/main-domain.pem /tmp/main-domain.pem

# Import the organization certificate into the Java Truststore
# $JAVA_HOME is usually set by the base WildFly image
RUN keytool -importcert -trustcacerts \
    -aliAS main-domain \
    -file /tmp/main-domain.pem \
    -keystore $JAVA_HOME/lib/security/cacerts \
    -storepass changeit \
    -noprompt \
    && rm /tmp/main-domain.pem

# Revert to the default user from the base image
USER jboss

RUN /opt/jboss/wildfly/bin/jboss-cli.sh --commands="embed-server --server-config=standalone.xml, run-batch --file=/opt/jboss/setup-postgres-datasource.cli, stop-embedded-server"

EXPOSE 8080 9990

ENTRYPOINT ["/opt/jboss/tools/docker-entrypoint.sh"]
CMD ["/opt/jboss/wildfly/bin/standalone.sh", "-b", "0.0.0.0", "-bmanagement", "0.0.0.0"]
