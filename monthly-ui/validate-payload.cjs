"use strict";
const fs = require("node:fs");
const { validate } = require("./dashboard.js");
try {
  validate(JSON.parse(fs.readFileSync(process.argv[2] === "-" ? 0 : process.argv[2], "utf8").replace(/^\uFEFF/, "")));
  process.stdout.write("Monthly payload valid\n");
} catch (error) {
  process.stderr.write(error.message + "\n");
  process.exitCode = 1;
}
