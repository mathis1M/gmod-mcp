#!/usr/bin/env node

import { createConnection } from "node:net";
import { pathToFileURL } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { Effect } from "effect";
import { z } from "zod";

const BRIDGE_PORT = 17905;
const BRIDGE_REQUEST_TIMEOUT = 1_000;
const BRIDGE_EXEC_RESULT_TIMEOUT = 11_000;
const MAX_SCREENSHOT_BYTES = 1024 * 1024;
const UNAVAILABLE = "GMod MCP is unavailable.";

type JsonObject = Record<string, unknown>;

const isObject = (value: unknown): value is JsonObject =>
	typeof value === "object" && value !== null && !Array.isArray(value);

const error = (cause: unknown) =>
	cause instanceof Error ? cause : new Error(String(cause));

const exchange = (request: Buffer, timeout: number) =>
	Effect.tryPromise({
		try: () =>
			new Promise<Buffer>((resolve, reject) => {
				const socket = createConnection({
					host: "127.0.0.1",
					port: BRIDGE_PORT,
				});
				const chunks: Buffer[] = [];
				let done = false;
				const finish = (callback: () => void) => {
					if (done) return;
					done = true;
					clearTimeout(timer);
					socket.destroy();
					callback();
				};
				const timer = setTimeout(
					() => finish(() => reject(new Error("GMod bridge timed out."))),
					timeout,
				);

				socket.once("connect", () => socket.write(request));
				socket.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
				socket.once("end", () => finish(() => resolve(Buffer.concat(chunks))));
				socket.once("error", (cause) => finish(() => reject(cause)));
			}),
		catch: error,
	});

const parseObject = (data: Buffer) =>
	Effect.try({
		try: () => {
			const result: unknown = JSON.parse(data.toString("utf8"));
			if (!isObject(result)) throw new Error("Invalid bridge response.");
			return result;
		},
		catch: error,
	});

const bridgeRequest = (
	action: string,
	fields: JsonObject = {},
	timeout = BRIDGE_REQUEST_TIMEOUT,
) =>
	exchange(
		Buffer.from(`${JSON.stringify({ action, ...fields })}\n`),
		timeout,
	).pipe(Effect.flatMap(parseObject));

const bridgeScreenshot = (target: string) =>
	exchange(
		Buffer.from(`${JSON.stringify({ action: "screenshot", target })}\n`),
		12_000,
	).pipe(
		Effect.flatMap((response) =>
			Effect.try({
				try: () => {
					const lineEnd = response.indexOf(0x0a);
					if (lineEnd < 0) throw new Error("Invalid bridge response.");
					const header: unknown = JSON.parse(
						response.subarray(0, lineEnd).toString("utf8"),
					);
					if (!isObject(header)) throw new Error("Invalid bridge response.");
					if (header.ok !== true) {
						throw new Error(
							typeof header.message === "string"
								? header.message
								: "Screenshot failed.",
						);
					}
					if (
						typeof header.size !== "number" ||
						!Number.isInteger(header.size) ||
						header.size <= 0 ||
						header.size > MAX_SCREENSHOT_BYTES
					) {
						throw new Error("Invalid screenshot size.");
					}
					const screenshot = response.subarray(lineEnd + 1);
					if (screenshot.length !== header.size)
						throw new Error("Incomplete screenshot.");
					return screenshot;
				},
				catch: error,
			}),
		),
	);

const run = (
	effect: Effect.Effect<unknown, unknown, never>,
	fallback: unknown,
) =>
	Effect.runPromise(
		(effect as Effect.Effect<unknown, unknown>).pipe(
			Effect.catchAll(() => Effect.succeed(fallback)),
		),
	);

const message = (result: JsonObject, fallback: string) =>
	typeof result.message === "string" ? result.message : fallback;

const json = (result: unknown) => ({
	content: [{ type: "text" as const, text: JSON.stringify(result) }],
});

export function validateExec(
	code: string,
	state: "server" | "client",
	target: string | undefined,
	returnResult: boolean,
): JsonObject | undefined {
	if (!code.trim())
		return { ok: false, message: "Lua code must not be empty." };
	if (state === "client" && !target?.trim()) {
		return {
			ok: false,
			message:
				"target is required for client execution: player name, SteamID, SteamID64, 'all', or 'tout le monde'.",
		};
	}
	if (state === "server" && target !== undefined) {
		return { ok: false, message: "target is only valid for client execution." };
	}
	if (typeof returnResult !== "boolean") {
		return { ok: false, message: "return_result must be a boolean." };
	}
}

