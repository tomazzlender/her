package dev.her.intellij

import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.platform.lsp.api.LspServerSupportProvider
import com.intellij.platform.lsp.api.ProjectWideLspServerDescriptor
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

class HerLspServerDescriptor(project: Project) :
    ProjectWideLspServerDescriptor(project, "HER") {

    override fun isSupportedFile(file: VirtualFile): Boolean = file.extension == "her"

    override fun createCommandLine(): GeneralCommandLine {
        val root = project.basePath?.let(Path::of)
        val command = mutableListOf<String>()
        if (root != null && Files.exists(root.resolve("Gemfile"))) {
            command += listOf("bundle", "exec")
        }
        command += listOf("her", "lsp")
        bootFile(root)?.let { command += listOf("-r", it) }
        return GeneralCommandLine(command).withWorkDirectory(project.basePath)
    }

    /**
     * The file passed to `her lsp -r`, which loads the project's component
     * modules. Configured by a `.her-lsp` file at the project root whose
     * first non-comment line is the boot path; falls back to config/boot.rb
     * when that exists. Without one the server still provides syntax
     * diagnostics.
     */
    private fun bootFile(root: Path?): String? {
        root ?: return null
        val configured = root.resolve(".her-lsp")
        if (Files.exists(configured)) {
            Files.readAllLines(configured)
                .firstOrNull { it.isNotBlank() && !it.trimStart().startsWith("#") }
                ?.trim()
                ?.let { return it }
        }
        return if (Files.exists(root.resolve("config").resolve("boot.rb"))) "config/boot.rb" else null
    }
}
