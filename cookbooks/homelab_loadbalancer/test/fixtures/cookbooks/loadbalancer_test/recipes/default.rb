# Kitchen stand-in for the ACME client and for Bao: a server certificate for the node
# address and a client CA plus one client certificate, which the InSpec suite uses to
# call the APIs the way Ayatori does. Test material only.
package 'openssl'

directory '/etc/lb-test'

execute 'test certificates' do
  cwd '/etc/lb-test'
  command <<~SH
    set -e
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=server-ca \
      -keyout server-ca.key -out server-ca.pem
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=lb -keyout server.key -out server.csr
    printf 'subjectAltName=IP:#{node['ipaddress']}\\nextendedKeyUsage=serverAuth\\n' > server.ext
    openssl x509 -req -in server.csr -CA server-ca.pem -CAkey server-ca.key -CAcreateserial -days 30 \
      -extfile server.ext -out server.crt
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=client-ca \
      -keyout client-ca.key -out client-ca.pem
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=ayatori-dev-controller \
      -keyout client.key -out client.csr
    printf 'extendedKeyUsage=clientAuth\\n' > client.ext
    openssl x509 -req -in client.csr -CA client-ca.pem -CAkey client-ca.key -CAcreateserial -days 30 \
      -extfile client.ext -out client.crt
    # A client certificate from a different CA, e.g. another environment's controller.
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=other \
      -keyout other.key -out other.crt
  SH
  creates '/etc/lb-test/other.crt'
end
