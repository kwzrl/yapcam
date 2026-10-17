#!/usr/bin/env python3
"""Integration probe for a running app with a disposable open fixture.
Uses curl, never reads or edits an original recording. Token comes from the app's
preferences via defaults, and is never written to the transcript.
"""
import json, os, subprocess, sys, tempfile, shlex
port = os.environ.get('YAPCAM_MCP_PORT', '7777')
token = os.environ.get('YAPCAM_MCP_TOKEN') or subprocess.check_output(['defaults', 'read', 'mov.yapcam.Yapcam', 'agent.mcp.token'], text=True).strip()
endpoint = f'http://127.0.0.1:{port}/mcp'
session = None
counter = 0

def rpc(method, params=None):
    global session, counter
    counter += 1
    payload = {'jsonrpc': '2.0', 'id': counter, 'method': method}
    if params is not None: payload['params'] = params
    command = ['curl', '-sS', '--max-time', '180', '-i', endpoint,
               '-H', 'Content-Type: application/json', '-H', 'Accept: application/json, text/event-stream',
               '-H', 'MCP-Protocol-Version: 2025-06-18', '-H', f'Authorization: Bearer {token}']
    if session: command += ['-H', f'Mcp-Session-Id: {session}']
    command += ['--data-binary', json.dumps(payload, separators=(',', ':'))]
    import shlex
    print('$ ' + shlex.join(command).replace(token, '${TOKEN}'), flush=True)
    response = subprocess.check_output(command, text=True)
    print(response, flush=True)
    header, body = response.split('\n\n', 1)
    assert '200' in header.splitlines()[0], header
    for line in header.splitlines()[1:]:
        if line.lower().startswith('mcp-session-id:'): session = line.split(':', 1)[1].strip()
    result = json.loads(body)
    assert 'error' not in result, result
    return result['result']

def call(name, args=None):
    result = rpc('tools/call', {'name': name, 'arguments': args or {}})
    assert not result.get('isError'), result
    return result['structuredContent']

rpc('initialize', {'protocolVersion':'2025-06-18', 'capabilities':{}, 'clientInfo':{'name':'Night curl verification', 'version':'1'}})
assert len(rpc('tools/list')['tools']) == 14
documents = call('list_documents')['documents']
assert documents and any(d['frontmost'] for d in documents)
summary = call('project_summary')
before = call('read_project')
call('batch', {'commands':[
    {'op':'delete_range', 'tl_start_ns':1000000000, 'tl_end_ns':1500000000},
    {'op':'add_zoom', 'tl_start_ns':0, 'tl_end_ns':500000000, 'mode':'manual', 'target':[0.5,0.5], 'scale':2}
]})
after = call('read_project')
assert after != before
edited = call('project_summary')
assert edited['duration_ns'] == summary['duration_ns'] - 500000000
assert edited['undo_steps'] == summary['undo_steps'] + 1
assert len(after['zooms']) == len(before['zooms']) + 1
call('seek', {'time_ns':250000000})
call('select', {'kind':'zoom', 'id':after['zooms'][-1]['id']})
assert call('undo')['changed']
assert call('read_project') == before
assert call('project_summary')['undo_steps'] == summary['undo_steps']
assert call('redo')['changed']
assert call('read_project') == after
assert call('undo')['changed']
assert call('read_project') == before
assert call('save')['saved']
assert call('project_summary', {'project': next(d['name'] for d in documents if d['frontmost'])})['duration_ns'] == summary['duration_ns']
# Errors must not mutate the document or create history.
failed = rpc('tools/call', {'name':'batch','arguments':{'commands':[{'op':'delete_range','tl_start_ns':0,'tl_end_ns':100000000}, {'op':'invalid'}]}})
assert failed['isError']
assert call('read_project') == before
# Even internal drag-group commands cannot merge separate agent calls.
depth = call('project_summary')['undo_steps']
for value in ['first MCP step', 'second MCP step']:
    call('apply', {'command': {'op':'coalesced_edit', 'key':'agent-test', 'command':{'op':'set','path':'notes','value':value}}})
assert call('project_summary')['undo_steps'] == depth + 2
assert call('undo')['changed']
assert call('undo')['changed']
assert call('read_project') == before
for label, extra, expected in [
    ('missing token', [], '401'),
    ('foreign origin', ['-H', f'Authorization: Bearer {token}', '-H', 'Origin: https://evil.example'], '403'),
    ('GET stream unsupported', ['-H', f'Authorization: Bearer {token}'], '405')]:
    command = ['curl','-sS','-o','/dev/null','-w','%{http_code}',endpoint] + extra
    print('$ ' + shlex.join(command).replace(token, '${TOKEN}'))
    code = subprocess.check_output(command, text=True)
    print(f'{code} ({label})')
    assert code == expected
print('PASS: live batch, one-step undo, selection/seek, atomic failure, auth and origin checks')
