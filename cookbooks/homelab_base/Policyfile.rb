# Kitchen only. Real node policies live in homelab-infra (infrastructure/chef/policies/)
# and pin this cookbook by git tag.
name 'homelab_base'
run_list 'homelab_base::default'
cookbook 'homelab_base', path: '.'
