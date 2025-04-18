# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "workflow"
  spec.version       = "0.0.1"
  spec.authors       = ["Mark Severson", "Simon Williams"]
  spec.email         = ["markse@instructure.com", "simon@instructure.com"]
  spec.summary       = "Instructure fork of the workflow gem"

  spec.files         = Dir.glob("{lib}/**/*")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 3.2", "< 8.0"
end
