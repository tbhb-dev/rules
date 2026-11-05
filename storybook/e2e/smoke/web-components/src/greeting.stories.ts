// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { html, LitElement } from "lit";

class TbhbGreeting extends LitElement {
  override render() {
    return html`<h1>Hello from Lit</h1>`;
  }
}

if (!customElements.get("tbhb-greeting")) {
  customElements.define("tbhb-greeting", TbhbGreeting);
}

export default { title: "Greeting" };

export const Static = {
  render: () => html`<tbhb-greeting></tbhb-greeting>`,
};
