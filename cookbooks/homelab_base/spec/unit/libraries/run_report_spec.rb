require 'spec_helper'
require_relative '../../../libraries/run_report'

describe HomelabBase::RunReport do
  it 'writes one labelled file per mode, atomically' do
    Dir.mktmpdir do |dir|
      described_class.write(dir, 'why-run', true, 3)
      body = File.read(File.join(dir, 'cinc_why_run.prom'))
      expect(body).to include('homelab_cinc_resources_updated{mode="why-run"} 3')
      expect(body).to include('homelab_cinc_last_run_success{mode="why-run"} 1')
      expect(Dir.children(dir)).to eq(['cinc_why_run.prom'])
    end
  end

  it 'does nothing before node_exporter exists' do
    expect { described_class.write('/nonexistent', 'apply', true, 0) }.not_to raise_error
  end
end
