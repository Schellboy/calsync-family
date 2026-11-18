import com.android.build.gradle.internal.api.ApkVariantOutputImpl
import java.security.KeyStore
import java.security.PrivateKey
import java.util.Properties

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

val ciKeystorePath = providers.environmentVariable("CALSYNCFAMILY_KEYSTORE_PATH").orNull
val releaseStoreFile = (ciKeystorePath ?: keystoreProperties.getProperty("storeFile"))
    ?.takeIf { it.isNotBlank() }?.let { file(it) }
val releaseStorePassword = if (ciKeystorePath != null)
    providers.environmentVariable("CALSYNCFAMILY_STORE_PASSWORD").orNull
else keystoreProperties.getProperty("storePassword")
val releaseKeyAlias = if (ciKeystorePath != null)
    providers.environmentVariable("CALSYNCFAMILY_KEY_ALIAS").orNull
else keystoreProperties.getProperty("keyAlias")
val releaseKeyPassword = if (ciKeystorePath != null)
    providers.environmentVariable("CALSYNCFAMILY_KEY_PASSWORD").orNull
else keystoreProperties.getProperty("keyPassword")

val validateReleaseSigningInputs = tasks.register("validateReleaseSigningInputs") {
    doLast {
        if (releaseStoreFile?.isFile != true || !releaseStoreFile.canRead() ||
            releaseStorePassword.isNullOrBlank() || releaseKeyAlias.isNullOrBlank() ||
            releaseKeyPassword.isNullOrBlank()
        ) {
            throw GradleException(
                "CalSync release signing requires a readable keystore and all signing settings. " +
                    "Configure android/key.properties locally or supply the CALSYNCFAMILY signing variables in CI."
            )
        }
        val hasSigningKey = runCatching {
            val keystore = KeyStore.getInstance(releaseStoreFile, releaseStorePassword.toCharArray())
            keystore.getKey(releaseKeyAlias, releaseKeyPassword.toCharArray()) is PrivateKey &&
                keystore.getCertificate(releaseKeyAlias) != null
        }.getOrDefault(false)
        if (!hasSigningKey) {
            throw GradleException("CalSync release signing could not unlock the signing key. Check the keystore, alias and passwords.")
        }
    }
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.henriquecouto.calsync"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "de.schellboy.calsyncfamily"
        manifestPlaceholders["launcherAppLabel"] = "CalSync Family"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (gradle.startParameter.taskNames.any { it.contains("Gplay", ignoreCase = true) }) {
        flavorDimensions += listOf("store")
        productFlavors {
            create("gplay") {
                dimension = "store"
                applicationId = "dev.henriquecouto.calsync_gplay"
                manifestPlaceholders["launcherAppLabel"] = "CalSync"
            }
        }
    }

    signingConfigs {
        create("release") {
            storeFile = releaseStoreFile
            storePassword = releaseStorePassword
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }
}

val abiCodes = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)
android.applicationVariants.configureEach {
    val variant = this
    variant.outputs.forEach { output ->
        val abiVersionCode = abiCodes[output.filters.find { it.filterType == "ABI" }?.identifier]
        if (abiVersionCode != null) {
            (output as ApkVariantOutputImpl).versionCodeOverride = variant.versionCode * 10 + abiVersionCode
        }
    }
}

androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        val taskSuffix = variant.name.replaceFirstChar { it.uppercaseChar() }
        tasks.configureEach {
            if (name == "pre${taskSuffix}Build" || name == "validateSigning${taskSuffix}") {
                dependsOn(validateReleaseSigningInputs)
            }
        }
    }
    onVariants { variant ->
        if (variant.flavorName == "gplay") {
            variant.packaging.resources.excludes.add("**/adi-registration.properties")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
}

tasks.register("injectSoftDeletePlugin") {
    doLast {
        val registrantFile = file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
        if (!registrantFile.exists()) return@doLast

        var content = registrantFile.readText()

        val injection = """
    try {
      flutterEngine.getPlugins().add(new dev.henriquecouto.calsync.SoftDeletePlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin cal_sync_soft_delete, dev.henriquecouto.calsync.SoftDeletePlugin", e);
    }
  """

        if (!content.contains("SoftDeletePlugin")) {
            content = content.replace("  }\n}", injection + "\n  }\n}")
            registrantFile.writeText(content)
        }
    }
}

tasks.whenTaskAdded {
    if (name.startsWith("compile") && name.endsWith("JavaWithJavac")) {
        dependsOn("injectSoftDeletePlugin")
    }
}
