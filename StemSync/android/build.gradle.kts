extra["ffmpegKitPackage"] = "audio"

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

allprojects {
    tasks.withType<JavaCompile> {
        if (project.name == "receive_sharing_intent" || project.name == "environment_sensors") {
            sourceCompatibility = "1.8"
            targetCompatibility = "1.8"
        } else {
            sourceCompatibility = "17"
            targetCompatibility = "17"
        }
    }
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile> {
        compilerOptions {
            if (project.name == "receive_sharing_intent" || project.name == "environment_sensors") {
                jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8
            } else {
                jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
            }
        }
    }
}
