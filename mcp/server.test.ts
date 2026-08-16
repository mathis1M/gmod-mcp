import { expect, test } from "bun:test";
import { validateExec } from "./server";

test("accepts valid server and client executions", () => {
	expect(
		validateExec("print('ok')", "server", undefined, false),
	).toBeUndefined();
	expect(validateExec("print('ok')", "client", "all", true)).toBeUndefined();
});

test("rejects empty Lua code", () => {
	expect(validateExec("  \n", "server", undefined, false)).toEqual({
		ok: false,
		message: "Lua code must not be empty.",
	});
});

test("requires a target for client execution", () => {
	expect(validateExec("print('ok')", "client", undefined, false)).toEqual({
		ok: false,
		message: expect.stringContaining("target is required"),
	});
	expect(validateExec("print('ok')", "client", "  ", false)).toMatchObject({
		ok: false,
	});
});

test("rejects server targets and non-boolean return_result", () => {
	expect(validateExec("print('ok')", "server", "player", false)).toEqual({
		ok: false,
		message: "target is only valid for client execution.",
	});
	expect(
		validateExec("print('ok')", "server", undefined, undefined as never),
	).toEqual({
		ok: false,
		message: "return_result must be a boolean.",
	});
});
