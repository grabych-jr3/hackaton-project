# --- build stage ---
FROM eclipse-temurin:21-jdk AS build
WORKDIR /src
COPY gradlew settings.gradle.kts build.gradle.kts ./
COPY gradle gradle
RUN sed -i 's/\r$//' gradlew && chmod +x gradlew && ./gradlew --no-daemon dependencies > /dev/null || true
COPY src src
RUN ./gradlew --no-daemon bootJar -x test

# --- runtime stage ---
FROM eclipse-temurin:21-jre
WORKDIR /app
RUN mkdir -p /photos
COPY --from=build /src/build/libs/central-api-0.1.0.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
