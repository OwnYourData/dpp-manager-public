// The messages of the form's checks, in words an operator reads.
//
// soya-form shows what its validator says, and that is written for whoever
// wrote the schema: "must have property declarationOfConformityContentType when
// property declarationOfConformity is present", with the internal field names
// in it. The label of the field is already shown above the message, so a
// readable message only has to say what is wrong.
//
// Only messages recognised in full are replaced; anything else is shown as it
// came, rather than guessed at. The texts come from the application's locale
// files, so a message is in the language of the page.
const RULES = [
  [/^must have property \S+ when property \S+ is present$/, "required_with"],
  [/^(is a required property|must have required property '[^']*')$/, "required"],
  [/^must match pattern "\^https:\/\/"$/, "https"],
  [/^must match pattern ".*"$/, "pattern"],
  [/^must be equal to one of the allowed values$/, "enum"],
  [/^must be >= (-?[\d.]+)$/, "minimum"],
  [/^must be <= (-?[\d.]+)$/, "maximum"],
  [/^must be > (-?[\d.]+)$/, "exclusive_minimum"],
  [/^must be < (-?[\d.]+)$/, "exclusive_maximum"],
  [/^must NOT have more than (\d+) characters$/, "max_length"],
  [/^must NOT have fewer than (\d+) characters$/, "min_length"],
  [/^must NOT have more than (\d+) items$/, "max_items"],
  [/^must NOT have fewer than (\d+) items$/, "min_items"],
  [/^must be integer$/, "integer"],
  [/^must be number$/, "number"],
  [/^must match format "date"$/, "date"],
  [/^must match format "[^"]*"$/, "format"]
]

// One message, or several joined by line breaks, as the form joins them.
export function readable(text, messages) {
  if (typeof text !== "string" || !messages) return text

  return text
    .split("\n")
    .map((line) => readableLine(line, messages))
    .join("\n")
}

function readableLine(line, messages) {
  const trimmed = line.trim()

  for (const [pattern, key] of RULES) {
    const match = trimmed.match(pattern)
    if (!match) continue

    const template = messages[key]
    if (typeof template !== "string" || template === "") return line

    return template.replace("%{limit}", match[1] ?? "")
  }

  return line
}
