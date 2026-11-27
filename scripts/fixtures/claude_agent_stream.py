#!/usr/bin/python3
"""Deterministic Claude Code stand-in for the msgblast agent: checks the arguments, the MCP
config file and the environment, then replays recorded stream-json. No network or model call.
"""
import json
import os
from pathlib import Path
import stat
import sys
import time
import uuid

args = sys.argv[1:]
if args == ['--help']:
    print('--permission-prompts <target>')
    sys.exit(0)

def value(flag):
    return args[args.index(flag) + 1]

for flag in ['--print', '--verbose', '--include-partial-messages', '--strict-mcp-config', '--disable-slash-commands']:
    assert flag in args, flag
assert value('--input-format') == value('--output-format') == 'stream-json'
assert value('--tools') == '' and value('--setting-sources') == ''
assert value('--allowedTools') == 'mcp__msgblast__*'
assert value('--permission-mode') == 'dontAsk' and value('--permission-prompts') == 'none'
assert json.loads(value('--settings')) == {'disableAllHooks': True}
assert value('--append-system-prompt') == 'Fixture instructions'
for forbidden in ['--dangerously-skip-permissions', '--allow-dangerously-skip-permissions', '--bare', '--no-session-persistence']:
    assert forbidden not in args, forbidden
key = 'fixture-session-key'
assert not any(key in arg for arg in args)
assert key not in ''.join(os.environ.values())
assert os.environ['ENABLE_CLAUDEAI_MCP_SERVERS'] == 'false' and 'CLAUDECODE' not in os.environ
assert os.environ['CLAUDE_CONFIG_DIR'] == os.environ['MSGBLAST_FIXTURE_CONFIG_DIR']
config = Path(value('--mcp-config'))
assert stat.S_IMODE(config.stat().st_mode) == 0o600
assert json.loads(config.read_text()) == {'mcpServers': {'msgblast': {
    'command': '/fixture/msgblast', 'args': ['mcp'], 'env': {'MSGBLAST_AGENT_SESSION_KEY': key}}}}

resumed = value('--resume') if '--resume' in args else None
session = resumed or str(uuid.uuid4())
log = open(os.environ['MSGBLAST_CLI_FIXTURE_LOG'], 'a')
log.write(json.dumps({'pid': os.getpid(), 'config': str(config), 'arguments': args, 'resumed': resumed, 'cwd': os.getcwd()}) + '\n')
log.flush()

def emit(record):
    print(json.dumps({**record, 'session_id': session}), flush=True)

def init(tools=('mcp__msgblast__msgblast_agents_list',)):
    emit({'type': 'system', 'subtype': 'init', 'tools': list(tools), 'mcp_servers': [{'name': 'msgblast', 'status': 'connected'}]})

def stream(event):
    emit({'type': 'stream_event', 'event': event, 'parent_tool_use_id': None})

for line in sys.stdin:
    message = json.loads(line)
    if message['type'] != 'user':
        continue
    text = message['message']['content'][0]['text']
    log.write(json.dumps({'input': text}) + '\n')
    log.flush()
    if text == 'FOREIGN':
        init(['Bash', 'mcp__msgblast__msgblast_agents_list'])
    elif text == 'SILENT':
        init()
        time.sleep(600)
    elif text == 'HANG':
        init()
        request = json.loads(sys.stdin.readline())
        assert request['type'] == 'control_request' and request['request']['subtype'] == 'interrupt'
        print(json.dumps({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': request['request_id'], 'response': {'still_queued': []}}}), flush=True)
        emit({'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'text', 'text': '[Request interrupted by user]'}]}})
        emit({'type': 'result', 'subtype': 'error_during_execution', 'is_error': True, 'errors': []})
    else:
        init()
        stream({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'tool_use', 'id': 'toolu_1', 'name': 'mcp__msgblast__msgblast_agents_list', 'input': {}}})
        emit({'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 'toolu_1', 'is_error': False, 'content': '[]'}]}})
        stream({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
        for part in ['Fixture summary', ' of: ', text]:
            stream({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': part}})
        emit({'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Fixture summary of: ' + text}]}})
        emit({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'Fixture summary of: ' + text})
