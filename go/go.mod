// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

module github.com/tbhb-dev/rules/go

go 1.27.0

toolchain go1.27.3

tool (
	github.com/gomutants/gomutants
	github.com/rillig/gobco
	golang.org/x/tools/cmd/deadcode
)

require (
	github.com/gomutants/gomutants v0.7.2 // indirect
	github.com/rillig/gobco v1.3.4 // indirect
	golang.org/x/mod v0.42.0 // indirect
	golang.org/x/sync v0.24.0 // indirect
	golang.org/x/sys v0.49.0 // indirect
	golang.org/x/telemetry v0.0.0-20261009151841-97e8ea77aa2a // indirect
	golang.org/x/tools v0.52.0 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)
