// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// The project makes the check manual, through the current initialGlobals
// and the older globals; the rules still fail the test.
export default {
  initialGlobals: { a11y: { manual: true } },
  globals: { a11y: { manual: true } },
};
