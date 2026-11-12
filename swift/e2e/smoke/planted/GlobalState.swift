// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// A planted defect for the strict flag set's proof: shared mutable global
// state, which complete strict concurrency checking rejects. Nothing builds
// this file but the proof.
var counter = 0

func increment() {
    counter += 1
}
