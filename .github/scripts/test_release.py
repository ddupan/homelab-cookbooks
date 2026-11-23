"""python3 .github/scripts/test_release.py"""
from release import bump, classify

# Real subjects from this repo's history.
assert classify('feat(homelab_compute): 部署 ayatori-imds（0.4.0）', '') == ('feat', 'minor')
assert classify('feat(homelab_loadbalancer)!: 关闭 :5555', '') == ('breaking', 'major')
assert classify('fix(homelab_data): etcd 备份检查改为可选', '') == ('fix', 'patch')
assert classify('chore(deps): update dependency spiffe/spire to v1.16.0', '') == ('deps', 'patch')
assert classify('refactor(homelab_base): x', 'BREAKING CHANGE: y') == ('breaking', 'major')
for silent in ('test(homelab_ayatori): Kitchen 改用 v0.3.0 镜像', 'docs: README', 'ci: 发布',
               'chore(renovate): 配置', 'chore(release): 发布 cookbook', 'Merge pull request x'):
    assert classify(silent, '') == (None, None), silent

assert bump('0.4.5', 'patch') == '0.4.6'
assert bump('0.4.5', 'minor') == '0.5.0'
assert bump('0.4.5', 'major') == '0.5.0'   # pre-1.0: breaking moves the minor
assert bump('1.2.3', 'major') == '2.0.0'
print('ok')
