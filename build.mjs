import { build } from "esbuild";
import { mkdir, readFile, writeFile } from "node:fs/promises";

const EXTENSION = "jsonschema_tle";
const VERSION = "0.1.0";
const RUNTIME_TAG = "$jsonschema_runtime$";
const PGTLE_TAG = "$jsonschema_tle_install$";

const { outputFiles } = await build({
  entryPoints: ["src/runtime.js"],
  bundle: true,
  minify: true,
  format: "iife",
  platform: "neutral",
  target: "es2020",
  write: false,
  legalComments: "none",
});
const runtime = outputFiles[0].text;

for (const tag of [RUNTIME_TAG, PGTLE_TAG]) {
  if (runtime.includes(tag)) throw new Error(`runtime bundle contains dollar-quote tag ${tag}`);
}

const template = await readFile("sql/extension.sql", "utf8");
const extensionSql = template.replace("{{RUNTIME}}", () => runtime);
if (extensionSql.includes(PGTLE_TAG)) throw new Error(`extension SQL contains ${PGTLE_TAG}`);

const installSql = `select pgtle.install_extension(
  '${EXTENSION}',
  '${VERSION}',
  'JSON Schema (2020-12) validation for jsonb, backed by Ajv on plv8',
  ${PGTLE_TAG}
${extensionSql}
${PGTLE_TAG},
  array['plv8']
);
`;

await mkdir("dist", { recursive: true });
await writeFile("dist/install.sql", installSql);
console.log(`runtime ${(runtime.length / 1024).toFixed(1)} KiB, dist/install.sql written`);
