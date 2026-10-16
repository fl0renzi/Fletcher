// Fletcher - scripts/deploy.mjs
// Installs the addon into a local client's AddOns folder, either from the
// latest published GitHub release or from this working tree. Nothing here
// ships with the addon: it is a convenience for the machine that plays the
// game, so a release can land without copying folders by hand.
//
//   npm run deploy                       install the latest release
//   npm run deploy -- --version 1.0.0    install one specific release
//   npm run deploy -- --local            install the working tree as it is
//   npm run deploy -- --check            report the versions, change nothing
//   npm run deploy -- --force            reinstall even when versions match
//   npm run deploy -- --to "<folder>"    override the target folder
//
// The target is the addon's own folder, for example
// E:\World of Warcraft\_classic_beta_\Interface\AddOns\Fletcher. It comes
// from --to, from the FLETCHER_ADDONS environment variable, or from the
// gitignored deploy.local.json next to this repo as {"addonsPath": "..."}.

import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const REPO = "fl0renzi/Fletcher";
const ADDON = "Fletcher"; // the folder name inside AddOns, and in the zip
const TOC = "Fletcher.toc";

function fail(message) {
  console.error("deploy: " + message);
  process.exit(1);
}

// --- options ---------------------------------------------------------------

const options = { local: false, check: false, force: false, version: null, to: null };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const arg = argv[i];
  if (arg === "--local") options.local = true;
  else if (arg === "--check") options.check = true;
  else if (arg === "--force") options.force = true;
  else if (arg === "--version") options.version = argv[++i];
  else if (arg === "--to") options.to = argv[++i];
  else fail("unknown argument: " + arg);
}
if (options.local && options.version) fail("--local and --version cannot be combined");
if (options.version && !options.version.startsWith("v")) options.version = "v" + options.version;

// --- where it goes ---------------------------------------------------------

function readLocalConfig() {
  const file = join(root, "deploy.local.json");
  if (!existsSync(file)) return null;
  try {
    const data = JSON.parse(readFileSync(file, "utf8"));
    if (typeof data.addonsPath === "string" && data.addonsPath.trim() !== "") {
      return data.addonsPath.trim();
    }
  } catch {
    fail("deploy.local.json is not valid JSON");
  }
  return null;
}

const targetValue = options.to || process.env.FLETCHER_ADDONS || readLocalConfig();
if (!targetValue) {
  fail(
    "no target folder configured.\n" +
    '  Set it with --to "<path>",\n' +
    "  with the FLETCHER_ADDONS environment variable,\n" +
    '  or in deploy.local.json as {"addonsPath": "<path>"}.\n' +
    "  The path is the addon's own folder, so it ends in \\" + ADDON + "."
  );
}
const target = resolve(targetValue);

// The install mirrors the folder (see the end of this file), so the wipe must
// never be pointed at the AddOns folder itself: the last segment of the path
// has to be the addon's own name.
if (basename(target).toLowerCase() !== ADDON.toLowerCase()) {
  fail('the target folder must be named "' + ADDON + '"; got "' + target + '"');
}

// --- what is installed there now -------------------------------------------

function versionIn(folder) {
  const toc = join(folder, TOC);
  if (!existsSync(toc)) return null;
  const match = readFileSync(toc, "utf8").match(/^##\s*Version:\s*(.+)$/m);
  return match ? match[1].trim() : null;
}

let installed = null;
if (existsSync(target)) {
  if (!statSync(target).isDirectory()) fail(target + " is not a folder");
  const entries = readdirSync(target);
  if (entries.length > 0 && !existsSync(join(target, TOC))) {
    fail(target + " does not look like the " + ADDON + " folder (no " + TOC + "); refusing to touch it");
  }
  installed = versionIn(target);
}

// --- where it comes from ---------------------------------------------------

// The files the addon ships, read from the .toc the same way the release
// packager reads it: the .toc itself and every file it lists.
function shippedFiles() {
  const toc = readFileSync(join(root, TOC), "utf8");
  const lua = toc
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith("#"));
  return [TOC, ...lua];
}

