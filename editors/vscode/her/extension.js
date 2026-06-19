// Highlighting works with no dependencies (the grammar is declarative).
// For the language server, run `npm install` in this folder once — the
// client library is the only dependency.
const vscode = require("vscode");

let client;

function activate(context) {
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

  // "HER: Show Generated Ruby" — asks the server for the Ruby HER compiled
  // the component at the cursor to, and opens it beside the template.
  context.subscriptions.push(
    vscode.commands.registerCommand("her.showSource", async () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor || !client) return;
      const source = await client.sendRequest("workspace/executeCommand", {
        command: "her.showSource",
        arguments: [
          editor.document.uri.toString(),
          { line: editor.selection.active.line, character: editor.selection.active.character }
        ]
      });
      if (!source) return;
      const doc = await vscode.workspace.openTextDocument({ language: "ruby", content: source });
      await vscode.window.showTextDocument(doc, { preview: true, viewColumn: vscode.ViewColumn.Beside });
    })
  );
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
