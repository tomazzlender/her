plugins {
    id("java")
    kotlin("jvm") version "2.0.21"
    id("org.jetbrains.intellij.platform") version "2.2.1"
}

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    intellijPlatform {
        // The LSP API ships only in commercial IDEs (Ultimate, RubyMine, ...).
        intellijIdeaUltimate("2024.2")
    }
}

intellijPlatform {
    pluginConfiguration {
        id = "dev.her.intellij"
        name = "HER (HTML Embedded Ruby)"
        version = "0.1.0"
        description = """
            Language-server client for HER (.her) templates: diagnostics,
            completion, hover and go-to-definition backed by `her lsp`.
            Pair with a TextMate bundle for syntax highlighting.
        """.trimIndent()
        ideaVersion {
            sinceBuild = "242"
            // Without this, the Gradle plugin derives untilBuild = "242.*"
            // and the installer rejects any newer IDE. The LSP API used
            // here is stable; leave the range open-ended.
            untilBuild = provider { null }
        }
    }
}

kotlin {
    jvmToolchain(21)
}