function listFiles(folder) {
  const files = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else files.push(full);
    }
  };
  walk(folder);
  return files;
}

const work = join(tmpdir(), "fletcher-deploy-" + process.pid);
mkdirSync(work, { recursive: true });

async function fromRelease() {
  const url = options.version
    ? `https://api.github.com/repos/${REPO}/releases/tags/${options.version}`
    : `https://api.github.com/repos/${REPO}/releases/latest`;
  const headers = { "User-Agent": "Fletcher-deploy" };
  const token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
  if (token) headers.Authorization = "Bearer " + token;

  const releaseResponse = await fetch(url, { headers });
  if (!releaseResponse.ok) fail(`GitHub answered ${releaseResponse.status} for ${url}`);
  const release = await releaseResponse.json();

  const asset = (release.assets || []).find((entry) => entry.name.endsWith(".zip"));
  if (!asset) fail("the release has no zip asset");

  const zipPath = join(work, asset.name);
  if (zipPath.includes("'")) fail("a path component contains an apostrophe; not supported");
  const zipResponse = await fetch(asset.browser_download_url, { headers });
  if (!zipResponse.ok) fail(`downloading ${asset.name} failed with ${zipResponse.status}`);
  writeFileSync(zipPath, Buffer.from(await zipResponse.arrayBuffer()));

  const extractDir = join(work, "extract");
  rmSync(extractDir, { recursive: true, force: true });
  mkdirSync(extractDir, { recursive: true });
  if (process.platform === "win32") {
    // The .NET zip API, as the release packager uses it: Compress-Archive's
    // module does not always autoload, and Expand-Archive has the same
    // problem.
    execFileSync("powershell", ["-NoProfile", "-Command",
      "Add-Type -AssemblyName System.IO.Compression.FileSystem;" +
      `[System.IO.Compression.ZipFile]::ExtractToDirectory('${zipPath}','${extractDir}')`,
    ], { stdio: "inherit" });
  } else {
    execFileSync("unzip", ["-q", zipPath, "-d", extractDir], { stdio: "inherit" });
  }

  const source = join(extractDir, ADDON);
  if (!existsSync(join(source, TOC))) fail("the release zip did not contain " + ADDON + "/" + TOC);

  return { folder: source, description: "release " + (release.tag_name || "?"), version: (release.tag_name || "").replace(/^v/, "") };
}

function fromWorkingTree() {
  return { folder: root, description: "working tree", version: versionIn(root) || "0.0.0" };
}

// --- install ---------------------------------------------------------------

let source;
try {
  source = options.local ? fromWorkingTree() : await fromRelease();
} catch (error) {
  fail(error && error.message ? error.message : String(error));
}

console.log(`deploy: installed ${installed || "(nothing)"}; ${source.description} is ${source.version}`);

if (options.check) {
  if (installed && installed === source.version) console.log("deploy: up to date");
  else console.log(`deploy: would install ${source.version} into ${target}`);
  rmSync(work, { recursive: true, force: true });
  process.exit(0);
}

if (installed && installed === source.version && !options.force) {
  console.log("deploy: already at " + installed + "; nothing to do (--force reinstalls)");
  rmSync(work, { recursive: true, force: true });
  process.exit(0);
}

// The release zip holds exactly the shipped files. The working tree also holds
// this repo's tooling, so only the files the package would ship are taken.
const files = options.local
  ? shippedFiles().map((entry) => ({ from: join(root, entry), to: join(target, entry) }))
  : listFiles(source.folder).map((file) => ({ from: file, to: join(target, relative(source.folder, file)) }));

for (const file of files) {
  if (!existsSync(file.from)) fail("missing file to install: " + file.from);
}

// Mirror semantics: the addon folder becomes exactly what is being installed,
// so files an older version left behind do not linger.
rmSync(target, { recursive: true, force: true });
mkdirSync(target, { recursive: true });
for (const file of files) {
  mkdirSync(dirname(file.to), { recursive: true });
  cpSync(file.from, file.to);
}

rmSync(work, { recursive: true, force: true });

console.log(`deploy: ${files.length} files written to ${target}`);
console.log("deploy: the client picks the new version up on the next /reload or restart");
