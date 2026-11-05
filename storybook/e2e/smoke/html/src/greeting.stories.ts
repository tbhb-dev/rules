// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

export default { title: "Greeting" };

export const Static = {
  render: () => "<h1>Hello from HTML</h1>",
};

// A story may relax the a11y check for itself: this one's contrast fails,
// and its test still passes.
export const FaintButAllowed = {
  render: () => '<p style="color: #eee; background: #fff">faint</p>',
  parameters: { a11y: { test: "todo" } },
};