export function createServer() {
	console.error("gmod mcp server lanceyy");
	const mcp = new McpServer(
		{ name: "gmod-mcp", version: "0.1.0" },
		{
			instructions:
				"MCP for Garry's Mod. For Lua execution, avoid hook Think, hook Tick, and player.GetAll unless necessary; keep code simple and efficient.",
		},
	);

	mcp.registerTool(
		"gmod_status",
		{ description: "Report the current Garry's Mod connection status." },
		async () =>
			json(
				await run(
					bridgeRequest("status").pipe(
						Effect.flatMap((status) =>
							typeof status.connected === "boolean" &&
							typeof status.message === "string"
								? Effect.succeed({
										connected: status.connected,
										message: status.message,
									})
								: Effect.fail(new Error("Invalid bridge response.")),
						),
					),
					{ connected: false, message: UNAVAILABLE },
				),
			),
	);

	mcp.registerTool(
		"gmod_players",
		{
			description:
				"List connected players and their current server-side state.",
		},
		async () =>
			json(
				await run(
					bridgeRequest("gmod_players").pipe(
						Effect.flatMap((result): Effect.Effect<JsonObject, Error> => {
							if (result.ok !== true)
								return Effect.succeed({
									ok: false,
									message: message(result, "Player query failed."),
								});
							return Array.isArray(result.result)
								? Effect.succeed({ ok: true, players: result.result })
								: Effect.fail(new Error("Invalid bridge response."));
						}),
					),
					{ ok: false, message: UNAVAILABLE },
				),
			),
	);

	mcp.registerTool(
		"gmod_entities",
		{
			description: "List server entities with a capped, structured snapshot.",
			inputSchema: {
				class_filter: z
					.string()
					.optional()
					.describe(
						"Optional case-insensitive substring matched against entity classes.",
					),
				customCheck: z
					.string()
					.max(60 * 1024)
					.optional()
					.describe(
						"Lua function body; return true to include an entity. The entity is available as `entity`.",
					),
				limit: z
					.number()
					.int()
					.min(1)
					.max(200)
					.optional()
					.default(100)
					.describe("Maximum entities to return."),
			},
		},
		async ({ class_filter, customCheck, limit }) => {
			const fields: JsonObject = { limit };
			if (class_filter?.trim()) fields.class_filter = class_filter.trim();
			if (customCheck?.trim()) fields.custom_check = customCheck;
			return json(
				await run(
					bridgeRequest("gmod_entities", fields).pipe(
						Effect.flatMap((result): Effect.Effect<JsonObject, Error> => {
							if (result.ok !== true)
								return Effect.succeed({
									ok: false,
									message: message(result, "Entity query failed."),
								});
							return isObject(result.result) &&
								Array.isArray(result.result.entities)
								? Effect.succeed({ ok: true, ...result.result })
								: Effect.fail(new Error("Invalid bridge response."));
						}),
					),
					{ ok: false, message: UNAVAILABLE },
				),
			);
		},
	);

	mcp.registerTool(
		"exec_lua_code",
		{
			description:
				"Execute Lua; set return_result=true only when the code returns a value or calls GModMCP.return_result(...).",
			inputSchema: {
				code: z.string().describe("Lua code to execute."),
				state: z
					.enum(["server", "client"])
					.describe("Execute on the server or on one client."),
				target: z
					.string()
					.optional()
					.describe(
						"Client name, SteamID, or SteamID64; required for client state.",
					),
				return_result: z
					.boolean()
					.optional()
					.default(false)
					.describe("Wait for and return the Lua result."),
			},
		},
		async ({ code, state, target, return_result }) => {
			const invalid = validateExec(code, state, target, return_result);
			if (invalid) return json(invalid);
			const fields: JsonObject = { state, code };
			if (target !== undefined) fields.target = target;
			if (return_result) fields.return_result = true;
			return json(
				await run(
					bridgeRequest(
						"exec_lua_code",
						fields,
						return_result ? BRIDGE_EXEC_RESULT_TIMEOUT : BRIDGE_REQUEST_TIMEOUT,
					).pipe(
						Effect.flatMap((result): Effect.Effect<JsonObject, Error> => {
							if (typeof result.ok !== "boolean")
								return Effect.fail(new Error("Invalid bridge response."));
							if (return_result) {
								return result.ok
									? Effect.succeed({ ok: true, result: result.result })
									: Effect.succeed({
											ok: false,
											message: message(result, "Lua execution failed."),
										});
							}
							return typeof result.message === "string"
								? Effect.succeed({ ok: result.ok, message: result.message })
								: Effect.fail(new Error("Invalid bridge response."));
						}),
					),
					{ ok: false, message: UNAVAILABLE },
				),
			);
		},
	);

	mcp.registerTool(
		"gmod_screenshot",
		{
			description:
				"Capture one player's current GMod render as a JPEG image, including VGUI. IMPORTANT: Save the returned screenshot to a local file on the user's computer before displaying it, then display that saved local file using an absolute path. Do not display the raw tool image payload alone.",
			inputSchema: {
				target: z.string().describe("Client name, SteamID, or SteamID64."),
			},
		},
		async ({ target }) => {
			if (!target.trim())
				return json({
					ok: false,
					message: "target is required for a screenshot.",
				});
			const screenshot = await Effect.runPromise(
				bridgeScreenshot(target.trim()).pipe(Effect.either),
			);
			return screenshot._tag === "Left"
				? json({ ok: false, message: screenshot.left.message || UNAVAILABLE })
				: {
						content: [
							{
								type: "image" as const,
								data: screenshot.right.toString("base64"),
								mimeType: "image/jpeg",
							},
						],
					};
		},
	);

	return mcp;
}

export async function main() {
	await createServer().connect(new StdioServerTransport());
}

if (
	process.argv[1] &&
	pathToFileURL(process.argv[1]).href === import.meta.url
) {
	main().catch((cause) => {
		console.error(cause);
		process.exitCode = 1;
	});
}
