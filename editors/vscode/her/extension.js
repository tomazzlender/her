// Highlighting works with no dependencies (the grammar is declarative).
// For the language server, run `npm install` in this folder once — the
// client library is the only dependency.
const vscode = require("vscode");

let client;

function activate() {
  let lc;
  try {
    lc = require("vscode-languageclient/node");
  } catch (_error) {
    console.warn(
      "her: vscode-languageclient is not installed; syntax highlighting only. " +
        "Run `npm install` in the extension folder to enable the language server."
    );
    return;
  }

  const config = vscode.workspace.getConfiguration("her");
  const command = config.get("command");
  const args = command.slice(1).concat(["lsp"]);
  const bootFile = config.get("bootFile");
  if (bootFile) args.push("-r", bootFile);

  client = new lc.LanguageClient(
    "her",
    "HER",
    {
      command: command[0],
      args,
      options: { cwd: vscode.workspace.workspaceFolders?.[0]?.uri.fsPath }
    },
    // .her templates plus Ruby files, so inline `template <<~HER`/`%(...)`
    // templates embedded in component sources get the same features.
    { documentSelector: [{ language: "her" }, { language: "ruby" }] }
  );
  client.start();
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
