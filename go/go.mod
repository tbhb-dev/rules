// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

module github.com/tbhb-dev/rules/go

go 1.27.0

toolchain go1.27.4

tool (
	github.com/gomutants/gomutants
	github.com/rillig/gobco
	golang.org/x/tools/cmd/deadcode
	golang.org/x/vuln/cmd/govulncheck
)

require github.com/bazelbuild/buildtools v0.0.0-20260904073137-eaa4d125b423

require (
	github.com/gomutants/gomutants v0.7.3 // indirect
	github.com/rillig/gobco v1.3.4 // indirect
	golang.org/x/mod v0.43.0 // indirect
	golang.org/x/sync v0.25.0 // indirect
	golang.org/x/sys v0.50.0 // indirect
	golang.org/x/telemetry v0.0.0-20261116191925-e77a43154acb // indirect
	golang.org/x/tools v0.53.0 // indirect
	golang.org/x/vuln v1.9.0 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)
