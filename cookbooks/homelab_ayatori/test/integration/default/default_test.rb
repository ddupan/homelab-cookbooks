# k0s answers, every control plane identity got a certificate through a CSR and uses it.

describe command('/usr/local/bin/k0s kubectl get --raw /readyz') do
  its('exit_status') { should eq 0 }
end

%w(ayatori-controller external-secrets flux-source-controller flux-kustomize-controller kube-state-metrics).each do |identity|
  dir = "/etc/ayatori-control-plane/#{identity}"

  describe file("#{dir}/client.pem") do
    it { should exist }
    its('mode') { should cmp '0400' }
  end

  describe file("#{dir}/bootstrap-kubeconfig") do
    its('owner') { should eq 'root' }
    its('mode') { should cmp '0400' }
  end

  # The certificate authenticates as the identity, with the client-certificate group.
  describe command("/usr/local/bin/k0s kubectl --kubeconfig #{dir}/kubeconfig auth whoami -o jsonpath='{.status.userInfo}'") do
    its('exit_status') { should eq 0 }
    its('stdout') { should include %("username":"#{identity}") }
    its('stdout') { should include 'system:ayatori:client-certificates' }
  end
end

# Issued by k0s's CA through kube-controller-manager's csrsigning, not by `k0s kubeconfig create`.
describe command('/usr/local/bin/k0s kubectl get csr -o jsonpath="{.items[*].spec.signerName}"') do
  its('stdout') { should include 'kubernetes.io/kube-apiserver-client' }
end

%w(client-credentials flux-source-controller flux-kustomize-controller external-secrets kube-state-metrics).each do |unit|
  describe service(unit) do
    it { should be_running }
  end
end

describe file('/var/lib/prometheus/node-exporter/ayatori_certificates.prom') do
  its('content') { should match(/identity="flux-kustomize-controller"} \d+/) }
end

# `ayatori config add` (Ayatori ADR-0027): before signing in, anonymous requests read the login
# ConfigMap and nothing else. --kubeconfig /dev/null keeps k0s kubectl from using its admin kubeconfig.
anonymous = '/usr/local/bin/k0s kubectl --kubeconfig /dev/null --server https://127.0.0.1:6443 --insecure-skip-tls-verify'

describe command("#{anonymous} -n kube-public get configmap ayatori-login -o jsonpath='{.data.clientID} {.data.issuer}'") do
  its('exit_status') { should eq 0 }
  its('stdout') { should eq 'ayatori-kitchen https://sso.ddupan.top' }
end

describe command("#{anonymous} -n kube-public get configmap ayatori-login -o jsonpath='{.data.ca\\.crt}'") do
  its('stdout') { should eq file('/var/lib/k0s/pki/ca.crt').content }
end

describe command("#{anonymous} -n kube-public get configmaps") do
  its('exit_status') { should_not eq 0 }
end

describe command("#{anonymous} -n kube-system get configmap ayatori-login") do
  its('exit_status') { should_not eq 0 }
end
