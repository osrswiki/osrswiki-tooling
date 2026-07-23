plugins {
    application
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(25)) // Use Java 25 with Gradle 9.3
    }
}

repositories {
    mavenCentral()
}

dependencies {
    // Required dependencies for the cache and dumper classes.
    implementation("org.slf4j:slf4j-simple:1.7.32")
    implementation("com.google.guava:guava:31.0.1-jre")
    implementation("commons-cli:commons-cli:1.4")
    
    // Missing dependencies that caused the build failure
    implementation("com.google.code.gson:gson:2.10.1") // For JSON parsing in various exporters
    implementation("org.antlr:antlr4-runtime:4.13.1") // For script parsing
    implementation("net.java.dev.jna:jna:5.14.0") // For native library access (bzip2)
    implementation("org.apache.commons:commons-compress:1.26.2") // For data decompression

    // Updated Lombok version for compatibility with newer JDKs
    compileOnly("org.projectlombok:lombok:1.18.38")
    annotationProcessor("org.projectlombok:lombok:1.18.38")

    testImplementation("org.junit.jupiter:junit-jupiter:5.10.2")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

application {
    mainClass.set("dumper.Main")
}

tasks.test {
    useJUnitPlatform()
}
