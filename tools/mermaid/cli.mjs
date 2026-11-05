import fs from "node:fs";
import { renderMermaidASCII } from "beautiful-mermaid";

const doubleWidthCharacters = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}⺀-〿！-｠￠-￦]/gu;
const source = fs.readFileSync(0, "utf8");

try {
  // The renderer counts CJK characters as one cell; joiners compensate for double-width terminals.
  const asciiSource = source.replace(doubleWidthCharacters, "$&\u200D");
  const output = renderMermaidASCII(asciiSource, {
    useAscii: false,
    paddingX: 3,
    paddingY: 2,
    colorMode: "none",
  });
  const trimmedOutput = output.split("\n").map((line) => line.trimEnd()).join("\n");
  process.stdout.write(trimmedOutput);
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(message);
  process.exitCode = 1;
}
