"""A deterministic `codex app-server` for msgblast agent tests. No model, account or network.

Usage: codex_app_server.py LOG_DIR app-server [-c key=value ...]
Messages follow `codex app-server generate-json-schema` from codex-cli 0.172.0.
The turn text picks the scenario: "reply", "unphased", "approvals", "wait", "fail" or "exit".
"""
import json
import os
import sys

log_dir = sys.argv[1]
log = open(os.path.join(log_dir, "requests.jsonl"), "a")


def record(entry):
    log.write(json.dumps(entry) + "\n")
    log.flush()


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def read():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    message = json.loads(line)
    record(message)
    return message


def notify(method, **params):
    send({"method": method, "params": params})


record({"argv": sys.argv[2:], "codexHome": os.environ.get("CODEX_HOME"),
        "openAIKey": "OPENAI_API_KEY" in os.environ, "cwd": os.getcwd()})
turns = 0
while True:
    message = read()
    method, params, request = message.get("method"), message.get("params", {}), message.get("id")
    if method == "initialize":
        send({"id": request, "result": {"userAgent": "msgblast/0.172.0", "codexHome": "/fixture",
                                        "platformFamily": "unix", "platformOs": "macos"}})
    elif method == "config/read":
        send({"id": request, "result": {"config": {"mcp_servers": {"user-tools": {"command": "true", "enabled": True}}}}})
    elif method in ("thread/start", "thread/resume"):
        send({"id": request, "result": {"thread": {"id": params.get("threadId", "thread-fixture"), "turns": []}}})
    elif method == "turn/start":
        turns += 1
        thread, turn, text = params["threadId"], f"turn-{turns}", params["input"][0]["text"]
        send({"id": request, "result": {"turn": {"id": turn, "items": [], "status": "inProgress"}}})
        notify("turn/started", threadId=thread, turn={"id": turn, "items": [], "status": "inProgress"})
        if text == "exit":
            sys.exit(3)
        if text == "fail":
            notify("turn/completed", threadId=thread, turn={"id": turn, "items": [], "status": "failed",
                                                             "error": {"message": "Usage limit reached."}})
            continue
        if text == "wait":
            notify("item/agentMessage/delta", threadId=thread, turnId=turn, itemId="message-wait", delta="Waiting")
            notify("item/completed", threadId=thread, turnId=turn, completedAtMs=3,
                   item={"type": "agentMessage", "id": "message-wait", "text": "Waiting", "phase": "final_answer"})
            interrupt = read()
            send({"id": interrupt["id"], "result": {}})
            notify("turn/completed", threadId=thread, turn={"id": turn, "items": [], "status": "interrupted"})
            continue
        if text == "approvals":
            approvals = [("mcpServer/elicitation/request", {"serverName": "msgblast", "mode": "form", "message": "Allow?",
                                                            "requestedSchema": {"type": "object", "properties": {}},
                                                            "_meta": {"codex_approval_kind": "mcp_tool_call"}}),
                         ("mcpServer/elicitation/request", {"serverName": "user-tools", "mode": "form", "message": "Allow?",
                                                            "requestedSchema": {"type": "object", "properties": {}},
                                                            "_meta": {"codex_approval_kind": "mcp_tool_call"}}),
                         ("item/commandExecution/requestApproval", {"itemId": "c1", "command": "ls"}),
                         ("item/tool/requestUserInput", {"questions": []})]
            for index, (name, body) in enumerate(approvals):
                send({"id": f"server-{index}", "method": name, "params": {"threadId": thread, "turnId": turn, **body}})
                read()
        tool = {"type": "mcpToolCall", "id": "tool-1", "server": "msgblast", "tool": "msgblast_agents_list", "arguments": {}}
        notify("item/started", threadId=thread, turnId=turn, startedAtMs=1, item={**tool, "status": "inProgress"})
        notify("item/completed", threadId=thread, turnId=turn, completedAtMs=2, item={**tool, "status": "completed"})
        # A progress note, then the answer. "unphased" leaves out the phase, as older models do.
        messages = [("message-1", ("I'll check ", "the agents."), "commentary"), ("message-2", ("Codex ", "replied"), "final_answer")]
        for item, deltas, phase in messages:
            phase = None if text == "unphased" else phase
            notify("item/started", threadId=thread, turnId=turn, startedAtMs=3, item={"type": "agentMessage", "id": item, "text": "", "phase": phase})
            for delta in deltas:
                notify("item/agentMessage/delta", threadId=thread, turnId=turn, itemId=item, delta=delta)
            notify("item/completed", threadId=thread, turnId=turn, completedAtMs=4,
                   item={"type": "agentMessage", "id": item, "text": "".join(deltas), "phase": phase})
        notify("item/completed", threadId="other-thread", turnId=turn, completedAtMs=4,
               item={**tool, "status": "failed"})
        notify("turn/completed", threadId=thread, turn={"id": turn, "items": [], "status": "completed"})
