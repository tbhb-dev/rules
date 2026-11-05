// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { greeting } from "./greeting.ts";

export default { title: "Greeting" };

export const Static = {
  render: () => greeting("HTML"),
};
