import net from "node:net";
import crypto from "node:crypto";

const DEFAULT_RPC_TIMEOUT_MILLISECONDS = 15_000;
const COMPLETION_RPC_TIMEOUT_MILLISECONDS = 60_000;

export function rpcTimeoutMilliseconds(method) {
  return method === "worker.complete"
    ? COMPLETION_RPC_TIMEOUT_MILLISECONDS
    : DEFAULT_RPC_TIMEOUT_MILLISECONDS;
}

export function request(socketPath, capability, method, fields = {}) {
  const payload = {
    id: crypto.randomUUID(),
    method,
    capability,
    ...fields
  };
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    let buffered = "";
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      error ? reject(error) : resolve(value);
    };
    socket.setTimeout(
      rpcTimeoutMilliseconds(method),
      () => finish(new Error("ADAPTER_RPC_TIMEOUT"))
    );
    socket.once("connect", () => socket.write(`${JSON.stringify(payload)}\n`));
    socket.on("data", (chunk) => {
      buffered += chunk.toString("utf8");
      const newline = buffered.indexOf("\n");
      if (newline === -1) return;
      try {
        const response = JSON.parse(buffered.slice(0, newline));
        if (!response.ok) finish(new Error(response.error || "ADAPTER_RPC_REJECTED"));
        else finish(null, response);
      } catch (error) {
        finish(error);
      }
    });
    socket.once("error", (error) => finish(error));
    socket.once("end", () => {
      if (!settled) finish(new Error("ADAPTER_RPC_EOF"));
    });
  });
}
