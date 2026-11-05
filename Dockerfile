################################################################################

# Create a stage for downloading libs.
FROM alpine:3.24 AS libs

WORKDIR /libs

RUN wget -q https://jdbc.postgresql.org/download/postgresql-42.2.2.jar -O postgresql-42.2.2.jar
    
################################################################################

# Create a stage for building the application artifact.
FROM maven:3.9.2-eclipse-temurin-17 AS package

ARG MAVEN_REPO
RUN echo "MAVEN_REPO: $MAVEN_REPO"

ARG MAIN_DOMAIN_ARG
RUN echo "MAIN_DOMAIN_ARG: $MAIN_DOMAIN_ARG"

# Copy the internal registry certificate to the container
COPY .gitlab-ci/variables/main-domain.pem /tmp/main-domain.pem

# Import the certificate into the Java truststore
RUN keytool -importcert -trustcacerts -keystore $JAVA_HOME/lib/security/cacerts \
    -storepass changeit -noprompt -alias gitlab-instance -file /tmp/main-domain.pem

WORKDIR /build

COPY firmadigital-servicio/pom.xml ./pom.xml
COPY firmadigital-servicio/src ./src

# Change database configuration for Payara Micro
COPY .gitlab-ci/container/persistence.xml src/main/resources/META-INF/persistence.xml
COPY .gitlab-ci/container/orm.xml src/main/resources/META-INF/orm.xml
RUN find src/main/java -type f -name "*.java" -exec sed -i 's|lookup = "java:/FirmaDigitalDS"|lookup = "java/FirmaDigitalDS"|g' {} +

RUN --mount=type=secret,id=maven-settings,target=/root/.m2/settings.xml \
    --mount=type=bind,source=${MAVEN_REPO},target=/root/.m2/repository,rw \
    mvn -B -s /root/.m2/settings.xml dependency:get \
    -DremoteRepositories=gitlab-maven::default::https://$MAIN_DOMAIN_ARG/api/v4/projects/44/packages/maven \
    -Dartifact=ec.gob.firmadigital:libreria:5.2.0-SNAPSHOT \
    && mvn -B package -DskipTests

################################################################################

# Final stage.
FROM payara/micro:6.2025.11-jdk17

# Set the timezone environment variable
ENV TZ=America/Guayaquil

# Copy the organization certificates
COPY --chown=payara:payara .gitlab-ci/variables/old-main-domain.pem /tmp/old-main-domain.pem
COPY --chown=payara:payara .gitlab-ci/variables/main-domain.pem /tmp/main-domain.pem

# Create a custom truststore in the user's working directory
RUN keytool -importcert -trustcacerts \
    -alias old-main-domain \
    -file /tmp/old-main-domain.pem \
    -keystore /opt/payara/custom-truststore.jks \
    -storepass changeit \
    -noprompt \
    && keytool -importcert -trustcacerts \
    -alias main-domain \
    -file /tmp/main-domain.pem \
    -keystore /opt/payara/custom-truststore.jks \
    -storepass changeit \
    -noprompt \
    && rm /tmp/old-main-domain.pem /tmp/main-domain.pem

# Explicitly force the JVM to use the custom truststore at runtime
ENV JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=/opt/payara/custom-truststore.jks -Djavax.net.ssl.trustStorePassword=changeit"

# Copy the post-boot.asadmin configuration file
COPY --chown=payara:payara .gitlab-ci/container/post-boot.asadmin /opt/payara/post-boot.asadmin

# Copy postgresql JDBC driver and explicitly grant ownership to payara
COPY --from=libs --chown=payara:payara libs/postgresql-42.2.2.jar /opt/payara/lib/postgresql-42.2.2.jar

# Copy the native Java health check script
COPY --chown=payara:payara .gitlab-ci/container/HealthCheck.java /opt/payara/HealthCheck.java

# Copy the compiled WAR file
COPY --from=package --chown=payara:payara build/target/servicio.war /opt/payara/deployments/servicio.war

# Pass arguments to the default Payara Micro entrypoint
CMD ["--addJars", "/opt/payara/lib/postgresql-42.2.2.jar", "--postbootcommandfile", "/opt/payara/post-boot.asadmin", "--deploy", "/opt/payara/deployments/servicio.war"]