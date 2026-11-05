// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Every story opts out of testing, so the test would prove nothing.
export default { title: "Hidden", tags: ["!test"] };

export const Untested = {
  render: () => "<h1>Untested</h1>",
};
