plugins {
    id("com.android.application")
    id("kotlin-android")
}

android {
    namespace = "com.example.speak_reader"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    defaultConfig {
        minSdk = 21
        multiDexEnabled = false
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    // =================== 体积优化：仅打包 arm64-v8a ===================
    // 减少约60%的.so库体积，只保留主流CPU架构
    flavorDimensions += "abi"
    productFlavors {
        create("arm64") {
            dimension = "abi"
            ndk {
                abiFilters.add("arm64-v8a")
            }
        }
    }

    // 防止因多 flavour 混淆问题，明确所有 ABI 都输出到同一个目录
    packaging {
        resourcesExcludes.addAll(listOf(
            "META-INF/DEPENDENCIES",
            "META-INF/LICENSE",
            "META-INF/LICENSE.txt",
            "META-INF/license.txt",
            "META-INF/NOTICE",
            "META-INF/NOTICE.txt",
            "META-INF/notice.txt",
            "META-INF/ASL2.0",
            "META-INF/*.list",
            "META-INF/*.SF",
            "META-INF/*.RSA"
        ))
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.12.0")
}

tasks.withType<JavaCompile>().configureEach {
    options.encoding = "UTF-8"
}