import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use(::load)
    }
}

android {
    namespace = "io.github.utabako"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.0.13004108"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "io.github.utabako"
        minSdk = 34
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

val validateReleaseSigning by tasks.registering {
    doLast {
        check(keystorePropertiesFile.exists()) {
            "Release signing requires android/key.properties"
        }
    }
}

tasks.configureEach {
    if (name in setOf("assembleRelease", "bundleRelease", "packageRelease")) {
        dependsOn(validateReleaseSigning)
    }
}

flutter {
    source = "../.."
}

val libboxDirectory = layout.buildDirectory.dir("libbox")
val buildLibbox = tasks.register<Exec>("buildLibbox") {
    workingDir(rootProject.projectDir.parentFile)
    val sdk = android.sdkDirectory
    val jdk = System.getProperty("java.home")
    inputs.files(rootProject.file("../tool/build_libbox.py"), rootProject.file("../tool/libbox.json"))
    inputs.property("goVersion", providers.exec {
        commandLine("go", "version")
        environment("GOTOOLCHAIN", "local")
    }.standardOutput.asText)
    inputs.property("javaVersion", System.getProperty("java.version"))
    inputs.file(sdk.resolve("ndk/${android.ndkVersion}/source.properties"))
    inputs.file(sdk.resolve("ndk/${android.ndkVersion}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"))
    outputs.files(listOf(
        "libbox.aar", "libbox.so", "libbox.buildinfo.txt", "libbox.aar.provenance.json",
        "jniLibs/arm64-v8a/libc++_shared.so",
    ).map { name -> libboxDirectory.map { it.file(name) } })
    commandLine(
        "python3", rootProject.file("../tool/build_libbox.py"),
        "--sdk", sdk, "--jdk", jdk,
    )
}

android.sourceSets.getByName("main").jniLibs.srcDir(
    files(libboxDirectory.map { it.dir("jniLibs") }).builtBy(buildLibbox)
)
tasks.named("preBuild") {
    dependsOn(buildLibbox)
}

dependencies {
    implementation(files(libboxDirectory.map { it.file("libbox.aar") }).builtBy(buildLibbox))
}

tasks.register("exportReleaseDependencies") {
    dependsOn(buildLibbox)
    doLast {
        val artifacts = configurations.getByName("releaseRuntimeClasspath")
            .incoming.resolutionResult.allComponents
            .mapNotNull { it.id as? org.gradle.api.artifacts.component.ModuleComponentIdentifier }
            .sortedBy { it.toString() }
            .map {
                mapOf("group" to it.group, "name" to it.module, "version" to it.version)
            }
        val output = layout.buildDirectory.file("reports/release-dependencies.json").get().asFile
        output.parentFile.mkdirs()
        output.writeText(groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(artifacts)))
    }
}
