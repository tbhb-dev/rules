// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

module.exports = {
  version: "0.2",
  import: process.env.TBHB_CSPELL_CONFIG ? [process.env.TBHB_CSPELL_CONFIG] : [],
  dictionaryDefinitions: [
    { name: "tbhb-rules", path: "./words.txt", addWords: true },
  ],
  dictionaries: ["tbhb-rules"],
  // Ignore only the suffix: the base word must still pass spelling checks.
  ignoreRegExpList: ["/['’]s\\b/g"],
};
