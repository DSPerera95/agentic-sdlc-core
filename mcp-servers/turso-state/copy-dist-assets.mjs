import { copyFileSync } from "node:fs";

copyFileSync("src/schema.sql", "dist/schema.sql");
copyFileSync("package.runtime.json", "dist/package.json");
