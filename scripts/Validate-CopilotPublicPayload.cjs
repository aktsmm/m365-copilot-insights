"use strict";
const fs = require("node:fs");
const { assertPublic } = require("./Export-CopilotPublicMonthly.cjs");
assertPublic(JSON.parse(fs.readFileSync(process.argv[2], "utf8").replace(/^\uFEFF/, "")));
