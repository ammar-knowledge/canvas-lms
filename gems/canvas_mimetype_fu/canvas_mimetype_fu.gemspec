# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "canvas_mimetype_fu"
  spec.version       = "0.0.1"
  spec.authors       = ["Raphael Weiner"]
  spec.email         = ["rweiner@pivotallabs.com"]
  spec.summary       = "Instructure fork of mimetype_fu gem"

  spec.files         = Dir.glob("{lib,spec}/**/*") + %w[LICENSE.txt Rakefile README.md test.sh]
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
