package dev.her.intellij

import org.jetbrains.plugins.textmate.api.TextMateBundleProvider
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption

/**
 * Ships the HER TextMate grammar with the plugin, so installing the plugin
 * is enough for .her files to be recognized and highlighted — no manual
 * Settings → Editor → TextMate Bundles import.
 *
 * The TextMate plugin wants a bundle *directory* on disk, and resources
 * inside the plugin jar are not a directory, so the bundle is extracted
 * once per IDE session into a temp dir.
 */
class HerTextMateBundleProvider : TextMateBundleProvider {
    override fun getBundles(): List<TextMateBundleProvider.PluginBundle> {
        val path = bundlePath ?: return emptyList()
        return listOf(TextMateBundleProvider.PluginBundle("HER", path))
    }

    companion object {
        private val FILES = listOf("info.plist", "Syntaxes/her.tmLanguage")

        private val bundlePath: Path? by lazy { extract() }

        private fun extract(): Path? = runCatching {
            val root = Files.createTempDirectory("her-textmate").resolve("her.tmbundle")
            for (name in FILES) {
                val resource = HerTextMateBundleProvider::class.java
                    .getResourceAsStream("/textmate/her.tmbundle/$name") ?: return null
                val target = root.resolve(name)
                Files.createDirectories(target.parent)
                resource.use { Files.copy(it, target, StandardCopyOption.REPLACE_EXISTING) }
            }
            root
        }.getOrNull()
    }
}
