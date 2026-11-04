# Kitchen only. Real node policies live in homelab-infra (infrastructure/chef/policies/)
# and pin this cookbook by git tag.
name 'homelab_data'
run_list 'homelab_data::monitoring'
cookbook 'homelab_data', path: '.'
