package dev.her.intellij

import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.platform.lsp.api.LspServerSupportProvider
import com.intellij.platform.lsp.api.ProjectWideLspServerDescriptor
import java.io.File
import java.nio.file.Files
import java.nio.file.Path

/**
 * Thin LSP wiring: every project with an open .her file gets one `her lsp`
 * process; all language intelligence lives in the server.
 */
class HerLspServerSupportProvider : LspServerSupportProvider {
    override fun fileOpened(
        project: Project,
        file: VirtualFile,
        serverStarter: LspServerSupportProvider.LspServerStarter
    ) {
        if (file.extension == "her") {
            serverStarter.ensureServerStarted(HerLspServerDescriptor(project))
        }
    }
}

/**
 * Optional `.her-lsp` file at the project root, one setting per line
 * (`#` comments allowed):
 *
 *     boot: config/boot.rb
 *     command: bundle exec her
 *
 * `boot:` is the file passed to `her lsp -r` (it loads the project's
 * component modules); a bare line means the same thing — the original
 * format. `command:` replaces the base command (default: `bundle exec her`
 * next to a Gemfile, plain `her` otherwise), split on whitespace, with
 * `lsp -r BOOT` appended by the plugin — use absolute paths here when the
 * IDE's environment can't see your Ruby setup.
 */
internal class HerLspConfig(val boot: String?, val command: List<String>?) {
    companion object {
        fun read(root: Path?): HerLspConfig {
            val file = root?.resolve(".her-lsp")
            if (file == null || !Files.exists(file)) return HerLspConfig(null, null)
            var boot: String? = null
            var command: List<String>? = null
            for (raw in Files.readAllLines(file)) {
                val line = raw.trim()
                if (line.isEmpty() || line.startsWith("#")) continue
                when {
                    line.startsWith("boot:") -> boot = line.removePrefix("boot:").trim()
                    line.startsWith("command:") ->
                        command = line.removePrefix("command:").trim().split(Regex("\\s+"))
                    boot == null -> boot = line
                }
            }
            return HerLspConfig(boot, command)
        }
    }
}

class HerLspServerDescriptor(project: Project) :
    ProjectWideLspServerDescriptor(project, "HER") {

    override fun isSupportedFile(file: VirtualFile): Boolean = file.extension == "her"

    override fun createCommandLine(): GeneralCommandLine {
        val root = project.basePath?.let(Path::of)
        val config = HerLspConfig.read(root)
        val command = mutableListOf<String>()
        command += config.command ?: defaultCommand(root)
        command += "lsp"
        (config.boot ?: defaultBoot(root))?.let { command += listOf("-r", it) }
        val line = GeneralCommandLine(command).withWorkDirectory(project.basePath)
        prependVersionManagerShims(line)
        return line
    }

    private fun defaultCommand(root: Path?): List<String> =
        if (root != null && Files.exists(root.resolve("Gemfile"))) listOf("bundle", "exec", "her")
        else listOf("her")

    /**
     * config/boot.rb when it exists; without a boot file the server still
     * provides syntax diagnostics.
     */
    private fun defaultBoot(root: Path?): String? =
        if (root != null && Files.exists(root.resolve("config").resolve("boot.rb"))) "config/boot.rb"
        else null

    /**
     * GUI-launched IDEs capture the login-shell environment (~/.zprofile)
     * but not interactive-shell config (~/.zshrc) — which is where version
     * managers usually edit PATH. macOS then resolves `bundle` to the
     * system /usr/bin/bundle, whose bundle has no `her` binstub:
     * "bundler: command not found: her", exit 127, even though the same
     * command works in a terminal. Shim directories re-resolve per working
     * directory, so prepending the common ones is safe; `command:` in
     * .her-lsp overrides when this guess is wrong.
     */
    private fun prependVersionManagerShims(line: GeneralCommandLine) {
        val home = System.getProperty("user.home") ?: return
        val shims = listOf(
            Path.of(home, ".local", "share", "mise", "shims"),
            Path.of(home, ".rbenv", "shims"),
            Path.of(home, ".asdf", "shims"),
        ).filter { Files.isDirectory(it) }.map(Path::toString)
        if (shims.isEmpty()) return
        val current = line.parentEnvironment["PATH"].orEmpty()
        val present = current.split(File.pathSeparator)
        val missing = shims.filterNot(present::contains)
        if (missing.isNotEmpty()) {
            line.environment["PATH"] = (missing + current).joinToString(File.pathSeparator)
        }
    }
}
