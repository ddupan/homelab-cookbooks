#!/usr/bin/env python3
"""Work out each cookbook's next release from Conventional Commits; optionally apply it.

A cookbook's last release is the last commit that changed the `version` line of its
metadata.rb, so no tags are needed. Commits after it that touch the cookbook decide the
bump (pre-1.0, as this repo has always done: breaking or feat -> minor, fix -> patch):

  feat                               minor (major from 1.0 on if breaking)
  fix, perf, refactor, revert,
  chore(deps) / build(deps)          patch
  `!` or `BREAKING CHANGE` in body   breaking
  anything else (docs, test, ci,
  style, chore, non-conventional)    no release

  release.py                    print the plan
  release.py --write --summary F   bump metadata.rb, prepend CHANGELOG.md, write PR body to F
"""
import argparse
import datetime
import re
import subprocess
from pathlib import Path

SUBJECT = re.compile(r'^(?P<type>\w+)(?:\((?P<scope>[^)]*)\))?(?P<bang>!)?: (?P<desc>.+)$')
PATCH_TYPES = {'fix', 'perf', 'refactor', 'revert'}
VERSION_LINE = re.compile(r"^version\s+['\"]([^'\"]+)['\"]", re.M)
# Changelog sections, in order, for each kind of change.
SECTIONS = [('breaking', '⚠ 破坏性变更'), ('feat', '新功能'), ('fix', '修复'), ('deps', '依赖'), ('other', '其他')]


def git(*args):
    return subprocess.run(['git', *args], check=True, capture_output=True, text=True).stdout


def classify(subject, body):
    """Return (kind, bump) for one commit; bump is None when it does not release."""
    m = SUBJECT.match(subject)
    if not m:
        return None, None
    kind, scope = m['type'], m['scope'] or ''
    breaking = bool(m['bang']) or 'BREAKING CHANGE' in body
    if kind == 'feat':
        return ('breaking' if breaking else 'feat'), ('major' if breaking else 'minor')
    if kind in ('chore', 'build') and scope == 'deps':
        return 'deps', ('major' if breaking else 'patch')
    if kind in PATCH_TYPES:
        section = 'fix' if kind == 'fix' else 'other'
        return ('breaking' if breaking else section), ('major' if breaking else 'patch')
    return None, None


def bump(version, level):
    major, minor, patch = (int(x) for x in version.split('.'))
    if level == 'major' and major == 0:
        level = 'minor'   # pre-1.0: a breaking change moves the minor version
    if level == 'major':
        return f'{major + 1}.0.0'
    if level == 'minor':
        return f'{major}.{minor + 1}.0'
    return f'{major}.{minor}.{patch + 1}'


def pending(cookbook):
    """Commits since the cookbook's last version change, as (sha, subject, kind, level)."""
    meta = cookbook / 'metadata.rb'
    base = git('log', '-1', '--format=%H', '-G', r'^version ', '--', str(meta)).strip()
    log = git('log', '--no-merges', '--format=%H%x1f%s%x1f%b%x1e',
              *([f'{base}..HEAD'] if base else []), '--', str(cookbook))
    out = []
    for entry in filter(None, (e.strip('\n') for e in log.split('\x1e'))):
        sha, subject, body = entry.split('\x1f')
        kind, level = classify(subject, body)
        if level:
            out.append((sha, subject, kind, level))
    return out


def changelog_section(version, commits, today):
    lines = [f'## {version} ({today})', '']
    for kind, title in SECTIONS:
        items = [f'- {subject} ({sha[:7]})' for sha, subject, k, _ in commits if k == kind]
        if items:
            lines += [f'### {title}', '', *items, '']
    return '\n'.join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--write', action='store_true')
    ap.add_argument('--summary', type=Path)
    args = ap.parse_args()
    today = datetime.date.today().isoformat()
    summary = []
    for cookbook in sorted(p.parent for p in Path('cookbooks').glob('*/metadata.rb')):
        commits = pending(cookbook)
        if not commits:
            continue
        meta = cookbook / 'metadata.rb'
        current = VERSION_LINE.search(meta.read_text())[1]
        order = ['patch', 'minor', 'major']
        level = max((c[3] for c in commits), key=order.index)
        new = bump(current, level)
        section = changelog_section(new, commits, today)
        summary.append(f'## {cookbook.name} {current} → {new}\n\n' + section.split('\n', 2)[2])
        print(f'{cookbook.name}: {current} -> {new} ({len(commits)} commits)')
        if args.write:
            meta.write_text(VERSION_LINE.sub(f"version '{new}'", meta.read_text(), count=1))
            log = cookbook / 'CHANGELOG.md'
            head = f'# {cookbook.name} 变更记录\n\n'
            old = log.read_text().removeprefix(head) if log.exists() else ''
            log.write_text(head + section + '\n' + old)
    if args.summary:
        args.summary.write_text('\n'.join(summary))
    if not summary:
        print('nothing to release')


if __name__ == '__main__':
    main()
