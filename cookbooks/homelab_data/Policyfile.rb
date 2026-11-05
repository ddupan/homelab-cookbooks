# Kitchen only. Real node policies live in homelab-infra (infrastructure/chef/policies/)
# and pin this cookbook by git tag. etcd_test stands in for Bao-issued certificates.
name 'homelab_data'
run_list 'etcd_test::default', 'homelab_data::etcd', 'homelab_data::monitoring'
cookbook 'homelab_data', path: '.'
cookbook 'homelab_base', path: '../homelab_base'
cookbook 'etcd_test', path: 'test/fixtures/cookbooks/etcd_test'
