import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";

// Settings can come from a .env file next to package.json (see .env.example).
try {
  process.loadEnvFile();
} catch {
  // No .env file: use the environment as is.
}

const config = loadConfig();
const app = await buildApp(config);

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, async () => {
    app.log.info({ signal }, "shutting down");
    await app.close();
    process.exit(0);
  });
}

await app.listen({ host: config.host, port: config.port });
