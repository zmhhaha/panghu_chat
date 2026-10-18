import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const supportedVersion = "0.1.6-alpha.2";
const defaultPackageRoot = "/usr/local/lib/node_modules/@deepseek-ai/dsh";
const clientPath = "node_modules/@deepseek-ai/dsh-client-ui-settings/lib/client.js";
const original = 'const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";';
const replacement = `const persistence = ctx.remote.$host.isLoopback || (
  globalThis.location?.origin === "https://dsh.panghuer.top" &&
  typeof globalThis.__DSH_TRANSPORT__ === "undefined"
) ? "host" : "memory";`;

// Only the authenticated DSH web origin may persist settings on its host.
// Injected transports remain subject to upstream's original loopback check.
// Do not change $host.isLoopback: other plugins rely on that security boundary.
export function patchSettingsSource(source) {
  const matches = source.split(original).length - 1;
  if (matches !== 1) {
    throw new Error(`Expected exactly one settings persistence statement, found ${matches}`);
  }
  return source.replace(original, replacement);
}

export function patchInstalledSettings(packageRoot = defaultPackageRoot) {
  const manifest = JSON.parse(readFileSync(resolve(packageRoot, "package.json"), "utf8"));
  if (manifest.name !== "@deepseek-ai/dsh" || manifest.version !== supportedVersion) {
    throw new Error(`Settings patch requires @deepseek-ai/dsh@${supportedVersion}; found ${manifest.name}@${manifest.version}`);
  }
  const target = resolve(packageRoot, clientPath);
  const patched = patchSettingsSource(readFileSync(target, "utf8"));
  writeFileSync(target, patched);
  return target;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const target = patchInstalledSettings(process.argv[2]);
  console.log(`Enabled trusted web settings in ${target}`);
}
