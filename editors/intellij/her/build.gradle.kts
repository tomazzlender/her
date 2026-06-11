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
        // For the TextMate bundleProvider EP (ships the grammar with the plugin).
        bundledPlugin("org.jetbrains.plugins.textmate")
    }
}

intellijPlatform {
    pluginConfiguration {
        id = "dev.her.intellij"
        name = "HER (HTML Embedded Ruby)"
        version = "0.1.0"
        description = """
            HER (.her) template support: syntax highlighting via a bundled
            TextMate grammar, plus diagnostics, completion, hover and
            go-to-definition backed by `her lsp`.
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
