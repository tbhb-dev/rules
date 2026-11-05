// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// The project turns color contrast off in axe; the rules still fail the
// test, with axe's defaults.
export default {
  parameters: {
    a11y: { config: { rules: [{ id: "color-contrast", enabled: false }] } },
  },
};
