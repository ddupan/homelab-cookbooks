# Kitchen only. Real node policies live in homelab-infra (infrastructure/chef/policies/)
# and pin this cookbook by git tag. The fixture plays the deployer's part: the backup
# volume and a stand-in for Bao's CA.
name 'homelab_ayatori'
run_list 'ayatori_test::default', 'homelab_ayatori::adopt', 'homelab_ayatori::default'
cookbook 'homelab_ayatori', path: '.'
cookbook 'homelab_base', path: '../homelab_base'
cookbook 'ayatori_test', path: 'test/fixtures/cookbooks/ayatori_test'
