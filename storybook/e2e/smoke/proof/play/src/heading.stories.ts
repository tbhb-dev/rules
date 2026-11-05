// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

export default { title: "Heading" };

export const MissingSubheading = {
  render: () => "<h1>Only a heading</h1>",
  play: async ({ canvasElement }: { canvasElement: HTMLElement }) => {
    if (canvasElement.querySelector("h2") === null) {
      throw new Error("planted failure: no h2 in the story");
    }
  },
};
