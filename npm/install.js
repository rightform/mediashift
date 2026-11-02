#!/usr/bin/env node
// Runs the installer that ships in this package: the same install.sh the README's curl line
// fetches from GitHub, so both ways install the same way.
const { spawnSync } = require("node:child_process");
const path = require("node:path");

if (process.platform !== "darwin") {
  console.error("MediaShift runs on macOS only.");
  process.exit(1);
}

const result = spawnSync("/bin/zsh", [path.join(__dirname, "install.sh"), ...process.argv.slice(2)], {
  stdio: "inherit",
});
process.exit(result.status ?? 1);
