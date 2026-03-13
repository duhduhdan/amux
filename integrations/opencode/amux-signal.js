/**
 * amux signal plugin for OpenCode.
 *
 * Writes/removes signal files so amux knows when an agent is waiting for input.
 *
 * Install by symlinking into the global plugins directory:
 *   ln -s /path/to/amux-signal.js ~/.config/opencode/plugins/amux-signal.js
 */

import { mkdirSync, writeFileSync, unlinkSync } from "fs";
import { execSync } from "child_process";

const runtimeDir = process.env.XDG_RUNTIME_DIR || `/tmp/amux-${process.getuid()}`;
const signalDir = `${runtimeDir}/amux`;

function getSession() {
  try {
    return execSync("tmux display-message -p '#S'", {
      encoding: "utf-8",
      timeout: 2000,
    }).trim();
  } catch {
    return null;
  }
}

function touch(session) {
  if (!session) return;
  try {
    writeFileSync(`${signalDir}/${session}.waiting`, "");
  } catch {}
}

function remove(session) {
  if (!session) return;
  try {
    unlinkSync(`${signalDir}/${session}.waiting`);
  } catch {}
}

try {
  mkdirSync(signalDir, { recursive: true });
} catch {}

export const AmuxSignal = async () => {
  return {
    event: async ({ event }) => {
      // Agent finished — signal idle
      if (event.type === "session.idle") {
        touch(getSession());
      }

      // Agent started working — clear signal.
      // session.status fires on state transitions; only clear on non-idle
      // to avoid racing with session.idle (which fires right after).
      if (event.type === "session.status") {
        const status = event.properties?.status;
        if (status && status.type !== "idle") {
          remove(getSession());
        }
      }

      // Session ended — clean up
      if (event.type === "session.deleted") {
        remove(getSession());
      }
    },
  };
};
