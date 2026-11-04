# Kitchen only. Real node policies live in homelab-infra (infrastructure/chef/policies/)
# and pin this cookbook by git tag. The fixture plays the part of an Ayatori release
# and of the deployer's join (bootstrap-kubeconfig).
name 'homelab_compute'
run_list 'compute_test::default', 'homelab_compute::default'
cookbook 'homelab_compute', path: '.'
cookbook 'homelab_base', path: '../homelab_base'
cookbook 'compute_test', path: 'test/fixtures/cookbooks/compute_test'
