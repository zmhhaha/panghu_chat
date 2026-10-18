import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";
import test from "node:test";
import { patchInstalledSettings, patchSettingsSource } from "./enable-trusted-web-settings.mjs";

const original = 'const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";';
const patched = patchSettingsSource(original);

function persistence(globals = {}, isLoopback = false) {
  return runInNewContext(`(function(ctx) { ${patched}\nreturn persistence; })(ctx)`, {
    ...globals,
    ctx: { remote: { $host: { isLoopback } } },
  });
}

test("retains the upstream loopback path even with an injected transport", () => {
  assert.equal(persistence({}, true), "host");
  assert.equal(persistence({ location: { origin: "https://other.example" }, __DSH_TRANSPORT__: {} }, true), "host");
});

test("enables host persistence for the exact HTTPS web origin", () => {
  assert.equal(persistence({ location: { origin: "https://dsh.panghuer.top" } }), "host");
  assert.equal(persistence({ location: new URL("https://dsh.panghuer.top:443/settings") }), "host");
  assert.equal(persistence({ location: { origin: "https://dsh.panghuer.top" }, __DSH_TRANSPORT__: undefined }), "host");
});

for (const origin of [
  "http://dsh.panghuer.top",
  "https://other.example",
  "https://dsh.panghuer.top.attacker.example",
  "https://sub.dsh.panghuer.top",
  "https://dsh.panghuer.top:444",
  "http://localhost:3000",
  "null",
]) {
  test(`keeps memory persistence for ${origin}`, () => {
    assert.equal(persistence({ location: { origin } }), "memory");
  });
}

for (const transport of [null, {}, false]) {
  test(`rejects an injected transport (${JSON.stringify(transport)}) on the trusted origin`, () => {
    assert.equal(persistence({ location: { origin: "https://dsh.panghuer.top" }, __DSH_TRANSPORT__: transport }), "memory");
  });
}

test("missing or null location safely keeps memory persistence", () => {
  assert.equal(persistence(), "memory");
  assert.equal(persistence({ location: null }), "memory");
  assert.equal(persistence({ location: {} }), "memory");
});

test("patch affects only the persistence statement", () => {
  const prefix = 'const otherCapability = ctx.remote.$host.isLoopback;\n';
  assert.equal(patchSettingsSource(prefix + original), prefix + patched);
});

test("rejects absent, duplicated, or already patched statements", () => {
  assert.throws(() => patchSettingsSource("const persistence = 'memory';"), /found 0/);
  assert.throws(() => patchSettingsSource(`${original}\n${original}`), /found 2/);
  assert.throws(() => patchSettingsSource(patched), /found 0/);
});

function packageFixture(t, { version = "0.1.6-alpha.2", name = "@deepseek-ai/dsh" } = {}) {
  const root = mkdtempSync(join(tmpdir(), "dsh-settings-patch-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const target = join(root, "node_modules/@deepseek-ai/dsh-client-ui-settings/lib/client.js");
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(join(root, "package.json"), JSON.stringify({ name, version }));
  writeFileSync(target, original);
  return { root, target };
}

test("patches the supported installed package", (t) => {
  const { root, target } = packageFixture(t);
  assert.equal(patchInstalledSettings(root), target);
  assert.equal(readFileSync(target, "utf8"), patched);
});

test("rejects a changed package version without modifying its source", (t) => {
  const { root, target } = packageFixture(t, { version: "0.1.6-alpha.3" });
  assert.throws(() => patchInstalledSettings(root), /requires @deepseek-ai\/dsh@0\.1\.6-alpha\.2/);
  assert.equal(readFileSync(target, "utf8"), original);
});

test("rejects an unexpected package name", (t) => {
  const { root, target } = packageFixture(t, { name: "other-package" });
  assert.throws(() => patchInstalledSettings(root), /requires @deepseek-ai\/dsh/);
  assert.equal(readFileSync(target, "utf8"), original);
});

test("CLI accepts a package root argument", (t) => {
  const { root, target } = packageFixture(t);
  const script = fileURLToPath(new URL("./enable-trusted-web-settings.mjs", import.meta.url));
  execFileSync(process.execPath, [script, root]);
  assert.equal(readFileSync(target, "utf8"), patched);
});
