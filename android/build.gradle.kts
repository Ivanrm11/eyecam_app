allprojects {
    repositories {
        google()
        mavenCentral()
    }
}
val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)
subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // IMPORTANTE: todo esto va dentro de afterEvaluate, para que se aplique
    // DESPUES de que cada plugin (como flutter_tts) haya fijado su propia
    // version de Java/Kotlin. Si no, el plugin la sobrescribe y volvemos
    // a tener el conflicto "Inconsistent JVM Target Compatibility".
    afterEvaluate {
        // Configuramos el Toolchain para Java en todos los subproyectos
        plugins.withType(com.android.build.gradle.BasePlugin::class.java).configureEach {
            extensions.configure(com.android.build.gradle.BaseExtension::class.java) {
                compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
            }
        }
        // Configuramos el Toolchain para Kotlin en todos los subproyectos
        tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile::class.java).configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
        // tflite_flutter fue compilado por sus autores contra una version
        // antigua de Android (31) y no se ha actualizado. En vez de desactivar
        // la comprobacion de seguridad (que rompe otras tareas de Gradle),
        // forzamos que compile contra la misma version moderna que el resto
        // de la app, que es la solucion real que recomienda el propio error.
        if (project.name == "tflite_flutter") {
            extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.apply {
                compileSdkVersion(36)
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}
tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}