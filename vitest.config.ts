import { defineConfig } from "vitest/config";

export default defineConfig({
  test: { include: ["scenarios/**/*.test.ts"] },
});
