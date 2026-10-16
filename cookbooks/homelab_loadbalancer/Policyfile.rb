# Kitchen only. Real node policies live in homelab-infra (infrastructure/chef/policies/)
# and pin this cookbook by git tag. The fixture plays the part of the ACME client and
# of Bao: it drops a test server certificate and a test client CA.
name 'homelab_loadbalancer'
run_list 'loadbalancer_test::default', 'homelab_loadbalancer::default'
cookbook 'homelab_loadbalancer', path: '.'
cookbook 'homelab_base', path: '../homelab_base'
cookbook 'loadbalancer_test', path: 'test/fixtures/cookbooks/loadbalancer_test'
