#!/usr/bin/env python3
"""PostToolUse hook on the GitHub MCP's Actions tools: send Claude the facts, not the padding.

Every workflow run GitHub returns carries the full commit message of its
head commit (often 2 KB) and two copies of the actor with avatar URLs. A
`list_workflow_runs` of five runs was 10 KB, of which the run's own facts
(id, status, conclusion, branch, sha, times, URL) were under 1 KB — and it
stays in the conversation, read again on every later turn. This keeps each
commit message's first line and drops the actors; everything else passes.

Fail-open by design: on any input it does not recognise, or any error, it
prints nothing and the tool's own output reaches Claude unchanged. It never
blocks a call (PostToolUse runs after the tool).
"""
import json
import sys

DROP = ('actor', 'triggering_actor', 'repository', 'head_repository')


def slim(x):
    """Return (new value, changed?) for any JSON value."""
    changed = False
    if isinstance(x, list):
        out = []
        for v in x:
            nv, c = slim(v)
            out.append(nv)
            changed |= c
        return out, changed
    if isinstance(x, dict):
        out = {}
        for k, v in x.items():
            if k in DROP and isinstance(v, dict):
                changed = True
                continue
            if k == 'head_commit' and isinstance(v, dict):
                msg = str(v.get('message') or '')
                first = msg.split('\n', 1)[0][:120]
                if first != msg or len(v) > 1:
                    changed = True
                out[k] = {'message': first}
                continue
            nv, c = slim(v)
            out[k] = nv
            changed |= c
        return out, changed
    return x, False


def main():
    data = json.load(sys.stdin)
    resp = data.get('tool_response')
    # The MCP result as Claude Code hands it over: a list of content items.
    if not isinstance(resp, list) or not resp:
        return
    new_items, any_change = [], False
    for item in resp:
        if not (isinstance(item, dict) and item.get('type') == 'text' and isinstance(item.get('text'), str)):
            new_items.append(item)
            continue
        try:
            parsed = json.loads(item['text'])
        except ValueError:
            new_items.append(item)
            continue
        slimmed, changed = slim(parsed)
        if changed:
            any_change = True
            new_items.append(dict(item, text=json.dumps(slimmed, ensure_ascii=False, separators=(',', ':'))))
        else:
            new_items.append(item)
    if any_change:
        print(json.dumps({'hookSpecificOutput': {
            'hookEventName': 'PostToolUse',
            'updatedToolOutput': new_items,
        }}))


if __name__ == '__main__':
    try:
        main()
    except Exception:  # noqa: BLE001 - never stand between Claude and a tool result
        pass
    sys.exit(0)
