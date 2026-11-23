# Kitchen only. Real node policies live in homelab-infra (infrastructure/chef/policies/)
# and pin this cookbook by git tag. The fixture plays the part of Bao (internal CA and SSH CA key).
name 'homelab_base'
run_list 'base_test::default', 'homelab_base::default'
cookbook 'homelab_base', path: '.'
cookbook 'base_test', path: 'test/fixtures/cookbooks/base_test'
